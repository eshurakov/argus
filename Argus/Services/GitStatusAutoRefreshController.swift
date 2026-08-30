import CoreServices
import Foundation

protocol FileSystemEventWatching: AnyObject, Sendable {
    func start(paths: [String], onEvents: @escaping @MainActor @Sendable ([String]) -> Void)
    func stop()
}

@MainActor
protocol RefreshScheduling: AnyObject {
    func schedule(after delay: TimeInterval, operation: @escaping @MainActor @Sendable () async -> Void)
    func cancel()
}

@MainActor
final class GitStatusAutoRefreshController {
    static let debounceInterval: TimeInterval = 0.3
    static let cooldownInterval: TimeInterval = 1.0

    private let watcher: any FileSystemEventWatching
    private let scheduler: any RefreshScheduling
    private let now: () -> Date
    private var refresh: (@MainActor @Sendable () async -> Void)?
    private var currentRootPath: String?
    private var lastRefreshCompletedAt: Date?

    convenience init() {
        self.init(
            watcher: FSEventsFileWatcher(),
            scheduler: DispatchRefreshScheduler()
        )
    }

    init(
        watcher: any FileSystemEventWatching,
        scheduler: any RefreshScheduling,
        now: @escaping () -> Date = Date.init
    ) {
        self.watcher = watcher
        self.scheduler = scheduler
        self.now = now
    }

    func start(rootPath: String, refresh: @escaping @MainActor @Sendable () async -> Void) {
        self.refresh = refresh
        guard currentRootPath != rootPath else { return }
        if currentRootPath != nil {
            scheduler.cancel()
            watcher.stop()
        }
        currentRootPath = rootPath
        watcher.start(paths: Self.watchedPaths(for: rootPath)) { [weak self] paths in
            self?.handleFileEvents(paths)
        }
    }

    func stop() {
        scheduler.cancel()
        watcher.stop()
        currentRootPath = nil
        refresh = nil
    }

    func handleFileEvents(_ paths: [String]) {
        let relevantPaths = paths.filter(shouldRefresh(for:))
        guard !relevantPaths.isEmpty else { return }

        if !isOutsideCooldown {
            guard relevantPaths.contains(where: isGitReferenceEvent) else { return }
            scheduleRefresh(after: max(Self.debounceInterval, remainingCooldownInterval))
            return
        }

        scheduleRefresh(after: Self.debounceInterval)
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        scheduler.cancel()
        scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            await self.refresh?()
            self.lastRefreshCompletedAt = self.now()
        }
    }

    private var isOutsideCooldown: Bool {
        guard let lastRefreshCompletedAt else { return true }
        return now().timeIntervalSince(lastRefreshCompletedAt) >= Self.cooldownInterval
    }

    private var remainingCooldownInterval: TimeInterval {
        guard let lastRefreshCompletedAt else { return 0 }
        return max(0, Self.cooldownInterval - now().timeIntervalSince(lastRefreshCompletedAt))
    }

    private func shouldRefresh(for path: String) -> Bool {
        let components = path.split(separator: "/")
        guard components.contains(".git") else { return true }

        // Index writes are deliberately ignored because reading status can
        // cause more Git metadata activity. Ref and HEAD-log writes, however,
        // are the only observable signal for metadata-only operations such as
        // committing already-staged files.
        return isGitReferenceEvent(path)
    }

    private func isGitReferenceEvent(_ path: String) -> Bool {
        path.hasSuffix("/HEAD")
            || path.hasSuffix("/packed-refs")
            || path.hasSuffix("/config")
            || path.hasSuffix("/config.worktree")
            || path.contains("/refs/heads/")
            || path.contains("/refs/remotes/")
            || path.contains("/refs/branch-metadata/")
            || path.contains("/logs/refs/heads/")
            || path.contains("/logs/refs/remotes/")
    }

    nonisolated static func watchedPaths(for rootPath: String) -> [String] {
        let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
        let dotGitURL = rootURL.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: dotGitURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return [rootURL.path]
        }

        guard let contents = try? String(contentsOf: dotGitURL, encoding: .utf8),
            let firstLine = contents.split(whereSeparator: \.isNewline).first,
            firstLine.hasPrefix("gitdir:")
        else {
            return [rootURL.path]
        }

        let gitDirectoryPath = firstLine.dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespaces)
        let gitDirectoryURL = URL(fileURLWithPath: gitDirectoryPath, relativeTo: rootURL)
            .standardizedFileURL
        let commonDirectoryURL: URL
        let commonDirectoryFile = gitDirectoryURL.appendingPathComponent("commondir")
        if let commonDirectoryPath = try? String(contentsOf: commonDirectoryFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !commonDirectoryPath.isEmpty
        {
            commonDirectoryURL =
                URL(
                    fileURLWithPath: commonDirectoryPath,
                    relativeTo: gitDirectoryURL
                ).standardizedFileURL
        } else {
            commonDirectoryURL = gitDirectoryURL
        }
        return Array(Set([rootURL.path, gitDirectoryURL.path, commonDirectoryURL.path])).sorted()
    }
}

@MainActor
final class WorkspaceFilesAutoRefreshController {
    static let debounceInterval: TimeInterval = 0.3

    private let watcher: any FileSystemEventWatching
    private let scheduler: any RefreshScheduling
    private var refresh: (@MainActor @Sendable () async -> Void)?
    private var currentRootPath: String?

    convenience init() {
        self.init(
            watcher: FSEventsFileWatcher(),
            scheduler: DispatchRefreshScheduler()
        )
    }

    init(
        watcher: any FileSystemEventWatching,
        scheduler: any RefreshScheduling
    ) {
        self.watcher = watcher
        self.scheduler = scheduler
    }

    func start(rootPath: String, refresh: @escaping @MainActor @Sendable () async -> Void) {
        let standardizedRootPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        self.refresh = refresh
        guard currentRootPath != standardizedRootPath else { return }

        if currentRootPath != nil {
            scheduler.cancel()
            watcher.stop()
        }
        currentRootPath = standardizedRootPath
        watcher.start(paths: [standardizedRootPath]) { [weak self] paths in
            self?.handleFileEvents(paths, rootPath: standardizedRootPath)
        }
    }

    func stop() {
        scheduler.cancel()
        watcher.stop()
        currentRootPath = nil
        refresh = nil
    }

    private func handleFileEvents(_ paths: [String], rootPath: String) {
        guard currentRootPath == rootPath, !paths.isEmpty else { return }
        scheduler.cancel()
        scheduler.schedule(after: Self.debounceInterval) { [weak self] in
            guard let self, self.currentRootPath == rootPath else { return }
            await self.refresh?()
        }
    }
}

final class FSEventsFileWatcher: FileSystemEventWatching, @unchecked Sendable {
    static let latency: CFTimeInterval = 0.3

    private let callbackBox = FSEventsCallbackBox()
    private let queue = DispatchQueue(label: "com.argus.filesystem.fsevents")
    private var stream: FSEventStreamRef?

    func start(paths: [String], onEvents: @escaping @MainActor @Sendable ([String]) -> Void) {
        stop()
        callbackBox.onEvents = onEvents

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let standardizedPaths =
            paths.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            } as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        )
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fseventsCallback,
            &context,
            standardizedPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            flags
        )

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

private final class FSEventsCallbackBox: @unchecked Sendable {
    var onEvents: (@MainActor @Sendable ([String]) -> Void)?
}

private let fseventsCallback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
    guard let info else { return }
    let box = Unmanaged<FSEventsCallbackBox>.fromOpaque(info).takeUnretainedValue()
    let paths = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray)
        .compactMap { $0 as? String }
    Task { @MainActor in
        box.onEvents?(paths)
    }
}

@MainActor
final class DispatchRefreshScheduler: RefreshScheduling {
    private var workItem: DispatchWorkItem?

    func schedule(after delay: TimeInterval, operation: @escaping @MainActor @Sendable () async -> Void) {
        cancel()
        let item = DispatchWorkItem {
            Task { @MainActor in await operation() }
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
