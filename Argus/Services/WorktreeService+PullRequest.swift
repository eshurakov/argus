import Foundation

extension WorktreeService {
    /// Lists remote names and all URLs configured for fetching. Push URLs are
    /// intentionally excluded from Repository Identity matching.
    func listFetchRemotes(repositoryPath: String) async throws -> [GitFetchRemote] {
        let output = try await runGit(
            args: ["-C", repositoryPath, "remote"],
            workingDirectory: repositoryPath
        )
        let names =
            output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var remotes: [GitFetchRemote] = []
        for name in names {
            let urlOutput = try? await runGit(
                args: [
                    "-C", repositoryPath, "config", "--get-all", "remote.\(name).url"
                ],
                workingDirectory: repositoryPath
            )
            let urls = (urlOutput ?? "")
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            remotes.append(GitFetchRemote(name: name, fetchURLs: urls))
        }
        return remotes
    }

    /// Chooses the fetch remote whose URL has the requested hosted identity.
    /// `origin` wins ties; all other ties use lexical remote-name order.
    func fetchRemoteName(
        for identity: RepositoryIdentity,
        repositoryPath: String
    ) async throws -> String? {
        let matchingNames = try await listFetchRemotes(repositoryPath: repositoryPath)
            .filter { remote in
                remote.fetchURLs.contains {
                    RepositoryIdentity.github(fromFetchRemoteURL: $0) == identity
                }
            }
            .map(\.name)

        return matchingNames.sorted { lhs, rhs in
            if lhs == rhs { return false }
            if lhs == "origin" { return true }
            if rhs == "origin" { return false }
            return lhs < rhs
        }.first
    }

    // Fetches a Pull Request head, creates or reuses its exact local branch,
    // and creates or reuses the normal Argus Managed Worktree.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func createPullRequestWorktree(
        projectId: UUID,
        repositoryPath: String,
        metadata: PullRequestWorkspaceMetadata
    ) async throws -> PullRequestWorktreeResolution {
        let baseRemote: String
        do {
            guard
                let resolvedRemote = try await fetchRemoteName(
                    for: metadata.baseRepository,
                    repositoryPath: repositoryPath
                )
            else {
                throw PullRequestWorkspaceError.baseRepositoryMismatch(metadata.baseRepository)
            }
            baseRemote = resolvedRemote
        } catch let error as PullRequestWorkspaceError {
            throw error
        } catch {
            throw PullRequestWorkspaceError.gitFetchFailed(error.localizedDescription)
        }

        let fetchedHead = try await fetchPullRequestHead(
            metadata,
            baseRemote: baseRemote,
            repositoryPath: repositoryPath
        )

        do {
            _ = try await runGit(
                args: [
                    "-C", repositoryPath, "check-ref-format", "--branch",
                    metadata.headBranchName
                ],
                workingDirectory: repositoryPath
            )
        } catch {
            throw PullRequestWorkspaceError.unavailableHead(
                "The head branch '" + metadata.headBranchName
                    + "' is not a valid local branch name."
            )
        }

        let worktrees = try await listWorktrees(repositoryPath: repositoryPath)
        let existingBranchCommit = await localBranchCommit(
            metadata.headBranchName,
            repositoryPath: repositoryPath
        )
        if let existingBranchCommit,
            existingBranchCommit.lowercased() != fetchedHead.lowercased()
        {
            throw PullRequestWorkspaceError.conflictingLocalBranch(
                name: metadata.headBranchName,
                existingCommit: existingBranchCommit,
                fetchedCommit: fetchedHead
            )
        }

        let existingWorktreePath =
            worktrees
            .first { !$0.isHead && $0.branch == metadata.headBranchName }
            .map { canonicalPath($0.path) }

        var createdBranch = false
        if existingBranchCommit == nil {
            do {
                _ = try await runGit(
                    args: [
                        "-C", repositoryPath, "branch", metadata.headBranchName,
                        fetchedHead
                    ],
                    workingDirectory: repositoryPath
                )
                createdBranch = true
            } catch {
                throw PullRequestWorkspaceError.worktreeCreationFailed(
                    detail(for: error)
                )
            }
        }

        await configurePullRequestUpstreamIfAvailable(
            metadata,
            repositoryPath: repositoryPath,
            fetchedHead: fetchedHead
        )

        if let existingWorktreePath {
            return PullRequestWorktreeResolution(
                branchName: metadata.headBranchName,
                worktreePath: existingWorktreePath,
                fetchedHeadObjectID: fetchedHead,
                reusedExistingWorktree: true
            )
        }

        let worktreeURL =
            managedWorktreeBaseURL
            .appendingPathComponent(projectId.uuidString, isDirectory: true)
            .appendingPathComponent(uniqueSlug(metadata.headBranchName, projectId: projectId), isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: worktreeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            if createdBranch {
                await rollbackPullRequestBranchIfSafe(
                    metadata.headBranchName,
                    repositoryPath: repositoryPath,
                    expectedCommit: fetchedHead
                )
            }
            throw PullRequestWorkspaceError.worktreeCreationFailed(error.localizedDescription)
        }

        do {
            _ = try await runGit(
                args: [
                    "-C", repositoryPath, "worktree", "add", worktreeURL.path,
                    metadata.headBranchName
                ],
                workingDirectory: repositoryPath
            )
        } catch {
            if createdBranch {
                await rollbackPullRequestBranchIfSafe(
                    metadata.headBranchName,
                    repositoryPath: repositoryPath,
                    expectedCommit: fetchedHead
                )
            }
            throw PullRequestWorkspaceError.worktreeCreationFailed(detail(for: error))
        }

        return PullRequestWorktreeResolution(
            branchName: metadata.headBranchName,
            worktreePath: canonicalPath(worktreeURL.path),
            fetchedHeadObjectID: fetchedHead,
            reusedExistingWorktree: false
        )
    }

    private func fetchPullRequestHead(
        _ metadata: PullRequestWorkspaceMetadata,
        baseRemote: String,
        repositoryPath: String
    ) async throws -> String {
        do {
            _ = try await runGit(
                args: [
                    "-C", repositoryPath, "fetch", "--no-tags", baseRemote,
                    "refs/pull/\(metadata.number)/head"
                ],
                workingDirectory: repositoryPath,
                timeout: 30
            )
        } catch {
            throw PullRequestWorkspaceError.gitFetchFailed(detail(for: error))
        }

        do {
            let fetchedHead = try await runGit(
                args: [
                    "-C", repositoryPath, "rev-parse", "--verify",
                    "FETCH_HEAD^{commit}"
                ],
                workingDirectory: repositoryPath
            )
            guard GitReferenceValidation.isValidBranchName(metadata.headBranchName),
                fetchedHead.count == 40 || fetchedHead.count == 64
            else {
                throw PullRequestWorkspaceError.unavailableHead(
                    "Git did not return a valid Pull Request head commit."
                )
            }
            return fetchedHead
        } catch let error as PullRequestWorkspaceError {
            throw error
        } catch {
            throw PullRequestWorkspaceError.unavailableHead(
                "Git could not resolve FETCH_HEAD as a commit."
            )
        }
    }

    private func configurePullRequestUpstreamIfAvailable(
        _ metadata: PullRequestWorkspaceMetadata,
        repositoryPath: String,
        fetchedHead: String
    ) async {
        guard let headRepository = metadata.headRepository else { return }
        guard
            let headRemote = try? await fetchRemoteName(
                for: headRepository,
                repositoryPath: repositoryPath
            )
        else { return }

        let refspec =
            "refs/heads/\(metadata.headBranchName):refs/remotes/\(headRemote)/\(metadata.headBranchName)"
        guard
            (try? await runGit(
                args: [
                    "-C", repositoryPath, "fetch", "--no-tags", headRemote, refspec
                ],
                workingDirectory: repositoryPath,
                timeout: 30
            )) != nil,
            let remoteCommit = try? await runGit(
                args: [
                    "-C", repositoryPath, "rev-parse", "--verify",
                    "refs/remotes/\(headRemote)/\(metadata.headBranchName)"
                ],
                workingDirectory: repositoryPath
            ),
            remoteCommit.lowercased() == fetchedHead.lowercased()
        else { return }

        _ = try? await runGit(
            args: [
                "-C", repositoryPath, "branch",
                "--set-upstream-to=\(headRemote)/\(metadata.headBranchName)",
                metadata.headBranchName
            ],
            workingDirectory: repositoryPath
        )
    }

    private func localBranchCommit(
        _ branchName: String,
        repositoryPath: String
    ) async -> String? {
        try? await runGit(
            args: [
                "-C", repositoryPath, "rev-parse", "--verify",
                "refs/heads/\(branchName)"
            ],
            workingDirectory: repositoryPath
        )
    }

    private func rollbackPullRequestBranchIfSafe(
        _ branchName: String,
        repositoryPath: String,
        expectedCommit: String
    ) async {
        guard let currentCommit = await localBranchCommit(branchName, repositoryPath: repositoryPath),
            currentCommit.lowercased() == expectedCommit.lowercased()
        else { return }

        guard let worktrees = try? await listWorktrees(repositoryPath: repositoryPath),
            !worktrees.contains(where: { $0.branch == branchName })
        else { return }

        _ = try? await runGit(
            args: ["-C", repositoryPath, "branch", "-D", branchName],
            workingDirectory: repositoryPath
        )
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private func detail(for error: Error) -> String {
        let rawDetail: String
        if let error = error as? WorktreeError {
            rawDetail =
                switch error {
                case .gitCommandFailed(let detail, _): detail
                case .gitCommandTimedOut(let command): command
                default: error.localizedDescription
                }
        } else {
            rawDetail = error.localizedDescription
        }

        let lines =
            rawDetail
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { line in
                let lowercased = line.lowercased()
                return !lowercased.contains("authorization")
                    && !lowercased.contains("password")
                    && !lowercased.contains("environment")
            }
        var detail = lines.joined(separator: " ")
        for prefix in ["ghp_", "gho_", "ghs_", "ghu_", "ghr_", "github_pat_"] {
            while let range = detail.range(of: prefix) {
                let suffix = detail[range.upperBound...]
                let tokenEnd = suffix.firstIndex(where: { $0.isWhitespace }) ?? suffix.endIndex
                detail.replaceSubrange(range.lowerBound..<tokenEnd, with: "[redacted]")
            }
        }
        return String(detail.prefix(500))
    }
}
