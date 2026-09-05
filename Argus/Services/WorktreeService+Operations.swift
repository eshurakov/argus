import Darwin
import Foundation

extension WorktreeService {
    /// Creates a Managed Worktree.
    ///
    /// `startPoint` applies only when creating a new branch and names the
    /// committish the branch starts from. Passing `nil` keeps Git's default of
    /// branching from the repository's current `HEAD`.
    func createWorktree(
        projectId: UUID,
        repositoryPath: String,
        branchName: String,
        createNewBranch: Bool = true,
        startPoint: String? = nil
    ) async throws -> String {
        let configuredRemotes = (try? await remoteNames(repositoryPath: repositoryPath)) ?? []
        let remoteNames = Set(configuredRemotes + ["origin"])
        if !createNewBranch,
            let existingPath = try await existingWorktreePath(
                for: branchName,
                repositoryPath: repositoryPath,
                remoteNames: remoteNames
            )
        {
            return existingPath
        }
        let resolvedBranchName =
            createNewBranch
            ? branchName.trimmingCharacters(in: .whitespacesAndNewlines)
            : try await resolveExistingBranchForWorktree(branchName, repositoryPath: repositoryPath)
        let worktreeURL =
            managedWorktreeBaseURL
            .appendingPathComponent(projectId.uuidString, isDirectory: true)
            .appendingPathComponent(uniqueSlug(resolvedBranchName, projectId: projectId), isDirectory: true)
        try FileManager.default.createDirectory(
            at: worktreeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            var arguments = ["-C", repositoryPath, "worktree", "add"]
            if createNewBranch {
                arguments += ["-b", resolvedBranchName, worktreeURL.path]
                if let startPoint, !startPoint.isEmpty {
                    arguments.append(startPoint)
                }
            } else {
                arguments += [worktreeURL.path, resolvedBranchName]
            }
            _ = try await runGit(args: arguments, workingDirectory: repositoryPath)
        } catch let error as WorktreeError {
            if case .gitCommandFailed(let detail, _) = error, detail.contains("already exists") {
                throw WorktreeError.branchAlreadyExists(branchName)
            }
            throw WorktreeError.worktreeCreationFailed(error.localizedDescription)
        }
        return worktreeURL.path
    }

    /// Deleting a Managed Worktree has to survive a partially completed
    /// earlier attempt. `git worktree remove` deletes the worktree's `.git`
    /// link before it finishes, so an attempt that was killed midway (for
    /// example by this service's own command timeout) leaves a directory that
    /// every later `git worktree remove` refuses with "validation failed".
    /// Retrying the same command can therefore never succeed on its own.
    ///
    /// A forced removal owns the outcome rather than the exact command: when
    /// Git cannot complete it, the worktree files are deleted directly and the
    /// stale registration is pruned. Pruning matters beyond tidiness, because a
    /// leftover registration keeps the branch marked as checked out and blocks
    /// creating that Worktree Workspace again.
    ///
    /// A non-forced removal keeps deferring to Git, so an unexpectedly dirty
    /// worktree still fails loudly instead of silently discarding user work.
    func removeWorktree(
        repositoryPath: String,
        worktreePath: String,
        force: Bool = false,
        managedOrphanProjectId: UUID? = nil
    ) async throws {
        let canonicalWorktreePath = try await authorizedRemovalPath(
            repositoryPath: repositoryPath,
            worktreePath: worktreePath,
            force: force,
            managedOrphanProjectId: managedOrphanProjectId
        )

        var arguments = ["-C", repositoryPath, "worktree", "remove"]
        if force {
            // Git requires --force twice to remove a locked worktree.
            arguments += ["--force", "--force"]
        }
        arguments.append(canonicalWorktreePath)

        let gitRemovalError: Error?
        do {
            _ = try await runGit(
                args: arguments,
                workingDirectory: repositoryPath,
                timeout: Self.worktreeRemovalTimeout
            )
            gitRemovalError = nil
        } catch {
            guard force else {
                throw WorktreeError.worktreeRemovalFailed(error.localizedDescription)
            }
            gitRemovalError = error
        }

        do {
            if FileManager.default.fileExists(atPath: canonicalWorktreePath) {
                try FileManager.default.removeItem(atPath: canonicalWorktreePath)
            }
        } catch {
            throw WorktreeError.worktreeRemovalFailed(
                (gitRemovalError ?? error).localizedDescription
            )
        }

        guard gitRemovalError != nil else { return }

        // The files are gone, so the registration must go too or the branch
        // stays unusable for a new Worktree Workspace.
        _ = try? await runGit(
            args: ["-C", repositoryPath, "worktree", "prune"],
            workingDirectory: repositoryPath
        )
    }

    private func authorizedRemovalPath(
        repositoryPath: String,
        worktreePath: String,
        force: Bool,
        managedOrphanProjectId: UUID?
    ) async throws -> String {
        let canonicalRepositoryPath = canonicalRemovalPath(repositoryPath)
        let canonicalWorktreePath = canonicalRemovalPath(worktreePath)
        let canonicalStorageRoot = canonicalRemovalPath(managedWorktreeBaseURL.path)
        let registeredWorktree = try await listWorktrees(repositoryPath: repositoryPath).first {
            canonicalRemovalPath($0.path) == canonicalWorktreePath
        }
        let managedOrphanIsAuthorized =
            managedOrphanProjectId.map { projectId in
                guard force else { return false }
                let projectStorageRoot = canonicalRemovalPath(
                    managedWorktreeBaseURL
                        .appendingPathComponent(projectId.uuidString, isDirectory: true)
                        .path
                )
                let targetParent = URL(fileURLWithPath: canonicalWorktreePath)
                    .deletingLastPathComponent()
                    .path
                var isDirectory: ObjCBool = false
                return targetParent == projectStorageRoot
                    && FileManager.default.fileExists(
                        atPath: canonicalWorktreePath,
                        isDirectory: &isDirectory
                    )
                    && isDirectory.boolValue
            } ?? false
        guard canonicalWorktreePath != canonicalRepositoryPath,
            canonicalWorktreePath != canonicalStorageRoot,
            registeredWorktree?.isHead == false || managedOrphanIsAuthorized
        else {
            throw WorktreeError.worktreeRemovalFailed(
                "Refusing to remove a path that is not an authorized secondary worktree"
            )
        }
        return canonicalWorktreePath
    }

    private func canonicalRemovalPath(_ path: String) -> String {
        guard let resolvedPath = realpath(path, nil) else {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        defer { free(resolvedPath) }
        return String(cString: resolvedPath)
    }

    func listBranches(repositoryPath: String) async throws -> [String] {
        let output = try await runGit(
            args: ["-C", repositoryPath, "branch", "--all", "--format=%(refname:short)"],
            workingDirectory: repositoryPath
        )
        let localAndTrackingBranches =
            output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("HEAD") }
        let remoteHeadBranches = (try? await listRemoteHeadBranches(repositoryPath: repositoryPath)) ?? []
        return Array(Set(localAndTrackingBranches + remoteHeadBranches)).sorted()
    }

    func uniqueBranchName(_ desiredName: String, repositoryPath: String) async throws -> String {
        let existingBranches = try await canonicalBranchNameSet(repositoryPath: repositoryPath)
        let baseName = desiredName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseName.isEmpty else { return "workspace" }
        if !existingBranches.contains(baseName) {
            return baseName
        }
        for counter in 1..<10_000 {
            let candidate = "\(baseName)-\(counter)"
            if !existingBranches.contains(candidate) {
                return candidate
            }
        }
        throw WorktreeError.branchAlreadyExists(baseName)
    }

    /// Returns `candidate` if it doesn't collide with an existing local or
    /// remote branch, otherwise generates fresh random candidates (falling
    /// back to a numeric suffix) until one is available.
    func suggestAvailableBranchName(
        preferring candidate: String,
        prefix: String,
        repositoryPath: String
    ) async throws -> String {
        let existingBranches = try await canonicalBranchNameSet(repositoryPath: repositoryPath)
        if !existingBranches.contains(candidate) {
            return candidate
        }
        for _ in 0..<25 {
            let alternative = RandomBranchNameGenerator.generate(prefix: prefix)
            if !existingBranches.contains(alternative) {
                return alternative
            }
        }
        return try await uniqueBranchName(candidate, repositoryPath: repositoryPath)
    }

    func ensureBranchNameAvailable(_ branchName: String, repositoryPath: String) async throws {
        let existingBranches = try await canonicalBranchNameSet(repositoryPath: repositoryPath)
        let baseName = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseName.isEmpty else { return }
        if existingBranches.contains(baseName) {
            throw WorktreeError.branchAlreadyExists(baseName)
        }
    }

    /// Records `baseBranch` as `branch`'s parent in the repository's shared
    /// local Git configuration — the same declaration Stack discovery reads.
    ///
    /// Only branches Argus creates are recorded, and only at creation time, so
    /// this never rewrites a parent another tool owns.
    func recordBaseBranch(
        _ baseBranch: String,
        forBranch branch: String,
        repositoryPath: String
    ) async throws {
        guard branch != baseBranch,
            GitReferenceValidation.isValidBranchName(branch),
            GitReferenceValidation.isValidBranchName(baseBranch)
        else {
            throw WorktreeError.baseBranchRecordingFailed(
                "Invalid branch names: '\(branch)' based on '\(baseBranch)'"
            )
        }
        do {
            _ = try await runGit(
                args: [
                    "-C", repositoryPath, "config",
                    RecordedBaseBranchConfiguration.key(for: branch), baseBranch
                ],
                workingDirectory: repositoryPath
            )
        } catch {
            throw WorktreeError.baseBranchRecordingFailed(error.localizedDescription)
        }
    }

    func remoteNames(repositoryPath: String) async throws -> [String] {
        let output = try? await runGit(
            args: ["-C", repositoryPath, "remote"],
            workingDirectory: repositoryPath
        )
        guard let output, !output.isEmpty else { return [] }
        return
            output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func remoteLocalBranchName(for branchName: String, remoteNames: Set<String>) -> String? {
        for remote in remoteNames where branchName.hasPrefix("\(remote)/") {
            return String(branchName.dropFirst(remote.count + 1))
        }
        return nil
    }

    private func canonicalBranchNameSet(repositoryPath: String) async throws -> Set<String> {
        async let branches = listBranches(repositoryPath: repositoryPath)
        async let remotes = remoteNames(repositoryPath: repositoryPath)
        let remoteNames = Set(try await remotes + ["origin"])
        return Set(
            try await branches.flatMap { branch -> [String] in
                for remote in remoteNames where branch.hasPrefix("\(remote)/") {
                    return [branch, String(branch.dropFirst(remote.count + 1))]
                }
                return [branch]
            })
    }

    private func listRemoteHeadBranches(repositoryPath: String) async throws -> [String] {
        let remotes = try await remoteNames(repositoryPath: repositoryPath)
        var branches: [String] = []
        for remote in remotes {
            guard
                let output = try? await runGit(
                    args: ["-C", repositoryPath, "ls-remote", "--heads", remote],
                    workingDirectory: repositoryPath,
                    timeout: 2
                ), !output.isEmpty
            else { continue }
            for line in output.components(separatedBy: "\n") {
                guard let refRange = line.range(of: "refs/heads/") else { continue }
                let branch = String(line[refRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !branch.isEmpty {
                    branches.append("\(remote)/\(branch)")
                }
            }
        }
        return branches
    }
}
