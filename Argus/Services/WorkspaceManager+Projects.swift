import Foundation

extension WorkspaceManager {
    func createProject(
        repositoryPath: String,
        displayName: String? = nil,
        mainBranchOverride: String? = nil
    ) async -> Project? {
        guard let repositoryRoot = try? await worktreeService.canonicalRepositoryRoot(for: repositoryPath),
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
            let worktreePath = try await worktreeService.createWorktree(
                projectId: projectId,
                repositoryPath: project.repositoryPath,
                branchName: branchName,
                createNewBranch: createNewBranch
            )
            let workspace = Workspace(
                title: branchName,
                workingDirectory: worktreePath,
                projectId: projectId,
                branchName: branchName,
                workspaceType: .worktree,
                worktreePath: worktreePath
            )
            if let customTitle {
                workspace.setCustomTitle(customTitle)
            }
            workspaces.append(workspace)
            project.addWorkspace(workspace.id)
            selectedWorkspaceId = workspace.id
            // Persist an optional custom name and the new Workspace Root
            // before a later application crash can discard them.
            saveSession()
            return workspace
        } catch let error as WorktreeError {
            lastWorkspaceCreationError = error
            print("Failed to create worktree workspace: \(error.localizedDescription)")
            return nil
        } catch {
            print("Failed to create worktree workspace: \(error.localizedDescription)")
            return nil
        }
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
