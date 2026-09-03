import Foundation

extension WorkspaceManager {
    struct PendingWorkspaceStackReveal {
        let project: Project
        let workspaceId: UUID
        let path: String
        let revision: UInt64
    }

    func sidebarItems(for project: Project) -> [WorkspaceSidebarItem] {
        let inputs = project.workspaceIds.compactMap { workspaceId -> WorkspaceStackWorkspace? in
            guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return nil }
            return WorkspaceStackWorkspace(id: workspaceId, path: workspaceStackPath(for: workspace, in: project))
        }
        let snapshot = project.isCatchAll ? nil : workspaceStackSnapshots[project.id]
        return WorkspaceStackLayout.items(workspaces: inputs, snapshot: snapshot, mainBranch: project.mainBranch)
    }

    func stackGroup(for workspaceId: UUID, in projectId: UUID) -> WorkspaceStackGroup? {
        guard let project = projects.first(where: { $0.id == projectId }) else { return nil }
        for item in sidebarItems(for: project) {
            if case .stack(let group) = item, group.workspaceIds.contains(workspaceId) {
                return group
            }
        }
        return nil
    }

    func cancelPendingWorkspaceStackReveal(in projectId: UUID) {
        if pendingWorkspaceStackReveal?.project.id == projectId {
            pendingWorkspaceStackReveal = nil
        }
    }

    func retainPendingWorkspaceStackRevealIfNeeded(for workspace: Workspace) {
        guard isObservingWorkspaceStacks,
            selectedWorkspaceId == workspace.id,
            let project = project(for: workspace.id),
            workspace.projectId == project.id,
            let path = workspaceStackPath(for: workspace, in: project),
            workspaceStackSnapshots[project.id]?.worktrees.contains(where: { $0.path == path }) != true
        else { return }
        pendingWorkspaceStackReveal = PendingWorkspaceStackReveal(
            project: project, workspaceId: workspace.id, path: path, revision: workspaceRevealRevision)
        refreshWorkspaceStacks(in: project.id)
    }

    func toggleWorkspaceStack(_ stackId: String, in projectId: UUID) {
        cancelPendingWorkspaceStackReveal(in: projectId)
        guard let project = projects.first(where: { $0.id == projectId }),
            sidebarItems(for: project).contains(where: {
                if case .stack(let group) = $0 { return group.id == stackId }
                return false
            })
        else { return }
        if !project.collapsedStackIds.insert(stackId).inserted {
            project.collapsedStackIds.remove(stackId)
        }
        saveSession()
    }

    @discardableResult
    func reorderWorkspace(
        in projectId: UUID,
        moving workspaceId: UUID,
        before targetWorkspaceId: UUID
    ) -> Bool {
        guard let project = projects.first(where: { $0.id == projectId }) else { return false }
        let items = sidebarItems(for: project)
        guard let source = items.firstIndex(where: { $0.workspaceIds.contains(workspaceId) }),
            let target = items.firstIndex(where: { $0.workspaceIds.contains(targetWorkspaceId) }),
            source != target
        else { return false }
        return moveSidebarItem(in: project, items: items, from: source, to: source < target ? target - 1 : target)
    }

    func canMoveWorkspace(in projectId: UUID, moving workspaceId: UUID, offset: Int) -> Bool {
        guard offset == -1 || offset == 1,
            let project = projects.first(where: { $0.id == projectId })
        else { return false }
        let items = sidebarItems(for: project)
        guard let source = items.firstIndex(where: { $0.workspaceIds.contains(workspaceId) }) else { return false }
        return items.indices.contains(source + offset)
    }

    @discardableResult
    func moveWorkspace(in projectId: UUID, moving workspaceId: UUID, offset: Int) -> Bool {
        guard offset == -1 || offset == 1,
            let project = projects.first(where: { $0.id == projectId })
        else { return false }
        let items = sidebarItems(for: project)
        guard let source = items.firstIndex(where: { $0.workspaceIds.contains(workspaceId) }),
            items.indices.contains(source + offset)
        else { return false }
        return moveSidebarItem(in: project, items: items, from: source, to: source + offset)
    }

    private func moveSidebarItem(
        in project: Project,
        items: [WorkspaceSidebarItem],
        from source: Int,
        to destination: Int
    ) -> Bool {
        guard source != destination else { return false }
        if items.allSatisfy({ $0.workspaceIds.count == 1 }),
            items.flatMap(\.workspaceIds) == project.workspaceIds
        {
            project.moveWorkspace(from: source, to: destination)
        } else {
            var reordered = items
            reordered.insert(reordered.remove(at: source), at: destination)
            project.workspaceIds = reordered.flatMap(\.workspaceIds)
        }
        syncFlatWorkspaceOrderToSidebarOrder()
        saveSession()
        return true
    }

    private func syncFlatWorkspaceOrderToSidebarOrder() {
        let orderedIds = sidebarOrderedWorkspaces.map(\.workspace.id)
        let indexById = Dictionary(
            uniqueKeysWithValues: orderedIds.enumerated().map { ($0.element, $0.offset) }
        )
        workspaces.sort { lhs, rhs in
            (indexById[lhs.id] ?? Int.max) < (indexById[rhs.id] ?? Int.max)
        }
    }

    func startWorkspaceStackObservations() {
        guard !isObservingWorkspaceStacks else { return }
        isObservingWorkspaceStacks = true
        reconcileWorkspaceStackObservations()
    }

    func stopWorkspaceStackObservations() {
        pendingWorkspaceStackReveal = nil
        isObservingWorkspaceStacks = false
        let observations = workspaceStackObservations.values.map(\.observation)
        workspaceStackObservations.removeAll()
        observations.forEach { $0.stop() }
        workspaceStackSnapshots.removeAll()
        workspaceStackErrors.removeAll()
        refreshingWorkspaceStackProjectIds.removeAll()
    }

    func refreshWorkspaceStacks(in projectId: UUID) {
        guard let entry = workspaceStackObservations[projectId],
            ownsWorkspaceStackObservation(entry.observation, for: entry.project)
        else { return }
        entry.observation.refresh()
    }

    func reconcileWorkspaceStackObservations() {
        guard isObservingWorkspaceStacks else { return }
        for (projectId, entry) in workspaceStackObservations
        where !projects.contains(where: { $0 === entry.project }) {
            cancelPendingWorkspaceStackReveal(in: projectId)
            workspaceStackObservations.removeValue(forKey: projectId)
            entry.observation.stop()
            workspaceStackSnapshots.removeValue(forKey: projectId)
            workspaceStackErrors.removeValue(forKey: projectId)
            refreshingWorkspaceStackProjectIds.remove(projectId)
        }
        for project in namedProjects where workspaceStackObservations[project.id] == nil {
            startWorkspaceStackObservation(for: project)
        }
    }

    private func startWorkspaceStackObservation(for project: Project) {
        let observation = WorkspaceStackObservation(
            repositoryPath: project.repositoryPath, reader: workspaceStackReader)
        workspaceStackObservations[project.id] = (project, observation)
        observation.start(
            onRefreshing: { [weak self, weak project, weak observation] isRefreshing in
                guard let self, let project, let observation,
                    self.ownsWorkspaceStackObservation(observation, for: project)
                else { return }
                if isRefreshing {
                    self.refreshingWorkspaceStackProjectIds.insert(project.id)
                } else {
                    self.refreshingWorkspaceStackProjectIds.remove(project.id)
                }
            },
            onResult: { [weak self, weak project, weak observation] result in
                guard let self, let project, let observation,
                    self.ownsWorkspaceStackObservation(observation, for: project)
                else { return }
                self.receiveWorkspaceStackResult(result, for: project)
            }
        )
    }

    private func ownsWorkspaceStackObservation(_ observation: WorkspaceStackObservation, for project: Project) -> Bool {
        isObservingWorkspaceStacks
            && projects.contains(where: { $0 === project })
            && workspaceStackObservations[project.id]?.observation === observation
    }

    private func receiveWorkspaceStackResult(_ result: Result<WorkspaceStackSnapshot, Error>, for project: Project) {
        switch result {
        case .success(let snapshot):
            workspaceStackSnapshots[project.id] = snapshot
            workspaceStackErrors[project.id] = snapshot.issue
            for workspace in workspaces where project.containsWorkspace(workspace.id) {
                guard let path = workspaceStackPath(for: workspace, in: project),
                    let worktree = snapshot.worktrees.first(where: { $0.path == path })
                else { continue }
                if workspace.branchName != worktree.branch {
                    workspace.branchName = worktree.branch
                }
            }
            revealPendingWorkspaceStackIfReady(for: project, snapshot: snapshot)
        case .failure(let error):
            cancelPendingWorkspaceStackReveal(in: project.id)
            workspaceStackSnapshots.removeValue(forKey: project.id)
            workspaceStackErrors[project.id] = error.localizedDescription
        }
    }

    private func revealPendingWorkspaceStackIfReady(for project: Project, snapshot: WorkspaceStackSnapshot) {
        guard let pending = pendingWorkspaceStackReveal, pending.project === project else { return }
        guard selectedWorkspaceId == pending.workspaceId,
            workspaceRevealRevision == pending.revision,
            project.isExpanded,
            collection(containing: project.id)?.isExpanded != false,
            self.project(for: pending.workspaceId) === project,
            let workspace = workspaces.first(where: { $0.id == pending.workspaceId }),
            workspace.projectId == project.id,
            workspaceStackPath(for: workspace, in: project) == pending.path
        else {
            cancelPendingWorkspaceStackReveal(in: project.id)
            return
        }
        guard snapshot.worktrees.contains(where: { $0.path == pending.path }) else { return }
        pendingWorkspaceStackReveal = nil
        guard let group = stackGroup(for: workspace.id, in: project.id) else { return }
        project.collapsedStackIds.remove(group.id)
        workspaceRevealRevision &+= 1
    }

    private func workspaceStackPath(for workspace: Workspace, in project: Project) -> String? {
        guard !project.isCatchAll else { return nil }
        let path: String?
        switch workspace.workspaceType {
        case .mainCheckout:
            path = project.repositoryPath
        case .worktree:
            path = workspace.worktreePath
        case .external:
            path = nil
        }
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
