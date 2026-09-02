import Foundation

extension GitHubPullRequestService: PullRequestStatusProviding {
    private static let discoveryFields =
        "number,title,url,state,isDraft,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository"

    func resolveRepository(repositoryPath: String, fetchRemotes: [GitFetchRemote]) async throws -> RepositoryIdentity {
        let result = try await runStatusCommand(
            ["repo", "view", "--json", "nameWithOwner,url"], repositoryPath: repositoryPath
        )
        guard result.exitCode == 0 else { throw GitHubStatusResponse.failure(result) }
        let repository = try GitHubPullRequestStatusDecoder.repository(from: result.stdout)
        guard
            fetchRemotes.contains(where: { remote in
                remote.fetchURLs.contains { RepositoryIdentity.github(fromFetchRemoteURL: $0) == repository }
            })
        else {
            throw PullRequestStatusError.repositoryUnavailable(
                "The active GitHub CLI repository does not match a Project fetch remote. "
                    + "Run gh repo set-default <remote> in the Project Repository Root."
            )
        }
        return repository
    }

    func discoverPullRequest(
        repository: RepositoryIdentity,
        branch: PullRequestBranchContext,
        previous: PullRequestStatus?,
        repositoryPath: String
    ) async throws -> PullRequestAssociation? {
        try GitHubPullRequestStatusDecoder.validateBranch(branch)
        let argument = try GitHubPullRequestStatusDecoder.repositoryArgument(repository)
        let result = try await runStatusCommand(
            [
                "pr", "list", "--repo", argument, "--head", branch.branchName,
                "--state", "all", "--limit", "50", "--json", Self.discoveryFields
            ],
            repositoryPath: repositoryPath
        )
        guard result.exitCode == 0 else { throw GitHubStatusResponse.failure(result) }
        let candidates = try GitHubPullRequestStatusDecoder.candidates(from: result.stdout, repository: repository)
        guard let selected = try Self.selectCandidate(candidates, branch: branch, previous: previous) else {
            return nil
        }
        return PullRequestAssociation(
            identity: selected.metadata.pullRequest,
            headBranchName: selected.metadata.headBranchName,
            headRepository: selected.metadata.headRepository
        )
    }

    func refreshPullRequests(
        _ identities: [PullRequestIdentity], repositoryPath: String
    ) async throws -> PullRequestStatusBatch {
        var seen = Set<PullRequestIdentity>()
        let unique = identities.filter { seen.insert($0).inserted }
        guard !unique.isEmpty, unique.count <= PullRequestStatusBatch.limit, let first = unique.first else {
            throw PullRequestStatusError.invalidMetadata("A status batch must contain between 1 and 20 Pull Requests.")
        }
        for identity in unique {
            _ = try GitHubPullRequestStatusDecoder.repositoryArgument(identity.repository)
            guard identity.repository.host == first.repository.host, identity.number > 0,
                identity.number <= Int32.max
            else {
                throw PullRequestStatusError.invalidMetadata(
                    "A status batch must contain valid Pull Request numbers on a single GitHub host."
                )
            }
        }
        var arguments = [
            "api", "graphql", "--hostname", first.repository.host, "--include",
            "--raw-field", "query=\(Self.statusQuery(count: unique.count))"
        ]
        for (index, identity) in unique.enumerated() {
            arguments += [
                "--raw-field", "owner\(index)=\(identity.repository.owner)",
                "--raw-field", "name\(index)=\(identity.repository.repositoryName)",
                "--field", "number\(index)=\(identity.number)"
            ]
        }
        let result = try await runStatusCommand(arguments, repositoryPath: repositoryPath)
        let response = try GitHubStatusResponse(result)
        return try GitHubPullRequestStatusDecoder.batch(response, identities: unique)
    }

    private static func statusQuery(count: Int) -> String {
        let variables = (0..<count).map {
            "$owner\($0):String!,$name\($0):String!,$number\($0):Int!"
        }.joined(separator: ",")
        let fields = """
            number title url state isDraft headRefName headRefOid
            headRepository { name owner { login } } isCrossRepository baseRefName reviewDecision
            commits(last:1) { nodes { commit { statusCheckRollup {
                contexts(first:100) {
                    nodes { __typename ... on CheckRun { status conclusion } ... on StatusContext { state } }
                    pageInfo { hasNextPage }
                }
            } } } }
            """
        let repositories = (0..<count).map { index in
            "pr\(index):repository(owner:$owner\(index),name:$name\(index)) { "
                + "pullRequest(number:$number\(index)) { \(fields) } }"
        }.joined(separator: "\n")
        return "query PullRequestStatuses(\(variables)) { rateLimit { cost remaining resetAt } \(repositories) }"
    }

    private static func selectCandidate(
        _ candidates: [GitHubPullRequestStatusDecoder.Candidate],
        branch: PullRequestBranchContext,
        previous: PullRequestStatus?
    ) throws -> GitHubPullRequestStatusDecoder.Candidate? {
        let matching = candidates.filter { candidate in
            guard candidate.metadata.headBranchName == branch.branchName else { return false }
            if let upstream = branch.upstreamRepository, let head = candidate.metadata.headRepository {
                return head == upstream
            }
            return true
        }
        let eligible = matching.filter { candidate in
            let metadata = candidate.metadata
            if let upstream = branch.upstreamRepository { return metadata.headRepository == upstream }
            return !metadata.isCrossRepository
                || metadata.headCommitObjectID == branch.headCommitObjectID.lowercased()
                || isPrevious(candidate, branch: branch, previous: previous)
        }
        let open = eligible.filter(\.isOpen)
        guard open.count <= 1 else { throw PullRequestStatusError.ambiguous }
        if let candidate = open.first { return candidate }
        if let candidate = eligible.first(where: { isPrevious($0, branch: branch, previous: previous) }) {
            return candidate
        }
        let terminal = eligible.filter { $0.metadata.headCommitObjectID == branch.headCommitObjectID.lowercased() }
        guard terminal.count <= 1 else { throw PullRequestStatusError.ambiguous }
        if let candidate = terminal.first { return candidate }
        guard matching.isEmpty else { throw PullRequestStatusError.unverifiedAssociation }
        return nil
    }

    private static func isPrevious(
        _ candidate: GitHubPullRequestStatusDecoder.Candidate,
        branch: PullRequestBranchContext,
        previous: PullRequestStatus?
    ) -> Bool {
        previous?.identity == candidate.metadata.pullRequest && previous?.headBranchName == branch.branchName
    }

    private func runStatusCommand(_ arguments: [String], repositoryPath: String) async throws -> GitHubCommandResult {
        try Task.checkCancellation()
        guard let executableURL = resolvedExecutableURL else { throw PullRequestStatusError.githubCLIUnavailable }
        let result: GitHubCommandResult
        do {
            result = try await commandRunner.run(
                executableURL: executableURL, arguments: arguments, workingDirectory: repositoryPath,
                environment: commandEnvironment, timeout: Self.timeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch GitHubCommandRunnerError.cancelled {
            throw CancellationError()
        } catch GitHubCommandRunnerError.timedOut {
            throw PullRequestStatusError.providerTimedOut
        } catch GitHubCommandRunnerError.launchFailed {
            throw PullRequestStatusError.githubCLIUnavailable
        } catch GitHubCommandRunnerError.outputTooLarge {
            throw PullRequestStatusError.invalidMetadata("GitHub CLI output exceeded the 1 MiB safety limit.")
        } catch {
            throw PullRequestStatusError.providerFailed("The GitHub CLI command could not be completed.")
        }
        try Task.checkCancellation()
        guard result.stdout.count <= Self.outputLimit, result.stderr.count <= Self.outputLimit else {
            throw PullRequestStatusError.invalidMetadata("GitHub CLI output exceeded the 1 MiB safety limit.")
        }
        return result
    }
}
