import Foundation
import Testing

@testable import Argus

@MainActor
final class ControlledWorkspaceStackReader: WorkspaceStackReading {
    var requests: [String] = []
    var completed: Set<Int> = []
    private var pending: [Int: CheckedContinuation<WorkspaceStackSnapshot, Error>] = [:]

    func load(repositoryPath: String) async throws -> WorkspaceStackSnapshot {
        let requestId = requests.count
        requests.append(repositoryPath)
        defer { completed.insert(requestId) }
        return try await withCheckedThrowingContinuation { pending[requestId] = $0 }
    }

    func startAndLoad(_ fixture: WorkspaceStackTestFixture) async {
        fixture.manager.startWorkspaceStackObservations()
        await waitForStackState { self.requests.count == 1 }
        complete(0, with: .success(fixture.snapshot))
        await waitForStackState { self.requests.count == 2 }
        complete(1, with: .success(fixture.snapshot))
        await waitForStackState { !fixture.manager.refreshingWorkspaceStackProjectIds.contains(fixture.project.id) }
    }

    func complete(_ requestId: Int, with result: Result<WorkspaceStackSnapshot, Error>) {
        let continuation = pending.removeValue(forKey: requestId)
        #expect(continuation != nil)
        continuation?.resume(with: result)
    }

    func cancelAll() {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

enum StackObservationError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Stack discovery unavailable" }
}

@MainActor
final class StackObservationFixture {
    let reader = ControlledWorkspaceStackReader()
    let watcher = StackEventWatcher()
    let scheduler = StackRefreshScheduler()
    let snapshot = WorkspaceStackSnapshot(
        gitCommonDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-stack-observation-\(UUID().uuidString)/common.git")
            .resolvingSymlinksInPath().path,
        worktrees: [], parents: [:]
    )
    let observation: WorkspaceStackObservation
    var results: [WorkspaceStackSnapshot] = []
    var refreshing: [Bool] = []

    init() {
        observation = WorkspaceStackObservation(
            repositoryPath: snapshot.gitCommonDirectory + "/repository",
            reader: reader, watcher: watcher, scheduler: scheduler
        )
    }

    func start() {
        observation.start(
            onRefreshing: { [weak self] in self?.refreshing.append($0) },
            onResult: { [weak self] result in
                if case .success(let snapshot) = result { self?.results.append(snapshot) }
            }
        )
    }

    func startAndLoad() async {
        start()
        await waitForStackState { self.reader.requests.count == 1 }
        await complete(0, with: snapshot)
        await waitForStackState { self.reader.requests.count == 2 }
        await complete(1, with: snapshot)
    }

    func complete(_ requestId: Int, with snapshot: WorkspaceStackSnapshot) async {
        reader.complete(requestId, with: .success(snapshot))
        await waitForStackState { self.reader.completed.contains(requestId) }
        await Task.yield()
    }

    func stop() {
        observation.stop()
        reader.cancelAll()
    }
}

final class StackEventWatcher: FileSystemEventWatching, @unchecked Sendable {
    var onEvents: (@MainActor @Sendable ([String]) -> Void)?
    var startedPaths: [String] = []
    var stopCount = 0

    func start(paths: [String], onEvents: @escaping @MainActor @Sendable ([String]) -> Void) {
        startedPaths.append(contentsOf: paths)
        self.onEvents = onEvents
    }

    func stop() { stopCount += 1 }

    @MainActor
    func emit(_ paths: [String]) { onEvents?(paths) }
}

@MainActor
final class StackRefreshScheduler: RefreshScheduling {
    var delays: [TimeInterval] = []
    var operation: (@MainActor @Sendable () async -> Void)?

    func schedule(after delay: TimeInterval, operation: @escaping @MainActor @Sendable () async -> Void) {
        delays.append(delay)
        self.operation = operation
    }

    func cancel() { operation = nil }

    func runScheduled() async {
        let scheduled = operation
        operation = nil
        await scheduled?()
    }
}

@MainActor
func waitForStackState(_ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(condition())
}
