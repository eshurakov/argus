import Foundation

extension WorkspacePullRequestStatusModel {
    @MainActor
    final class RunningBatch {
        let id = UUID()
        let host: String
        let operations: [RunningRequest]
        let identities: [PullRequestIdentity]

        init(host: String, operations: [RunningRequest], identities: [PullRequestIdentity]) {
            self.host = host
            self.operations = operations
            self.identities = identities
        }
    }

    func flushBatches() {
        var hosts: [String] = []
        var ready: [String: [RunningRequest]] = [:]
        for id in prioritizedIDs {
            guard let operation = running[id], operation.task == nil, operation.batchID == nil,
                isCurrent(operation), let association = operation.association,
                let project = projects[operation.request.target.projectID]
            else { continue }
            guard allowedDate(project: project, kind: operation.request.kind) <= now() else {
                running[id] = nil
                pending[id] = operation.request.kind
                publishBlocked(id, project: project)
                continue
            }
            let host = association.identity.repository.host
            if ready[host] == nil { hosts.append(host) }
            ready[host, default: []].append(operation)
        }
        for host in hosts {
            guard hasProviderCapacity else { return }
            guard batches[host] == nil, !hasPreparations(for: host), let operations = ready[host] else { continue }
            var seen = Set<PullRequestIdentity>()
            let identities = operations.compactMap(\.association?.identity).filter { seen.insert($0).inserted }
            let selected = Array(identities.prefix(PullRequestStatusBatch.limit))
            let members = operations.filter { operation in
                operation.association.map { selected.contains($0.identity) } == true
            }
            let batch = RunningBatch(host: host, operations: members, identities: selected)
            for operation in members { operation.batchID = batch.id }
            batches[host] = batch
            providerTasks[batch.id] = Task { [weak self] in await self?.performBatch(batch) }
        }
    }

    func hasPreparations(for host: String) -> Bool {
        for project in projects.values where project.localReadID != nil || project.resolutionID != nil {
            if knownHost(project) == nil || knownHost(project) == host { return true }
        }
        for id in targetOrder {
            guard let entry = entries[id], let project = projects[entry.target.projectID],
                knownHost(project) == nil || knownHost(project) == host
            else { continue }
            if let operation = running[id], isCurrent(operation), operation.association == nil { return true }
            if let kind = prepared[id]?.kind ?? pending[id], allowedDate(project: project, kind: kind) <= now() {
                return true
            }
        }
        return false
    }

    func performBatch(_ batch: RunningBatch) async {
        defer {
            providerTasks[batch.id] = nil
            if batches[batch.host]?.id == batch.id { batches[batch.host] = nil }
            for operation in batch.operations { finishRequest(operation) }
            drainQueue()
        }
        guard let first = batch.operations.first else { return }
        do {
            let response = try await provider.refreshPullRequests(
                batch.identities, repositoryPath: first.request.target.repositoryPath
            )
            recordQuota(response, host: batch.host)
            recordHostSuccess(host: batch.host, manual: batch.operations.contains { $0.request.kind == .manual })
            guard !Task.isCancelled else { return }
            for operation in batch.operations where isCurrent(operation) {
                guard let association = operation.association else { continue }
                let result =
                    response.results[association.identity]
                    ?? .failure(.invalidMetadata("The GraphQL batch omitted this Pull Request."))
                if case .failure(let error) = result {
                    recordProjectFailure(error, request: operation.request)
                }
                await revalidateAndPublish(result.map(Optional.some), operation: operation)
            }
        } catch {
            guard !(error is CancellationError) else { return }
            let failure = statusError(error)
            recordHostFailure(failure, host: batch.host)
            guard !Task.isCancelled else { return }
            for operation in batch.operations where isCurrent(operation) {
                recordProjectFailure(failure, request: operation.request)
                await revalidateAndPublish(.failure(failure), operation: operation)
            }
        }
    }
}
