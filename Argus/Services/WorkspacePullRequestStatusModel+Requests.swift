import Foundation

extension WorkspacePullRequestStatusModel {
    func startRepositoryResolution(_ request: Request, project: ProjectRuntime) {
        let id = UUID()
        let service = provider
        let host = knownHost(project)
        project.resolutionID = id
        project.resolutionTask = Task { [weak self] in
            let result: Result<RepositoryIdentity, Error>
            do {
                result = .success(
                    try await service.resolveRepository(
                        repositoryPath: request.target.repositoryPath, fetchRemotes: request.fetchRemotes
                    )
                )
            } catch { result = .failure(error) }
            self?.finishRepositoryResolution(result, request: request, id: id, host: host)
        }
        providerTasks[id] = project.resolutionTask
    }

    func finishRepositoryResolution(
        _ result: Result<RepositoryIdentity, Error>, request: Request, id: UUID, host: String?
    ) {
        providerTasks[id] = nil
        defer { drainQueue() }
        if case .failure(let error) = result, let failure = error as? PullRequestStatusError {
            recordHostFailure(failure, host: host)
        }
        guard isEnabled, isActive, !Task.isCancelled,
            let project = projects[request.target.projectID], project.owner == request.projectOwner,
            project.revision == request.revision, project.resolutionID == id
        else { return }
        project.resolutionTask = nil
        project.resolutionID = nil
        switch result {
        case .success(let repository):
            providerIsAvailable = true
            missingCLIUntil = nil
            recordHostSuccess(host: repository.host, manual: request.kind == .manual)
            acceptRepository(repository, project: project, projectID: request.target.projectID)
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            let failure = statusError(error)
            recordProjectFailure(failure, request: request)
            for (workspaceID, preparedRequest) in prepared
            where preparedRequest.target.projectID == request.target.projectID {
                guard isCurrent(preparedRequest) else { continue }
                prepared[workspaceID] = nil
                publishFailure(failure, request: preparedRequest)
            }
        }
    }

    func discoverAssociation(_ operation: RunningRequest) async {
        defer {
            providerTasks[operation.id] = nil
            operation.task = nil
            if operation.association == nil || !isCurrent(operation) {
                finishRequest(operation)
            } else {
                drainQueue()
            }
        }
        guard isCurrent(operation), let repository = operation.repository else { return }
        let request = operation.request
        do {
            let association = try await provider.discoverPullRequest(
                repository: repository, branch: request.branch, previous: states[request.target.workspaceID]?.status,
                repositoryPath: request.target.repositoryPath
            )
            guard isCurrent(operation), !Task.isCancelled else { return }
            providerIsAvailable = true
            missingCLIUntil = nil
            recordHostSuccess(host: repository.host, manual: request.kind == .manual)
            if let association {
                guard association.identity.repository == repository,
                    association.headBranchName == request.branch.branchName,
                    request.branch.upstreamRepository == nil
                        || association.headRepository == request.branch.upstreamRepository
                else {
                    throw PullRequestStatusError.invalidMetadata(
                        "The discovered Pull Request does not match this Workspace.")
                }
                operation.association = association
            } else {
                await revalidateAndPublish(.success(nil), operation: operation)
            }
        } catch {
            guard !(error is CancellationError) else { return }
            let failure = statusError(error)
            recordHostFailure(failure, host: repository.host)
            guard isCurrent(operation), !Task.isCancelled else { return }
            recordProjectFailure(failure, request: request)
            await revalidateAndPublish(.failure(failure), operation: operation)
        }
    }

    func revalidateAndPublish(
        _ result: Result<PullRequestStatus?, PullRequestStatusError>, operation: RunningRequest
    ) async {
        let request = operation.request
        do {
            let current = try await localInputs.readWorktree(target: request.target)
            guard isCurrent(operation), !Task.isCancelled,
                let project = projects[request.target.projectID]
            else { return }
            if normalizedRemotes(current.fetchRemotes) != request.fetchRemotes {
                applyFetchRemotes(current.fetchRemotes, projectID: request.target.projectID, project: project)
                return
            }
            if current.branch != request.branch {
                observe(current.branch, workspaceID: request.target.workspaceID)
                return
            }
            guard operation.repository == project.repository else { return }
            switch result {
            case .success(let status):
                do {
                    if let status { try validateReturnedStatus(status, operation: operation) }
                    publishSuccess(status, operation: operation)
                } catch {
                    publishFailure(statusError(error), request: request)
                }
            case .failure(let error):
                publishFailure(error, request: request)
            }
        } catch {
            guard isCurrent(operation), !(error is CancellationError), !Task.isCancelled else { return }
            clearLocalContext(
                request.target.workspaceID,
                error: error as? PullRequestStatusError
                    ?? .repositoryUnavailable("The worktree's branch and HEAD could not be revalidated.")
            )
        }
    }

    private func validateReturnedStatus(_ status: PullRequestStatus, operation: RunningRequest) throws {
        let request = operation.request
        guard status.identity.repository == operation.repository,
            status.headBranchName == request.branch.branchName,
            request.branch.upstreamRepository == nil
                || status.headRepository == request.branch.upstreamRepository
        else {
            throw PullRequestStatusError.invalidMetadata(
                "The returned Pull Request does not match this Workspace's repository and branch.")
        }
        try operation.association?.validate(status)
    }

    func isCurrent(_ request: Request) -> Bool {
        isEnabled && isActive
            && entries[request.target.workspaceID]?.owner == request.owner
            && entries[request.target.workspaceID]?.target == request.target
            && projects[request.target.projectID]?.owner == request.projectOwner
            && projects[request.target.projectID]?.revision == request.revision
            && entries[request.target.workspaceID]?.branch == request.branch
    }

    func isCurrent(_ operation: RunningRequest) -> Bool {
        !operation.invalidated && running[operation.request.target.workspaceID]?.id == operation.id
            && isCurrent(operation.request)
    }

    func finishRequest(_ operation: RunningRequest) {
        let request = operation.request
        let id = request.target.workspaceID
        guard running[id]?.id == operation.id else { return }
        running[id] = nil
        if entries[id]?.owner == request.owner, let project = projects[request.target.projectID] {
            if allowedDate(project: project, kind: pending[id] ?? .refresh) > now() {
                publishBlocked(id, project: project)
            } else {
                var state = states[id] ?? WorkspacePullRequestState()
                state.isRefreshing = pending[id] != nil || prepared[id] != nil
                publish(state, for: id)
            }
        }
        drainQueue()
    }

    func publishSuccess(_ status: PullRequestStatus?, operation: RunningRequest) {
        let request = operation.request
        let id = request.target.workspaceID
        guard let project = projects[request.target.projectID] else { return }
        let completedAt = now()
        if project.failureGeneration == request.failureGeneration
            || project.retryAt.map({ $0 <= completedAt }) == true
        {
            project.failureCount = 0
            project.failureGeneration = UUID()
            project.retryAt = nil
            project.error = nil
        }
        publish(
            WorkspacePullRequestState(
                status: status, branchName: request.branch.branchName, lastSuccess: completedAt,
                error: hostPause(project), hasLoaded: true
            ), for: id
        )
        entries[id]?.nextRefresh = completedAt.addingTimeInterval(status == nil ? 600 : 60)
        if operation.discovered { entries[id]?.nextDiscovery = completedAt.addingTimeInterval(600) }
    }

    func publishFailure(_ error: PullRequestStatusError, request: Request) {
        let id = request.target.workspaceID
        guard let project = projects[request.target.projectID] else { return }
        var state = states[id] ?? WorkspacePullRequestState()
        state.isRefreshing = false
        state.hasLoaded = true
        state.error = hostPause(project) ?? error
        publish(state, for: id)
        let retryAt = max(
            now().addingTimeInterval(isWorkspaceFailure(error) ? 60 : 0),
            allowedDate(project: project, kind: .discover)
        )
        entries[id]?.nextDiscovery = retryAt
        entries[id]?.nextRefresh = retryAt
    }

    func isWorkspaceFailure(_ error: PullRequestStatusError) -> Bool {
        switch error {
        case .ambiguous, .unverifiedAssociation, .lookupLimit, .invalidMetadata:
            true
        case .githubCLIUnavailable, .unauthenticated, .repositoryUnavailable, .providerTimedOut, .providerFailed,
            .rateLimited, .secondaryRateLimited, .quotaPaused:
            false
        }
    }

    func statusError(_ error: Error) -> PullRequestStatusError {
        error as? PullRequestStatusError ?? .providerFailed("Pull Request status could not be refreshed.")
    }

    func recordProjectFailure(_ error: PullRequestStatusError, request: Request) {
        guard !isWorkspaceFailure(error), let project = projects[request.target.projectID],
            project.owner == request.projectOwner
        else { return }
        if project.retryAt == nil || project.failureGeneration == request.failureGeneration {
            project.failureCount = min(project.failureCount + 1, 3)
            project.failureGeneration = UUID()
            project.retryAt = now().addingTimeInterval([30, 60, 120][project.failureCount - 1])
        }
        project.error = error
        if error == .githubCLIUnavailable {
            missingCLIUntil = now().addingTimeInterval(30)
            providerIsAvailable = false
        } else {
            providerIsAvailable = true
        }
    }
}
