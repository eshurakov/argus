import Foundation

extension WorkspaceManager {
    func createProject(
        repositoryPath: String,
        displayName: String? = nil,
        mainBranchOverride: String? = nil
    ) async -> Project? {
        guard workspaces.count < Self.maxWorkspaces,
            let repositoryRoot = try? await worktreeService.canonicalRepositoryRoot(for: repositoryPath),
            !hasDuplicateProject(repositoryRoot: repositoryRoot)
        else { return nil }

        let detectedMainBranch = try? await worktreeService.detectMainBranch(
            repositoryPath: repositoryRoot
        )
        let normalizedMainBranch =
            mainBranchOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mainBranch = normalizedMainBranch.isEmpty ? (detectedMainBranch ?? "") : normalizedMainBranch
        guard !mainBranch.isEmpty else { return nil }
        let checkoutBranch =
            (try? await worktreeService.currentBranchName(repositoryPath: repositoryRoot))
            ?? mainBranch
        guard workspaces.count < Self.maxWorkspaces,
            !hasDuplicateProject(repositoryRoot: repositoryRoot)
        else { return nil }
        let project = Project(
            repositoryPath: repositoryRoot,
            displayName: displayName,
            mainBranch: mainBranch
        )
        projects.insert(project, at: max(projects.count - 1, 0))
        let workspace = Workspace(
            title: checkoutBranch,
            workingDirectory: repositoryRoot,
            projectId: project.id,
            branchName: checkoutBranch,
            workspaceType: .mainCheckout
        )
        workspaces.append(workspace)
        project.addWorkspace(workspace.id)
        selectedWorkspaceId = workspace.id
        saveSession()
        return project
    }

    func removeProject(_ projectId: UUID) async {
        guard let project = projects.first(where: { $0.id == projectId }),
            !project.isCatchAll
        else { return }
        for workspaceId in project.workspaceIds {
            guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { continue }
            agentStatusRuntime?.removeStatuses(forWorkspace: workspaceId)
            turnCompletionRuntime?.removeAttention(forWorkspace: workspaceId)
            if let worktreePath = workspace.worktreePath {
                try? await worktreeService.removeWorktree(
                    repositoryPath: project.repositoryPath,
                    worktreePath: worktreePath,
                    force: true
                )
            }
            for panelId in workspace.panelOrder {
                workspace.closeTab(panelId)
            }
        }
        let idsToRemove = Set(project.workspaceIds)
        workspaces.removeAll { idsToRemove.contains($0.id) }
        projects.removeAll { $0.id == projectId }
        restoreSelectionAfterRemovingWorkspaces(idsToRemove)
    }

    func renameProject(_ projectId: UUID, name: String) {
        guard let project = projects.first(where: { $0.id == projectId }),
            !project.isCatchAll
        else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            project.displayName = trimmed
            notifyWorkspaceContextChanged()
        }
    }

    func project(for workspaceId: UUID) -> Project? {
        projects.first { $0.containsWorkspace(workspaceId) }
    }

    var namedProjects: [Project] {
        projects.filter { !$0.isCatchAll }
    }

    @discardableResult
    func adoptOrphanedWorktree(_ orphan: OrphanedWorktreeInfo) -> Workspace? {
        guard workspaces.count < Self.maxWorkspaces,
            let project = projects.first(where: { $0.id == orphan.projectId }),
            !project.isCatchAll
        else { return nil }
        let branchName = orphan.branchName ?? (orphan.path as NSString).lastPathComponent
        let workspace = Workspace(
            title: branchName,
            workingDirectory: orphan.path,
            projectId: orphan.projectId,
            branchName: branchName,
            workspaceType: .worktree,
            worktreePath: orphan.path
        )
        workspaces.append(workspace)
        project.addWorkspace(workspace.id)
        selectedWorkspaceId = workspace.id
        saveSession()
        return workspace
    }

    func hasDuplicateProject(repositoryRoot: String) -> Bool {
        let canonicalRoot = URL(fileURLWithPath: repositoryRoot)
            .resolvingSymlinksInPath()
            .path
        return projects.contains {
            !$0.isCatchAll
                && URL(fileURLWithPath: $0.repositoryPath).resolvingSymlinksInPath().path == canonicalRoot
        }
    }

    func addWorkspaceToProject(
        _ projectId: UUID,
        branchName: String,
        createNewBranch: Bool = true,
        customTitle: String? = nil
    ) async -> Workspace? {
        lastWorkspaceCreationError = nil
        guard workspaces.count < Self.maxWorkspaces,
            let project = projects.first(where: { $0.id == projectId }),
            !project.isCatchAll
        else { return nil }

        do {
            if createNewBranch {
                try await worktreeService.ensureBranchNameAvailable(
                    branchName,
                    repositoryPath: project.repositoryPath
                )
            }
            let existingWorktreePaths = Set(
                ((try? await worktreeService.listWorktrees(repositoryPath: project.repositoryPath)) ?? [])
                    .map { canonicalPath($0.path) }
            )
            let worktreePath = try await worktreeService.createWorktree(
                projectId: projectId,
                repositoryPath: project.repositoryPath,
                branchName: branchName,
                createNewBranch: createNewBranch
            )
            return await attachPreparedWorktree(
                PreparedWorktreeAttachment(
                    path: worktreePath,
                    branchName: branchName,
                    customTitle: customTitle,
                    projectId: projectId,
                    repositoryPath: project.repositoryPath,
                    existingWorktreePaths: existingWorktreePaths
                ))
        } catch let error as WorktreeError {
            lastWorkspaceCreationError = error
            print("Failed to create worktree workspace: \(error.localizedDescription)")
            return nil
        } catch {
            print("Failed to create worktree workspace: \(error.localizedDescription)")
            return nil
        }
    }

    private struct PreparedWorktreeAttachment {
        let path: String
        let branchName: String
        let customTitle: String?
        let projectId: UUID
        let repositoryPath: String
        let existingWorktreePaths: Set<String>
    }

    private func attachPreparedWorktree(_ attachment: PreparedWorktreeAttachment) async -> Workspace? {
        guard let project = projects.first(where: { $0.id == attachment.projectId }),
            !project.isCatchAll,
            canonicalPath(project.repositoryPath) == canonicalPath(attachment.repositoryPath),
            workspaces.count < Self.maxWorkspaces
        else {
            if !attachment.existingWorktreePaths.contains(canonicalPath(attachment.path)) {
                try? await worktreeService.removeWorktree(
                    repositoryPath: attachment.repositoryPath,
                    worktreePath: attachment.path,
                    force: true
                )
            }
            return nil
        }

        let workspace = Workspace(
            title: attachment.branchName,
            workingDirectory: attachment.path,
            projectId: attachment.projectId,
            branchName: attachment.branchName,
            workspaceType: .worktree,
            worktreePath: attachment.path
        )
        if let customTitle = attachment.customTitle {
            workspace.setCustomTitle(customTitle)
        }
        workspaces.append(workspace)
        project.addWorkspace(workspace.id)
        selectedWorkspaceId = workspace.id
        saveSession()
        return workspace
    }

    /// Resolves one Pull Request through the active GitHub CLI and attaches
    /// its exact head to a Worktree Workspace in the initiating Project.
    ///
    /// Provider and Git work happen while this MainActor remains suspended;
    /// Project identity and the Project Repository Root are revalidated before
    /// durable Workspace state is changed.
    @discardableResult
    func createWorkspace(
        fromPullRequest input: String,
        in projectId: UUID
    ) async throws -> Workspace {
        lastPullRequestWorkspaceError = nil
        do {
            let parsedInput = try PullRequestInput.parse(input)
            let context = try pullRequestProjectContext(for: projectId)
            let metadata = try await pullRequestService.resolve(
                parsedInput,
                repositoryPath: context.repositoryRoot
            )
            let resolution = try await worktreeService.createPullRequestWorktree(
                projectId: context.projectID,
                repositoryPath: context.repositoryRoot,
                metadata: metadata
            )
            return try await attachPullRequestWorkspace(
                resolution,
                metadata: metadata,
                projectID: context.projectID,
                repositoryRoot: context.repositoryRoot
            )
        } catch let error as PullRequestWorkspaceError {
            lastPullRequestWorkspaceError = error
            throw error
        } catch {
            let mapped = PullRequestWorkspaceError.worktreeCreationFailed(
                error.localizedDescription
            )
            lastPullRequestWorkspaceError = mapped
            throw mapped
        }
    }

    private func pullRequestProjectContext(
        for projectId: UUID
    ) throws -> (projectID: UUID, repositoryRoot: String) {
        guard let project = projects.first(where: { $0.id == projectId }) else {
            throw PullRequestWorkspaceError.projectUnavailable
        }
        guard !project.isCatchAll else {
            throw PullRequestWorkspaceError.catchAllProject
        }
        guard workspaces.count < Self.maxWorkspaces else {
            throw PullRequestWorkspaceError.workspaceLimitReached
        }
        return (project.id, project.repositoryPath)
    }

    private func attachPullRequestWorkspace(
        _ resolution: PullRequestWorktreeResolution,
        metadata: PullRequestWorkspaceMetadata,
        projectID: UUID,
        repositoryRoot: String
    ) async throws -> Workspace {
        guard let currentProject = projects.first(where: { $0.id == projectID }),
            !currentProject.isCatchAll,
            canonicalPath(currentProject.repositoryPath) == canonicalPath(repositoryRoot)
        else {
            await cleanupPullRequestWorktreeIfNeeded(
                resolution,
                repositoryPath: repositoryRoot
            )
            throw PullRequestWorkspaceError.projectChanged
        }

        if let existingWorkspace = workspaces.first(where: { workspace in
            workspace.projectId == projectID
                && workspace.branchName == resolution.branchName
                && canonicalPath(workspace.worktreePath ?? workspace.currentDirectory)
                    == canonicalPath(resolution.worktreePath)
        }) {
            if existingWorkspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                existingWorkspace.customTitle = metadata.title
                saveSession()
            }
            selectedWorkspaceId = existingWorkspace.id
            return existingWorkspace
        }

        guard workspaces.count < Self.maxWorkspaces else {
            await cleanupPullRequestWorktreeIfNeeded(
                resolution,
                repositoryPath: repositoryRoot
            )
            throw PullRequestWorkspaceError.workspaceLimitReached
        }

        let workspace = Workspace(
            title: resolution.branchName,
            workingDirectory: resolution.worktreePath,
            projectId: projectID,
            branchName: resolution.branchName,
            workspaceType: .worktree,
            worktreePath: resolution.worktreePath
        )
        // GitHub's title is the authoritative custom title for newly
        // created Pull Request Workspaces. Preserve it exactly as returned.
        workspace.customTitle = metadata.title
        workspaces.append(workspace)
        currentProject.addWorkspace(workspace.id)
        selectedWorkspaceId = workspace.id
        saveSession()
        return workspace
    }

    private func cleanupPullRequestWorktreeIfNeeded(
        _ resolution: PullRequestWorktreeResolution,
        repositoryPath: String
    ) async {
        guard !resolution.reusedExistingWorktree else { return }
        do {
            try await worktreeService.removeWorktree(
                repositoryPath: repositoryPath,
                worktreePath: resolution.worktreePath
            )
        } catch {
            // Keep the original Project/Workspace error visible. The normal
            // Orphaned Worktree scan remains the recovery path for cleanup
            // failures; do not log provider or Git transport diagnostics here.
        }
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private func restoreSelectionAfterRemovingWorkspaces(_ removedIds: Set<UUID>) {
        guard let selectedWorkspaceId, removedIds.contains(selectedWorkspaceId) else { return }
        if workspaces.isEmpty {
            let workspace = freshStandaloneWorkspace()
            workspaces.append(workspace)
            catchAllProject.addWorkspace(workspace.id)
            self.selectedWorkspaceId = workspace.id
        } else {
            self.selectedWorkspaceId = workspaces.first?.id
        }
    }
}
