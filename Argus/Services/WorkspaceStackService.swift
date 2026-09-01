import Foundation

protocol WorkspaceStackReading: Sendable {
    func load(repositoryPath: String) async throws -> WorkspaceStackSnapshot
}

struct WorkspaceStackService: WorkspaceStackReading {
    private let reader: RecordedBaseBranchReader

    init(reader: RecordedBaseBranchReader = RecordedBaseBranchReader()) {
        self.reader = reader
    }

    func load(repositoryPath: String) async throws -> WorkspaceStackSnapshot {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try reader.read(repositoryPath: repositoryPath)
        }
        return try await withTaskCancellationHandler {
            let snapshot = try await worker.value
            try Task.checkCancellation()
            return snapshot
        } onCancel: {
            worker.cancel()
        }
    }
}
