import Foundation
import Testing

@testable import Argus

@Suite
struct GitStatusAutoRefreshMetadataTests {
    @Test
    @MainActor
    func refreshesForSharedRefsAndConfiguration() async {
        let watcher = MetadataWatcher()
        let scheduler = MetadataScheduler()
        let controller = GitStatusAutoRefreshController(watcher: watcher, scheduler: scheduler)
        var refreshCount = 0
        controller.start(rootPath: "/repo") { refreshCount += 1 }

        for path in [
            "/repo/.git/refs/remotes/origin/main",
            "/repo/.git/refs/branch-metadata/feature",
            "/repo/.git/packed-refs",
            "/repo/.git/config"
        ] {
            watcher.emit(paths: [path])
            await scheduler.runScheduled()
        }

        #expect(refreshCount == 4)
    }
}

private final class MetadataWatcher: FileSystemEventWatching, @unchecked Sendable {
    var onEvents: (@MainActor @Sendable ([String]) -> Void)?

    func start(paths _: [String], onEvents: @escaping @MainActor @Sendable ([String]) -> Void) {
        self.onEvents = onEvents
    }

    func stop() {}

    @MainActor
    func emit(paths: [String]) {
        onEvents?(paths)
    }
}

@MainActor
private final class MetadataScheduler: RefreshScheduling {
    private var scheduledOperation: (@MainActor @Sendable () async -> Void)?

    func schedule(
        after _: TimeInterval,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        scheduledOperation = operation
    }

    func cancel() {
        scheduledOperation = nil
    }

    func runScheduled() async {
        let operation = scheduledOperation
        scheduledOperation = nil
        await operation?()
    }
}
