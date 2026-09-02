import Foundation

extension WorkspacePullRequestStatusModel {
    func finishLocalRead(
        _ result: Result<WorkspacePullRequestProjectInputs, Error>,
        read: LocalRead
    ) {
        localTasks[read.id] = nil
        defer { drainQueue() }
        guard isEnabled, isActive, let project = projects[read.projectID],
            project.owner == read.owner, project.localReadID == read.id
        else { return }
        project.localReadID = nil
        guard !Task.isCancelled, project.revision == read.revision else { return }
        let currentEntries = read.entries.filter {
            entries[$0.target.workspaceID]?.owner == $0.owner
                && entries[$0.target.workspaceID]?.observation == $0.observation
        }
        switch result {
        case .success(let inputs):
            applyFetchRemotes(inputs.fetchRemotes, projectID: read.projectID, project: project)
            for entry in currentEntries {
                let id = entry.target.workspaceID
                switch inputs.worktrees[entry.target.worktreePath] {
                case .success(let branch):
                    observe(branch, workspaceID: id)
                case .failure(let error):
                    clearLocalContext(id, error: error)
                case nil:
                    clearLocalContext(
                        id, error: .repositoryUnavailable("The worktree is no longer registered in this Named Project.")
                    )
                }
            }
            prepareRequests(workspaceIDs: Set(currentEntries.map(\.target.workspaceID)), project: project)
        case .failure(let error):
            finishLocalFailure(error, entries: currentEntries)
        }
    }

    func prepareRequests(workspaceIDs: Set<UUID>, project: ProjectRuntime) {
        for id in prioritizedIDs where workspaceIDs.contains(id) {
            guard let requested = pending[id], running[id] == nil,
                let entry = entries[id], let branch = entry.branch
            else { continue }
            pending[id] = nil
            guard let kind = networkKind(requested, workspaceID: id) else {
                var state = states[id] ?? WorkspacePullRequestState()
                state.isRefreshing = false
                publish(state, for: id)
                continue
            }
            guard allowedDate(project: project, kind: kind) <= now() else {
                pending[id] = kind
                publishBlocked(id, project: project)
                continue
            }
            prepared[id] = Request(
                target: entry.target,
                owner: entry.owner,
                projectOwner: project.owner,
                revision: project.revision,
                branch: branch,
                fetchRemotes: project.fetchRemotes ?? [],
                kind: kind,
                failureGeneration: project.failureGeneration
            )
        }
    }

    func finishLocalFailure(_ error: Error, entries currentEntries: [Entry]) {
        let failure =
            error as? PullRequestStatusError
            ?? .repositoryUnavailable("The Project Repository Root could not be read.")
        for entry in currentEntries {
            let id = entry.target.workspaceID
            guard pending[id] != nil else { continue }
            pending[id] = nil
            var state = states[id] ?? WorkspacePullRequestState()
            state.isRefreshing = false
            state.hasLoaded = true
            state.error = failure
            publish(state, for: id)
            entries[id]?.nextDiscovery = now().addingTimeInterval(60)
            entries[id]?.nextRefresh = now().addingTimeInterval(60)
        }
    }

    @discardableResult
    func applyFetchRemotes(_ remotes: [GitFetchRemote], projectID: UUID, project: ProjectRuntime) -> Bool {
        let normalized = normalizedRemotes(remotes)
        let changed = project.fetchRemotes.map { $0 != normalized } ?? false
        project.fetchRemotes = normalized
        guard changed else { return false }
        invalidateRepository(project)
        for id in targetOrder where entries[id]?.target.projectID == projectID {
            if var state = states[id], state.status != nil, state.error == nil {
                state.error = .repositoryUnavailable(
                    "Repository Identity is being revalidated after the Project's fetch remotes changed."
                )
                publish(state, for: id)
            }
            invalidateRequest(id)
            enqueue(id, kind: .discover)
        }
        return true
    }

    func normalizedRemotes(_ remotes: [GitFetchRemote]) -> [GitFetchRemote] {
        remotes.map { GitFetchRemote(name: $0.name, fetchURLs: $0.fetchURLs.sorted()) }
            .sorted { $0.name < $1.name }
    }

    func observe(_ branch: PullRequestBranchContext, workspaceID: UUID) {
        guard let entry = entries[workspaceID] else { return }
        let previous = entry.branch
        let associationChanged =
            previous?.branchName != branch.branchName
            || previous?.upstreamRepository != branch.upstreamRepository
        if associationChanged { clearAssociation(workspaceID) }
        entries[workspaceID]?.branch = branch
        var state = states[workspaceID] ?? WorkspacePullRequestState()
        state.branchName = branch.branchName
        publish(state, for: workspaceID)
        if previous != branch {
            entries[workspaceID]?.observation = UUID()
            entries[workspaceID]?.nextDiscovery = .distantPast
            entries[workspaceID]?.nextRefresh = .distantPast
            invalidateRequest(workspaceID)
            enqueue(workspaceID, kind: .discover)
        }
    }

    func clearAssociation(_ workspaceID: UUID) {
        var state = states[workspaceID] ?? WorkspacePullRequestState()
        state.status = nil
        state.lastSuccess = nil
        state.error = nil
        state.hasLoaded = false
        publish(state, for: workspaceID)
        entries[workspaceID]?.nextDiscovery = .distantPast
        entries[workspaceID]?.nextRefresh = .distantPast
    }

    func clearLocalContext(_ workspaceID: UUID, error: PullRequestStatusError) {
        invalidateRequest(workspaceID)
        pending[workspaceID] = nil
        entries[workspaceID]?.branch = nil
        entries[workspaceID]?.observation = UUID()
        entries[workspaceID]?.nextDiscovery = now().addingTimeInterval(60)
        entries[workspaceID]?.nextRefresh = now().addingTimeInterval(60)
        publish(WorkspacePullRequestState(error: error, hasLoaded: true), for: workspaceID)
    }

    func acceptRepository(_ repository: RepositoryIdentity, project: ProjectRuntime, projectID: UUID) {
        if let previous = project.repository, previous != repository {
            for id in targetOrder where entries[id]?.target.projectID == projectID {
                clearAssociation(id)
                if let operation = running[id], let resolved = operation.repository, resolved != repository {
                    invalidateRequest(id)
                    enqueue(id, kind: .discover)
                } else if running[id] == nil {
                    enqueue(id, kind: .discover)
                }
            }
        }
        project.repository = repository
        project.resolvedAt = now()
        hostBudgets.repositories[project.repositoryPath] = repository
    }
}
