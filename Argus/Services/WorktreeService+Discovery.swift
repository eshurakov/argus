import Darwin
import Foundation

extension WorktreeService {
    func listWorktrees(repositoryPath: String) async throws -> [WorktreeInfo] {
        let output = try await runGit(
            args: ["-C", repositoryPath, "worktree", "list", "--porcelain"],
            workingDirectory: repositoryPath
        )
        guard !output.isEmpty else { return [] }
        return parseWorktrees(output)
    }

    func listAvailableBranches(repositoryPath: String) async throws -> [String] {
        async let allBranches = listBranches(repositoryPath: repositoryPath)
        async let worktrees = listWorktrees(repositoryPath: repositoryPath)
        async let remotes = remoteNames(repositoryPath: repositoryPath)
        let checkedOut = Set(try await worktrees.map(\.branch))
        let remoteNames = Set(try await remotes + ["origin"])
        return try await allBranches.filter { branch in
            if checkedOut.contains(branch) { return false }
            if let localName = remoteLocalBranchName(for: branch, remoteNames: remoteNames),
                checkedOut.contains(localName)
            {
                return false
            }
            return true
        }
    }

    func listWorkspaceBranchChoices(repositoryPath: String) async throws -> [String] {
        async let availableBranches = listAvailableBranches(repositoryPath: repositoryPath)
        async let worktrees = listWorktrees(repositoryPath: repositoryPath)
        let externalWorktreeBranches =
            try await worktrees
            .filter { !$0.isHead && !$0.branch.isEmpty && $0.branch != "(detached)" }
            .map(\.branch)
        return Array(Set(try await availableBranches + externalWorktreeBranches)).sorted()
    }

    func existingWorktreePath(
        for branchName: String,
        repositoryPath: String,
        remoteNames: Set<String>
    ) async throws -> String? {
        let localName = remoteLocalBranchName(for: branchName, remoteNames: remoteNames) ?? branchName
        return try await listWorktrees(repositoryPath: repositoryPath)
            .first { !$0.isHead && $0.branch == localName }?
            .path
    }

    func resolveExistingBranchForWorktree(
        _ branchName: String,
        repositoryPath: String
    ) async throws -> String {
        if await localBranchExists(branchName, repositoryPath: repositoryPath) {
            return branchName
        }
        let configuredRemotes = (try? await remoteNames(repositoryPath: repositoryPath)) ?? []
        let remoteNames = Set(configuredRemotes + ["origin"])
        if let localName = try await resolveQualifiedRemoteBranch(
            branchName,
            repositoryPath: repositoryPath,
            remoteNames: remoteNames
        ) {
            return localName
        }
        for remote in remoteNames {
            guard
                try await prepareRemoteBranch(
                    branchName,
                    remote: remote,
                    repositoryPath: repositoryPath,
                    remoteNames: remoteNames
                )
            else { continue }
            return branchName
        }
        throw WorktreeError.worktreeCreationFailed("Branch not found: \(branchName)")
    }

    func detectOrphanedWorktrees(
        projectId: UUID,
        knownWorkspacePaths: Set<String>
    ) -> [OrphanedWorktreeInfo] {
        let projectDirectory =
            managedWorktreeBaseURL
            .appendingPathComponent(projectId.uuidString, isDirectory: true)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: projectDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        let canonicalKnownPaths = Set(knownWorkspacePaths.map(canonicalDiscoveryPath))
        return entries.compactMap { entry in
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey]),
                values.isDirectory == true,
                !canonicalKnownPaths.contains(canonicalDiscoveryPath(entry.path))
            else { return nil }
            return OrphanedWorktreeInfo(
                path: entry.path,
                branchName: readBranchFromWorktreeDir(entry.path),
                projectId: projectId
            )
        }
    }

    /// An Orphaned Worktree has no Workspace state left to protect, so it uses
    /// the same forced removal contract as "Delete Worktree and Close".
    func cleanupOrphanedWorktree(
        projectId: UUID,
        repositoryPath: String,
        worktreePath: String
    ) async throws {
        try await removeWorktree(
            repositoryPath: repositoryPath,
            worktreePath: worktreePath,
            force: true,
            managedOrphanProjectId: projectId
        )
        _ = try? await runGit(
            args: ["-C", repositoryPath, "worktree", "prune"],
            workingDirectory: repositoryPath
        )
    }

    private func canonicalDiscoveryPath(_ path: String) -> String {
        guard let resolvedPath = realpath(path, nil) else {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        defer { free(resolvedPath) }
        return String(cString: resolvedPath)
    }

    private func parseWorktrees(_ output: String) -> [WorktreeInfo] {
        var parser = WorktreeListParser()
        for line in output.components(separatedBy: "\n") {
            parser.consume(line)
        }
        return parser.finish()
    }

    private func resolveQualifiedRemoteBranch(
        _ branchName: String,
        repositoryPath: String,
        remoteNames: Set<String>
    ) async throws -> String? {
        guard let localName = remoteLocalBranchName(for: branchName, remoteNames: remoteNames) else {
            return nil
        }
        if !(await remoteTrackingBranchExists(branchName, repositoryPath: repositoryPath)) {
            try await fetchRemoteHead(branchName, repositoryPath: repositoryPath, remoteNames: remoteNames)
        }
        guard await remoteTrackingBranchExists(branchName, repositoryPath: repositoryPath) else { return nil }
        if !(await localBranchExists(localName, repositoryPath: repositoryPath)) {
            try await createLocalBranchFromRemote(
                localName: localName,
                remoteBranch: branchName,
                repositoryPath: repositoryPath,
                remoteNames: remoteNames
            )
        }
        return localName
    }

    private func prepareRemoteBranch(
        _ branchName: String,
        remote: String,
        repositoryPath: String,
        remoteNames: Set<String>
    ) async throws -> Bool {
        let remoteBranch = "\(remote)/\(branchName)"
        if !(await remoteTrackingBranchExists(remoteBranch, repositoryPath: repositoryPath)) {
            try? await fetchRemoteHead(remoteBranch, repositoryPath: repositoryPath, remoteNames: remoteNames)
        }
        guard await remoteTrackingBranchExists(remoteBranch, repositoryPath: repositoryPath) else { return false }
        if !(await localBranchExists(branchName, repositoryPath: repositoryPath)) {
            try await createLocalBranchFromRemote(
                localName: branchName,
                remoteBranch: remoteBranch,
                repositoryPath: repositoryPath,
                remoteNames: remoteNames
            )
        }
        return true
    }

    private func localBranchExists(_ branchName: String, repositoryPath: String) async -> Bool {
        await runGitQuiet(
            args: ["-C", repositoryPath, "show-ref", "--verify", "refs/heads/\(branchName)"],
            workingDirectory: repositoryPath
        )
    }

    private func remoteTrackingBranchExists(_ branchName: String, repositoryPath: String) async -> Bool {
        await runGitQuiet(
            args: ["-C", repositoryPath, "show-ref", "--verify", "refs/remotes/\(branchName)"],
            workingDirectory: repositoryPath
        )
    }

    private func fetchRemoteHead(
        _ branchName: String,
        repositoryPath: String,
        remoteNames: Set<String>
    ) async throws {
        guard let localName = remoteLocalBranchName(for: branchName, remoteNames: remoteNames),
            let remote = remoteNames.first(where: { branchName.hasPrefix("\($0)/") })
        else { return }
        _ = try await runGit(
            args: [
                "-C", repositoryPath, "fetch", remote,
                "+refs/heads/\(localName):refs/remotes/\(remote)/\(localName)"
            ],
            workingDirectory: repositoryPath,
            timeout: 15
        )
    }

    private func createLocalBranchFromRemote(
        localName: String,
        remoteBranch: String,
        repositoryPath: String,
        remoteNames: Set<String>
    ) async throws {
        if (try? await runGit(
            args: ["-C", repositoryPath, "branch", "--track", localName, "refs/remotes/\(remoteBranch)"],
            workingDirectory: repositoryPath
        )) != nil {
            return
        }
        guard let remoteName = remoteNames.first(where: { remoteBranch.hasPrefix("\($0)/") }),
            let remoteLocalName = remoteLocalBranchName(for: remoteBranch, remoteNames: remoteNames)
        else { throw WorktreeError.worktreeCreationFailed("Branch not found: \(remoteBranch)") }
        _ = try await runGit(
            args: ["-C", repositoryPath, "fetch", remoteName, "refs/heads/\(remoteLocalName)"],
            workingDirectory: repositoryPath,
            timeout: 15
        )
        _ = try await runGit(
            args: ["-C", repositoryPath, "branch", localName, "FETCH_HEAD"],
            workingDirectory: repositoryPath
        )
    }

    private func readBranchFromWorktreeDir(_ path: String) -> String? {
        let gitFilePath = (path as NSString).appendingPathComponent(".git")
        let fileManager = FileManager.default
        guard let contents = fileManager.contents(atPath: gitFilePath),
            let text = String(data: contents, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir:") else { return nil }
        let gitDirectory = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let headPath = (gitDirectory as NSString).appendingPathComponent("HEAD")
        guard let headData = fileManager.contents(atPath: headPath),
            let head = String(data: headData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            head.hasPrefix("ref: refs/heads/")
        else { return nil }
        return String(head.dropFirst("ref: refs/heads/".count))
    }
}

private struct WorktreeListParser {
    private var worktrees: [WorktreeInfo] = []
    private var path: String?
    private var commit: String?
    private var branch: String?
    private var isFirst = true

    mutating func consume(_ line: String) {
        if line.hasPrefix("worktree ") {
            appendCurrent()
            path = String(line.dropFirst("worktree ".count))
            commit = nil
            branch = nil
        } else if line.hasPrefix("HEAD ") {
            commit = String(line.dropFirst("HEAD ".count))
        } else if line.hasPrefix("branch ") {
            branch = String(line.dropFirst("branch ".count))
                .replacingOccurrences(of: "refs/heads/", with: "")
        } else if line.hasPrefix("detached") {
            branch = "(detached)"
        }
    }

    mutating func finish() -> [WorktreeInfo] {
        appendCurrent()
        return worktrees
    }

    private mutating func appendCurrent() {
        guard let path else { return }
        worktrees.append(
            WorktreeInfo(
                path: path,
                branch: branch ?? "",
                commitHash: commit ?? "",
                isHead: isFirst
            ))
        isFirst = false
    }
}
