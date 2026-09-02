import Foundation

extension WorkspacePullRequestStatusModel {
    struct Entry: Sendable {
        let target: WorkspacePullRequestTarget
        let owner = UUID()
        var observation = UUID()
        var branch: PullRequestBranchContext?
        var nextDiscovery = Date.distantPast
        var nextRefresh = Date.distantPast
    }

    struct LocalRead: Sendable {
        let id = UUID()
        let projectID: UUID
        let owner: UUID
        let revision: UUID
        let entries: [Entry]
    }

    @MainActor
    final class ProjectRuntime {
        let owner = UUID()
        let repositoryPath: String
        var revision = UUID()
        var fetchRemotes: [GitFetchRemote]?
        var repository: RepositoryIdentity?
        var resolvedAt: Date?
        var resolutionTask: Task<Void, Never>?
        var resolutionID: UUID?
        var localReadID: UUID?
        var failureCount = 0
        var failureGeneration = UUID()
        var retryAt: Date?
        var error: PullRequestStatusError?

        init(repositoryPath: String) {
            self.repositoryPath = repositoryPath
        }
    }

    enum RequestKind: Int, Sendable {
        case observe
        case selection
        case refresh
        case discover
        case manual
    }

    struct Request: Sendable {
        let target: WorkspacePullRequestTarget
        let owner: UUID
        let projectOwner: UUID
        let revision: UUID
        let branch: PullRequestBranchContext
        let fetchRemotes: [GitFetchRemote]
        let kind: RequestKind
        let failureGeneration: UUID
    }

    @MainActor
    final class RunningRequest {
        let id = UUID()
        let request: Request
        var invalidated = false
        var repository: RepositoryIdentity?
        var association: PullRequestAssociation?
        var discovered = false
        var batchID: UUID?
        var task: Task<Void, Never>?

        init(request: Request) {
            self.request = request
        }
    }

    func runDueWork() {
        guard isEnabled, isActive else { return }
        if let missingCLIUntil, missingCLIUntil <= now() { self.missingCLIUntil = nil }
        for id in targetOrder {
            guard pending[id] == nil, prepared[id] == nil, running[id] == nil,
                let entry = entries[id]
            else { continue }
            if entry.nextDiscovery <= now() {
                enqueue(id, kind: .discover)
            } else if id == selectedWorkspaceID, entry.nextRefresh <= now() {
                enqueue(id, kind: .refresh)
            }
        }
        drainQueue()
    }

    func enqueue(_ workspaceID: UUID, kind: RequestKind) {
        guard isEnabled, isActive, let entry = entries[workspaceID] else { return }
        if let request = running[workspaceID], !request.invalidated {
            guard kind.rawValue > request.request.kind.rawValue, kind.rawValue >= RequestKind.discover.rawValue else {
                return
            }
            invalidateRequest(workspaceID)
        }
        if let existing = pending[workspaceID], existing.rawValue >= kind.rawValue { return }
        if let existing = prepared[workspaceID] {
            if existing.kind.rawValue >= kind.rawValue { return }
            prepared[workspaceID] = nil
        }
        pending[workspaceID] = kind
        if let project = projects[entry.target.projectID], allowedDate(project: project, kind: kind) > now() {
            publishBlocked(workspaceID, project: project)
        } else {
            var state = states[workspaceID] ?? WorkspacePullRequestState()
            state.isRefreshing = true
            publish(state, for: workspaceID)
        }
    }

    var hasProviderCapacity: Bool {
        providerTasks.count < (providerIsAvailable ? 3 : 1)
    }

    func drainQueue() {
        guard isEnabled, isActive else { return }
        startLocalReads()
        for id in prioritizedIDs {
            guard running[id] == nil, let request = prepared[id],
                let project = projects[request.target.projectID]
            else { continue }
            guard isCurrent(request) else {
                prepared[id] = nil
                enqueue(id, kind: maxKind(request.kind, .discover))
                continue
            }
            guard allowedDate(project: project, kind: request.kind) <= now() else {
                prepared[id] = nil
                pending[id] = request.kind
                publishBlocked(id, project: project)
                continue
            }
            var state = states[id] ?? WorkspacePullRequestState()
            state.isRefreshing = true
            publish(state, for: id)
            guard let repository = project.repository, let resolvedAt = project.resolvedAt,
                now().timeIntervalSince(resolvedAt) < 600
            else {
                if project.resolutionID == nil, hasProviderCapacity {
                    startRepositoryResolution(request, project: project)
                }
                continue
            }
            let previous = states[id]?.status
            let refresh = request.kind == .refresh && previous?.identity.repository == repository
            guard refresh || hasProviderCapacity else { continue }
            prepared[id] = nil
            let operation = RunningRequest(request: request)
            operation.repository = repository
            running[id] = operation
            if refresh, let previous {
                operation.association = PullRequestAssociation(previous)
            } else {
                operation.discovered = true
                operation.task = Task { [weak self] in await self?.discoverAssociation(operation) }
                providerTasks[operation.id] = operation.task
            }
        }
        startLocalReads()
        flushBatches()
    }

    var prioritizedIDs: [UUID] {
        guard let selectedWorkspaceID, targetOrder.contains(selectedWorkspaceID) else { return targetOrder }
        return [selectedWorkspaceID] + targetOrder.filter { $0 != selectedWorkspaceID }
    }

    func allowedDate(project: ProjectRuntime, kind: RequestKind) -> Date {
        var date = hostPause(project)?.pauseDeadline ?? .distantPast
        if kind != .manual {
            date = max(date, project.retryAt ?? .distantPast, missingCLIUntil ?? .distantPast)
            if let host = knownHost(project), let retryAt = hostBudgets.hosts[host]?.authenticationRetryAt {
                date = max(date, retryAt)
            }
        }
        return date
    }

    func publishBlocked(_ workspaceID: UUID, project: ProjectRuntime) {
        var state = states[workspaceID] ?? WorkspacePullRequestState()
        state.isRefreshing = false
        if let pause = hostPause(project) {
            state.error = pause
        } else if let missingCLIUntil, missingCLIUntil > now() {
            state.error = .githubCLIUnavailable
        } else if let host = knownHost(project),
            hostBudgets.hosts[host]?.authenticationRetryAt.map({ $0 > now() }) == true
        {
            state.error = .unauthenticated
        } else if let error = project.error {
            state.error = error
        }
        state.hasLoaded = state.hasLoaded || state.error != nil
        publish(state, for: workspaceID)
    }

    func invalidateRequest(_ workspaceID: UUID) {
        if let operation = running[workspaceID] {
            operation.invalidated = true
            operation.task?.cancel()
            if let host = operation.repository?.host, let batch = batches[host], batch.id == operation.batchID {
                if batch.operations.allSatisfy(\.invalidated) { providerTasks[batch.id]?.cancel() }
            } else if operation.task == nil {
                running[workspaceID] = nil
            }
        }
        prepared[workspaceID] = nil
    }

    func invalidateRepository(_ project: ProjectRuntime) {
        project.resolvedAt = nil
        project.revision = UUID()
        project.resolutionTask?.cancel()
        project.resolutionTask = nil
        project.resolutionID = nil
        for id in targetOrder where entries[id]?.target.repositoryPath == project.repositoryPath {
            guard let projectID = entries[id]?.target.projectID, projects[projectID] === project else { continue }
            if running[id] != nil || prepared[id] != nil {
                let kind = pending[id] ?? prepared[id]?.kind ?? running[id]?.request.kind ?? .discover
                invalidateRequest(id)
                enqueue(id, kind: maxKind(kind, .discover))
            }
        }
    }

    func maxKind(_ first: RequestKind, _ second: RequestKind) -> RequestKind {
        first.rawValue >= second.rawValue ? first : second
    }

    func networkKind(_ requested: RequestKind, workspaceID: UUID) -> RequestKind? {
        guard let entry = entries[workspaceID], let state = states[workspaceID] else { return nil }
        if requested == .manual { return .manual }
        if requested == .observe || requested == .selection,
            let error = state.error, isWorkspaceFailure(error),
            entry.nextDiscovery > now(), entry.nextRefresh > now()
        {
            return nil
        }
        if !state.hasLoaded || entry.nextDiscovery <= now() { return .discover }
        if requested == .discover { return .discover }
        if requested == .refresh { return state.status == nil ? .discover : .refresh }
        if requested == .observe {
            guard workspaceID == selectedWorkspaceID, entry.nextRefresh <= now() else { return nil }
        } else {
            let interval: TimeInterval = state.status == nil && state.error == nil ? 600 : 60
            guard state.lastSuccess.map({ now().timeIntervalSince($0) >= interval }) ?? true else { return nil }
        }
        return state.status == nil ? .discover : .refresh
    }

    func startLocalReads() {
        var dueProjects: [UUID: [Entry]] = [:]
        for id in prioritizedIDs {
            guard let kind = pending[id], running[id] == nil, let entry = entries[id],
                let project = projects[entry.target.projectID], project.localReadID == nil
            else { continue }
            if kind != .observe, kind != .selection, allowedDate(project: project, kind: kind) > now() {
                publishBlocked(id, project: project)
                continue
            }
            dueProjects[entry.target.projectID, default: []].append(entry)
        }
        for (projectID, dueEntries) in dueProjects {
            guard let project = projects[projectID] else { continue }
            let read = LocalRead(
                projectID: projectID, owner: project.owner, revision: project.revision, entries: dueEntries
            )
            project.localReadID = read.id
            let inputs = localInputs
            localTasks[read.id] = Task { [weak self] in
                let result: Result<WorkspacePullRequestProjectInputs, Error>
                do {
                    result = .success(
                        try await inputs.readProject(
                            repositoryPath: project.repositoryPath,
                            worktreePaths: read.entries.map(\.target.worktreePath)
                        )
                    )
                } catch { result = .failure(error) }
                self?.finishLocalRead(result, read: read)
            }
        }
    }
}
