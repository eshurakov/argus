import Foundation

struct WorkspacePullRequestProjectInputs: Sendable {
    let fetchRemotes: [GitFetchRemote]
    let worktrees: [String: Result<PullRequestBranchContext, PullRequestStatusError>]
}

struct WorkspacePullRequestWorktreeInputs: Equatable, Sendable {
    let branch: PullRequestBranchContext
    let fetchRemotes: [GitFetchRemote]
}

protocol WorkspacePullRequestLocalInputProviding: Sendable {
    func readProject(
        repositoryPath: String,
        worktreePaths: [String]
    ) async throws -> WorkspacePullRequestProjectInputs

    func readWorktree(target: WorkspacePullRequestTarget) async throws -> WorkspacePullRequestWorktreeInputs
}

struct WorktreePullRequestLocalInputProvider: WorkspacePullRequestLocalInputProviding {
    let worktreeService: WorktreeService

    init(worktreeService: WorktreeService = WorktreeService()) {
        self.worktreeService = worktreeService
    }

    func readProject(
        repositoryPath: String,
        worktreePaths: [String]
    ) async throws -> WorkspacePullRequestProjectInputs {
        do {
            let worktrees = try await worktreeService.listWorktrees(repositoryPath: repositoryPath)
            let remotes = try await worktreeService.listFetchRemotes(repositoryPath: repositoryPath)
            try Task.checkCancellation()
            var contexts: [String: Result<PullRequestBranchContext, PullRequestStatusError>] = [:]
            for path in worktreePaths {
                do {
                    let context = try await branchContext(
                        path: path,
                        worktree: worktrees.first { WorkspacePullRequestTarget.normalizedPath($0.path) == path }
                    )
                    contexts[path] = .success(context)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as PullRequestStatusError {
                    contexts[path] = .failure(error)
                }
            }
            return WorkspacePullRequestProjectInputs(fetchRemotes: remotes, worktrees: contexts)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            throw PullRequestStatusError.repositoryUnavailable(
                "The Project Repository Root could not be read. Verify that its Git repository still exists."
            )
        }
    }

    func readWorktree(target: WorkspacePullRequestTarget) async throws -> WorkspacePullRequestWorktreeInputs {
        do {
            try requireDirectory(target.worktreePath)
            let branch = try await currentBranch(path: target.worktreePath)
            let output = try await worktreeService.runGit(
                args: ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir", "HEAD"],
                workingDirectory: target.worktreePath
            )
            let values = output.components(separatedBy: "\n")
            let commonDirectory = try await worktreeService.runGit(
                args: ["rev-parse", "--path-format=absolute", "--git-common-dir"],
                workingDirectory: target.repositoryPath
            )
            guard values.count == 3,
                WorkspacePullRequestTarget.normalizedPath(values[0]) == target.worktreePath,
                WorkspacePullRequestTarget.normalizedPath(values[1])
                    == WorkspacePullRequestTarget.normalizedPath(commonDirectory),
                target.worktreePath != target.repositoryPath
            else {
                throw PullRequestStatusError.repositoryUnavailable(
                    "The worktree is no longer registered in this Named Project."
                )
            }
            let remotes = try await worktreeService.listFetchRemotes(repositoryPath: target.repositoryPath)
            let context = try await makeContext(
                path: target.worktreePath, branch: branch, head: values[2]
            )
            try Task.checkCancellation()
            return WorkspacePullRequestWorktreeInputs(branch: context, fetchRemotes: remotes)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            if let error = error as? PullRequestStatusError { throw error }
            throw PullRequestStatusError.repositoryUnavailable(
                "The worktree's branch and HEAD could not be read. Verify that it is still a registered Git worktree."
            )
        }
    }

    private func branchContext(
        path: String,
        worktree: WorktreeInfo?
    ) async throws -> PullRequestBranchContext {
        try requireDirectory(path)
        guard let worktree, !worktree.isHead else {
            throw PullRequestStatusError.repositoryUnavailable(
                "The worktree is no longer registered in this Named Project."
            )
        }
        return try await makeContext(
            path: path, branch: worktree.branch, head: worktree.commitHash
        )
    }

    private func makeContext(
        path: String,
        branch: String,
        head: String
    ) async throws -> PullRequestBranchContext {
        guard !branch.isEmpty, branch != "(detached)", branch != "HEAD" else {
            throw PullRequestStatusError.repositoryUnavailable(
                "The worktree has a detached HEAD. Check out a branch to discover its Pull Request."
            )
        }
        guard GitReferenceValidation.isValidBranchName(branch),
            head.count == 40 || head.count == 64,
            head.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else {
            throw PullRequestStatusError.repositoryUnavailable("The worktree has no readable branch and HEAD commit.")
        }
        return PullRequestBranchContext(
            branchName: branch,
            headCommitObjectID: head.lowercased(),
            upstreamRepository: try await upstreamRepository(path: path, branch: branch)
        )
    }

    private func upstreamRepository(
        path: String,
        branch: String
    ) async throws -> RepositoryIdentity? {
        guard let remoteName = try await configuration("branch.\(branch).remote", path: path),
            remoteName != ".",
            let mergeReference = try await configuration("branch.\(branch).merge", path: path),
            mergeReference.hasPrefix("refs/heads/")
        else { return nil }
        let fetchURLs = try await configuration("remote.\(remoteName).url", path: path, all: true)
        let identities = Set(
            (fetchURLs ?? "").components(separatedBy: "\n")
                .compactMap { RepositoryIdentity.github(fromFetchRemoteURL: $0) }
        )
        guard identities.count == 1 else {
            throw PullRequestStatusError.repositoryUnavailable(
                "The branch upstream does not identify a single hosted repository through its fetch URLs."
            )
        }
        return identities.first
    }

    private func configuration(_ key: String, path: String, all: Bool = false) async throws -> String? {
        do {
            let value = try await worktreeService.runGit(
                args: ["config", all ? "--get-all" : "--get", key], workingDirectory: path
            )
            try Task.checkCancellation()
            return value.isEmpty ? nil : value
        } catch WorktreeError.gitCommandFailed(_, 1) {
            try Task.checkCancellation()
            return nil
        }
    }

    private func currentBranch(path: String) async throws -> String {
        do {
            let reference = try await worktreeService.runGit(
                args: ["symbolic-ref", "--quiet", "HEAD"], workingDirectory: path
            )
            guard reference.hasPrefix("refs/heads/") else {
                throw PullRequestStatusError.repositoryUnavailable(
                    "The worktree's HEAD does not reference a local branch."
                )
            }
            return String(reference.dropFirst("refs/heads/".count))
        } catch WorktreeError.gitCommandFailed(_, 1) {
            try Task.checkCancellation()
            throw PullRequestStatusError.repositoryUnavailable(
                "The worktree has a detached HEAD. Check out a branch to discover its Pull Request."
            )
        }
    }

    private func requireDirectory(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PullRequestStatusError.repositoryUnavailable("The worktree directory is missing.")
        }
    }
}
