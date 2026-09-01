import Foundation

@MainActor
final class WorkspaceStackObservation {
    static let debounceInterval: TimeInterval = 0.3

    private let repositoryPath: String
    private let reader: any WorkspaceStackReading
    private let watcher: any FileSystemEventWatching
    private let scheduler: any RefreshScheduling
    private var onRefreshing: (@MainActor @Sendable (Bool) -> Void)?
    private var onResult: (@MainActor @Sendable (Result<WorkspaceStackSnapshot, Error>) -> Void)?
    private var loadTask: Task<Void, Never>?
    private var gitCommonDirectory: String?
    private var isRunning = false
    private var pendingRefresh = false
    private var generation: UInt64 = 0
    private var scheduledRefreshId: UUID?
    private var watchId: UUID?

    init(
        repositoryPath: String,
        reader: any WorkspaceStackReading,
        watcher: any FileSystemEventWatching = FSEventsFileWatcher(),
        scheduler: any RefreshScheduling = DispatchRefreshScheduler()
    ) {
        self.repositoryPath = repositoryPath
        self.reader = reader
        self.watcher = watcher
        self.scheduler = scheduler
    }

    deinit {
        loadTask?.cancel()
        watcher.stop()
    }

    func start(
        onRefreshing: @escaping @MainActor @Sendable (Bool) -> Void,
        onResult: @escaping @MainActor @Sendable (Result<WorkspaceStackSnapshot, Error>) -> Void
    ) {
        guard !isRunning else { return }
        self.onRefreshing = onRefreshing
        self.onResult = onResult
        isRunning = true
        generation &+= 1
        refresh()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        scheduler.cancel()
        scheduledRefreshId = nil
        watchId = nil
        watcher.stop()
        gitCommonDirectory = nil
        loadTask?.cancel()
        loadTask = nil
        pendingRefresh = false
        onRefreshing?(false)
        onRefreshing = nil
        onResult = nil
    }

    func refresh() {
        guard isRunning else { return }
        scheduler.cancel()
        scheduledRefreshId = nil
        if loadTask != nil {
            pendingRefresh = true
            return
        }
        let requestGeneration = generation
        loadTask = Task { [weak self, reader, repositoryPath] in
            guard !Task.isCancelled else { return }
            let result: Result<WorkspaceStackSnapshot, Error>
            do {
                result = .success(try await reader.load(repositoryPath: repositoryPath))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.finish(result, generation: requestGeneration)
        }
        onRefreshing?(true)
    }

    private func finish(_ result: Result<WorkspaceStackSnapshot, Error>, generation requestGeneration: UInt64) {
        guard isRunning, generation == requestGeneration else { return }
        if case .success(let snapshot) = result {
            watch(commonDirectory: snapshot.gitCommonDirectory)
        }
        if !pendingRefresh {
            onResult?(result)
        }
        guard isRunning, generation == requestGeneration else { return }
        loadTask = nil
        if pendingRefresh {
            pendingRefresh = false
            refresh()
        } else {
            onRefreshing?(false)
        }
    }

    private func watch(commonDirectory: String) {
        let path = URL(fileURLWithPath: commonDirectory).resolvingSymlinksInPath().standardizedFileURL.path
        guard gitCommonDirectory != path else { return }
        gitCommonDirectory = path
        pendingRefresh = true
        let currentWatchId = UUID()
        watchId = currentWatchId
        watcher.start(paths: [path]) { [weak self] paths in
            guard let self, self.isRunning, self.watchId == currentWatchId else { return }
            self.handleFileEvents(paths, commonDirectory: path)
        }
    }

    private func handleFileEvents(_ paths: [String], commonDirectory: String) {
        guard paths.contains(where: { Self.isRelevantPath($0, commonDirectory: commonDirectory) }) else { return }
        if loadTask != nil {
            pendingRefresh = true
            return
        }
        let refreshId = UUID()
        scheduledRefreshId = refreshId
        scheduler.cancel()
        scheduler.schedule(after: Self.debounceInterval) { [weak self] in
            guard let self, self.isRunning, self.scheduledRefreshId == refreshId else { return }
            self.refresh()
        }
    }

    private static func isRelevantPath(_ path: String, commonDirectory: String) -> Bool {
        guard let relativePath = GitMetadataEventPath.relativePath(path, in: commonDirectory) else { return false }
        return relativePath.isEmpty || GitMetadataEventPath.isRelevant(relativePath)
    }
}
