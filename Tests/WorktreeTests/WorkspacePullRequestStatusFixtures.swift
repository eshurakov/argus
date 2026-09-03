import Foundation
import Testing

@testable import Argus

@MainActor
final class PullRequestRuntimeFixture {
    let targets: [WorkspacePullRequestTarget]
    let provider: PullRequestRuntimeProvider
    let inputs: PullRequestRuntimeInputs
    let clock = PullRequestRuntimeClock()
    let model: WorkspacePullRequestStatusModel
    let hostBudgets: PullRequestStatusHostBudgetStore

    init(
        workspaceCount: Int = 1, projectCount: Int = 1, hostCount: Int = 1,
        hostBudgets: PullRequestStatusHostBudgetStore? = nil
    ) {
        self.hostBudgets = hostBudgets ?? PullRequestStatusHostBudgetStore()
        let projectIDs = (0..<projectCount).map { _ in UUID() }
        targets = (0..<workspaceCount).map { index in
            let project = index % projectCount
            return WorkspacePullRequestTarget(
                workspaceID: UUID(), projectID: projectIDs[project],
                repositoryPath: "/projects/project-\(project)", worktreePath: "/worktrees/feature-\(index)"
            )
        }
        var repositories: [String: RepositoryIdentity] = [:]
        var branches: [String: PullRequestBranchContext] = [:]
        for (index, target) in targets.enumerated() {
            let host = index % projectCount % hostCount
            repositories[target.repositoryPath] = RepositoryIdentity(
                provider: .github, host: host == 0 ? "github.example" : "github-\(host).example",
                owner: "owner-\(index % projectCount)", repositoryName: "repo"
            )
            branches[target.worktreePath] = Self.branch("feature-\(index)")
        }
        provider = PullRequestRuntimeProvider(repositories: repositories)
        inputs = PullRequestRuntimeInputs(branches: branches, repositories: repositories)
        model = WorkspacePullRequestStatusModel(
            provider: provider, localInputs: inputs, now: { [clock] in clock.date }, automaticallySchedules: false,
            hostBudgets: self.hostBudgets
        )
    }

    func update(
        targets: [WorkspacePullRequestTarget]? = nil, selected: UUID? = nil, enabled: Bool = true, active: Bool = true
    ) {
        model.update(
            targets: targets ?? self.targets, selectedWorkspaceID: selected, isEnabled: enabled, isActive: active
        )
    }

    func load(selected: UUID? = nil) async {
        update(selected: selected)
        await model.waitForIdle()
    }

    nonisolated static func branch(
        _ name: String, head: String = String(repeating: "a", count: 40), upstream: RepositoryIdentity? = nil
    ) -> PullRequestBranchContext {
        PullRequestBranchContext(branchName: name, headCommitObjectID: head, upstreamRepository: upstream)
    }

    nonisolated static func status(
        branch: String, repository: RepositoryIdentity, number: Int = 1,
        head: String = String(repeating: "a", count: 40), lifecycle: PullRequestLifecycle = .open
    ) -> PullRequestStatus {
        PullRequestStatus(
            identity: PullRequestIdentity(repository: repository, number: number),
            url: URL(
                string: "https://\(repository.host)/\(repository.owner)/\(repository.repositoryName)/pull/\(number)")!,
            title: "Pull Request for \(branch)", headBranchName: branch, headCommitObjectID: head,
            headRepository: repository, baseBranchName: "main", lifecycle: lifecycle, review: .required,
            checks: PullRequestChecks(pending: 1)
        )
    }

    nonisolated static func remotes(_ repository: RepositoryIdentity) -> [GitFetchRemote] {
        [
            GitFetchRemote(
                name: "origin",
                fetchURLs: ["https://\(repository.host)/\(repository.owner)/\(repository.repositoryName).git"])
        ]
    }
}

@MainActor
final class PullRequestRuntimeClock {
    var date = Date(timeIntervalSince1970: 1_700_000_000)

    func advance(_ seconds: TimeInterval) {
        date.addTimeInterval(seconds)
    }
}

actor PullRequestRuntimeProvider: PullRequestStatusProviding {
    enum Method: Hashable, Sendable {
        case resolve
        case discover
        case batch
    }

    struct Call: Equatable, Sendable {
        let method: Method
        let repositoryPath: String
        var repository: RepositoryIdentity?
        var branch: PullRequestBranchContext?
        var previous: PullRequestStatus?
        var fetchRemotes: [GitFetchRemote] = []
        var identities: [PullRequestIdentity] = []
    }

    private(set) var calls: [Call] = []
    private(set) var activeCount = 0
    private(set) var maximumActiveCount = 0
    private(set) var maximumBatchesPerHost: [String: Int] = [:]
    private var activeBatchesPerHost: [String: Int] = [:]
    private(set) var cancelledCompletions: [Int] = []
    var repositories: [String: RepositoryIdentity]
    var resolutionErrors: [String: PullRequestStatusError] = [:]
    var discoveries: [String: Result<PullRequestStatus?, PullRequestStatusError>] = [:]
    var statuses: [PullRequestIdentity: PullRequestStatus] = [:]
    var refreshes: [PullRequestIdentity: Result<PullRequestStatus, PullRequestStatusError>] = [:]
    var quotas: [String: PullRequestStatusQuota] = [:]
    var batchError: PullRequestStatusError?
    var retryAfter: Date?
    var suspendedMethods = Set<Method>()
    var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var nextNumber = 100

    init(repositories: [String: RepositoryIdentity]) {
        self.repositories = repositories
    }

    func resolveRepository(repositoryPath: String, fetchRemotes: [GitFetchRemote]) async throws -> RepositoryIdentity {
        let repository = repositories[repositoryPath]!
        let error = resolutionErrors[repositoryPath]
        await record(Call(method: .resolve, repositoryPath: repositoryPath, fetchRemotes: fetchRemotes))
        if let error { throw error }
        return repository
    }

    func discoverPullRequest(
        repository: RepositoryIdentity, branch: PullRequestBranchContext, previous: PullRequestStatus?,
        repositoryPath: String
    ) async throws -> PullRequestAssociation? {
        let number =
            branch.branchName.hasPrefix("feature-")
            ? Int(branch.branchName.dropFirst("feature-".count)).map { $0 + 1 } ?? nextNumber : nextNumber
        nextNumber += 1
        let result =
            discoveries[branch.branchName]
            ?? .success(
                PullRequestRuntimeFixture.status(branch: branch.branchName, repository: repository, number: number))
        await record(
            Call(
                method: .discover, repositoryPath: repositoryPath, repository: repository, branch: branch,
                previous: previous))
        guard let status = try result.get() else { return nil }
        statuses[status.identity] = status
        return PullRequestAssociation(status)
    }

    func refreshPullRequests(
        _ identities: [PullRequestIdentity], repositoryPath: String
    ) async throws -> PullRequestStatusBatch {
        let quota =
            quotas[identities[0].repository.host]
            ?? PullRequestStatusQuota(cost: 1, remaining: 4_999, resetAt: Date(timeIntervalSince1970: 2_000_000_000))
        let results = Dictionary(
            uniqueKeysWithValues: identities.map { identity in
                (
                    identity,
                    refreshes[identity] ?? statuses[identity].map { .success($0) }
                        ?? .failure(.invalidMetadata("No fixture status for this identity."))
                )
            })
        let error =
            batchError
            ?? results.values.compactMap { result -> PullRequestStatusError? in
                guard case .failure(let error) = result else { return nil }
                switch error {
                case .ambiguous, .unverifiedAssociation, .lookupLimit, .invalidMetadata: return nil
                default: return error
                }
            }.first
        let batch = PullRequestStatusBatch(results: results, quota: quota, retryAfter: retryAfter)
        await record(Call(method: .batch, repositoryPath: repositoryPath, identities: identities))
        if let error { throw error }
        return batch
    }

    func setRepository(_ repository: RepositoryIdentity, path: String) {
        repositories[path] = repository
    }

    func setResolutionError(_ error: PullRequestStatusError?, path: String) {
        resolutionErrors[path] = error
    }

    func setDiscovery(_ result: Result<PullRequestStatus?, PullRequestStatusError>, branch: String) {
        discoveries[branch] = result
    }

    func setRefresh(_ result: Result<PullRequestStatus, PullRequestStatusError>, branch: String) {
        for (identity, status) in statuses where status.headBranchName == branch { refreshes[identity] = result }
    }

    func setQuota(_ quota: PullRequestStatusQuota, host: String = "github.example", retryAfter: Date? = nil) {
        quotas[host] = quota
        self.retryAfter = retryAfter
    }

    func setBatchError(_ error: PullRequestStatusError?) {
        batchError = error
    }

    func suspend(_ methods: Set<Method>) {
        suspendedMethods = methods
    }

    func resume(_ index: Int) {
        guard let continuation = continuations.removeValue(forKey: index) else {
            Issue.record("No suspended provider call at index \(index)")
            return
        }
        continuation.resume()
    }

    func resumeAll() {
        suspendedMethods.removeAll()
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func waitForCalls(_ count: Int) async {
        guard calls.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    private func record(_ call: Call) async {
        let index = calls.count
        calls.append(call)
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        let batchHost = call.method == .batch ? call.identities.first?.repository.host : nil
        if let batchHost {
            activeBatchesPerHost[batchHost, default: 0] += 1
            maximumBatchesPerHost[batchHost] = max(
                maximumBatchesPerHost[batchHost, default: 0], activeBatchesPerHost[batchHost, default: 0]
            )
        }
        if suspendedMethods.contains(call.method) {
            await withCheckedContinuation { continuation in
                continuations[index] = continuation
                notifyWaiters()
            }
        } else {
            notifyWaiters()
        }
        if Task.isCancelled { cancelledCompletions.append(index) }
        if let batchHost { activeBatchesPerHost[batchHost, default: 0] -= 1 }
        activeCount -= 1
    }

    private func notifyWaiters() {
        let ready = waiters.filter { calls.count >= $0.0 }
        waiters.removeAll { calls.count >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
    }
}

actor PullRequestRuntimeInputs: WorkspacePullRequestLocalInputProviding {
    struct ProjectRead: Sendable {
        let repositoryPath: String
        let worktreePaths: [String]
    }

    var contexts: [String: Result<PullRequestBranchContext, PullRequestStatusError>]
    var fetchRemotes: [String: [GitFetchRemote]]
    private(set) var projectReads: [ProjectRead] = []
    private(set) var worktreeReads: [WorkspacePullRequestTarget] = []
    var suspendProjectReads = false
    var suspendedReads: [CheckedContinuation<Void, Never>] = []
    var readWaiter: CheckedContinuation<Void, Never>?

    init(branches: [String: PullRequestBranchContext], repositories: [String: RepositoryIdentity]) {
        contexts = branches.mapValues { .success($0) }
        fetchRemotes = repositories.mapValues { PullRequestRuntimeFixture.remotes($0) }
    }

    func readProject(
        repositoryPath: String, worktreePaths: [String]
    ) async throws -> WorkspacePullRequestProjectInputs {
        projectReads.append(ProjectRead(repositoryPath: repositoryPath, worktreePaths: worktreePaths))
        let result = WorkspacePullRequestProjectInputs(
            fetchRemotes: fetchRemotes[repositoryPath] ?? [],
            worktrees: contexts.filter { worktreePaths.contains($0.key) }
        )
        if suspendProjectReads {
            await withCheckedContinuation { continuation in
                suspendedReads.append(continuation)
                readWaiter?.resume()
                readWaiter = nil
            }
        }
        return result
    }

    func readWorktree(target: WorkspacePullRequestTarget) async throws -> WorkspacePullRequestWorktreeInputs {
        worktreeReads.append(target)
        guard let context = contexts[target.worktreePath] else {
            throw PullRequestStatusError.repositoryUnavailable("The worktree is not registered.")
        }
        return WorkspacePullRequestWorktreeInputs(
            branch: try context.get(), fetchRemotes: fetchRemotes[target.repositoryPath] ?? [])
    }

    func setBranch(_ branch: PullRequestBranchContext, path: String) {
        contexts[path] = .success(branch)
    }

    func setUnavailable(_ error: PullRequestStatusError, path: String) {
        contexts[path] = .failure(error)
    }

    func setRemotes(_ remotes: [GitFetchRemote], path: String) {
        fetchRemotes[path] = remotes
    }

    func suspendReads() {
        suspendProjectReads = true
    }

    func waitForRead() async {
        guard suspendedReads.isEmpty else { return }
        await withCheckedContinuation { readWaiter = $0 }
    }

    func resumeReads() {
        suspendProjectReads = false
        let pending = suspendedReads
        suspendedReads.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
