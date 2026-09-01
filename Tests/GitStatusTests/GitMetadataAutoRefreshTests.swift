import Foundation
import Testing

@testable import Argus

// Synchronous Git setup must not delay another case's MainActor event callbacks.
@Suite(.serialized)
@MainActor
struct GitMetadataAutoRefreshTests {
    @Test(arguments: GitMetadataRepositoryLayout.allCases)
    func defersConfigProviderAndReferenceEventsDuringCooldown(layout: GitMetadataRepositoryLayout) async throws {
        let fixture = try GitMetadataRefreshRepository(layout: layout)
        defer { fixture.directory.remove() }
        let watcher = RecordingFileSystemEventWatcher()
        let scheduler = RecordingRefreshScheduler()
        var currentTime = Date(timeIntervalSince1970: 100)
        let controller = GitStatusAutoRefreshController(watcher: watcher, scheduler: scheduler, now: { currentTime })
        defer { controller.stop() }
        var refreshCount = 0
        controller.start(rootPath: fixture.root.path) { refreshCount += 1 }
        watcher.emit(paths: [fixture.root.appendingPathComponent("file.txt").path])
        await scheduler.runScheduled()
        currentTime = Date(timeIntervalSince1970: 100.5)
        let commonEvents = [
            "config", "config.worktree", "gh-stack", "HEAD", "packed-refs", "refs", "refs/heads", "refs/heads/feature",
            "refs/branch-metadata", "refs/branch-metadata/feature/child", "refs/remotes", "refs/remotes/origin",
            "refs/remotes/origin/main", "refs/remotes/upstream", "refs/remotes/upstream/main", "logs/HEAD",
            "logs/refs/heads/feature", "logs/refs/remotes/origin/main", "logs/refs/remotes/upstream/main", "worktrees"
        ].map { fixture.commonDirectory.appendingPathComponent($0).path }
        let administrativeEvents = ["HEAD", "config.worktree", "gh-stack", "gitdir", "commondir", "locked"]
            .flatMap { path in
                [fixture.gitDirectory, fixture.siblingDirectory].map { $0.appendingPathComponent(path).path }
            }
        let registrationEvents = [
            fixture.siblingDirectory.path, fixture.commonDirectory.appendingPathComponent("worktrees/new").path
        ]
        let events = commonEvents + administrativeEvents + registrationEvents
        for event in events { watcher.emit(paths: [event]) }

        #expect(scheduler.scheduledDelays == [0.3] + Array(repeating: 0.5, count: events.count))
        watcher.emit(paths: [fixture.root.path, fixture.root.appendingPathComponent("HEAD").path])
        watcher.emit(paths: [fixture.root.appendingPathComponent("refs/heads/source.txt").path])
        #expect(scheduler.scheduledDelays.count == events.count + 1)
        await scheduler.runScheduled()
        #expect(refreshCount == 2)
    }

    @Test(arguments: GitMetadataRepositoryLayout.allCases)
    func suppressesIndexObjectAndIrrelevantLogNoise(layout: GitMetadataRepositoryLayout) async throws {
        let fixture = try GitMetadataRefreshRepository(layout: layout)
        defer { fixture.directory.remove() }
        let watcher = RecordingFileSystemEventWatcher()
        let scheduler = RecordingRefreshScheduler()
        let controller = GitStatusAutoRefreshController(watcher: watcher, scheduler: scheduler)
        defer { controller.stop() }
        controller.start(rootPath: fixture.root.path) {}
        let noise = [
            "index", "index.lock", "objects", "objects/ab/cdef", "logs", "logs/refs/tags/release",
            "refs/tags/release", "config.lock", "config.worktree.lock", "refs/remotes/upstream/main.lock",
            "gh-stack.lock", "packed-refs.lock", "refs/branch-metadata/feature.lock"
        ]
        for directory in [fixture.commonDirectory, fixture.gitDirectory, fixture.siblingDirectory] {
            watcher.emit(paths: noise.map { directory.appendingPathComponent($0).path })
        }
        watcher.emit(paths: [fixture.commonDirectory.path, fixture.root.appendingPathComponent(".git").path])

        #expect(scheduler.scheduledDelays.isEmpty)
        watcher.emit(paths: [fixture.root.path])
        #expect(scheduler.scheduledDelays == [0.3])
    }

    @Test(arguments: [GitMetadataRepositoryLayout.linked, .separate, .split])
    func observesMetadataCreationRemovalAndPackingOnActualWatchRoots(layout: GitMetadataRepositoryLayout) async throws {
        let fixture = try GitMetadataRefreshRepository(layout: layout)
        defer { fixture.directory.remove() }
        let watcher = MetadataRecordingWatcher()
        let scheduler = RecordingRefreshScheduler()
        let controller = GitStatusAutoRefreshController(
            watcher: watcher, scheduler: scheduler, now: { Date(timeIntervalSince1970: 100) })
        defer { controller.stop() }
        controller.start(rootPath: fixture.root.path) {}
        let files = [
            fixture.commonDirectory.appendingPathComponent("config"),
            fixture.gitDirectory.appendingPathComponent("config.worktree"),
            fixture.commonDirectory.appendingPathComponent("gh-stack"),
            fixture.siblingDirectory.appendingPathComponent("gh-stack")
        ]
        for (index, file) in files.enumerated() {
            let previousCount = watcher.events.count
            let content =
                file.lastPathComponent == "gh-stack"
                ? #"{"schemaVersion":1,"stacks":[]}"# : "[branch \"main\"]\nbase = parent\n"
            try content.write(to: file, atomically: true, encoding: .utf8)
            try await waitForEvent(file, after: previousCount, watcher: watcher)
            #expect(scheduler.scheduledDelays.last == (index == 0 ? 0.3 : 1.0))
            await scheduler.runScheduled()
        }
        let removed = fixture.siblingDirectory.appendingPathComponent("gh-stack")
        let beforeRemoval = watcher.events.count
        try FileManager.default.removeItem(at: removed)
        try await waitForEvent(removed, after: beforeRemoval, watcher: watcher)
        #expect(scheduler.scheduledDelays.last == 1.0)
        await scheduler.runScheduled()
        try await observePackedGraphite(fixture: fixture, watcher: watcher, scheduler: scheduler)
    }

    @Test(arguments: ["git data\nwith spaces ", "git data with trailing spaces  "], [false, true])
    func oddGitDirectoryPathsStillTriggerMetadataRefresh(directoryName: String, linked: Bool) async throws {
        let fixture = try GitMetadataRefreshRepository(layout: .separate, commonDirectoryName: directoryName)
        defer { fixture.directory.remove() }
        let checkout =
            linked ? fixture.directory.url.appendingPathComponent("sibling", isDirectory: true) : fixture.root
        let gitDirectory = linked ? fixture.siblingDirectory : fixture.gitDirectory
        if linked {
            try "\(fixture.commonDirectory.path)\n".write(
                to: gitDirectory.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        }
        let watcher = MetadataRecordingWatcher()
        let scheduler = RecordingRefreshScheduler()
        let controller = GitStatusAutoRefreshController(
            watcher: watcher, scheduler: scheduler, now: { Date(timeIntervalSince1970: 100) })
        defer { controller.stop() }
        var refreshCount = 0
        controller.start(rootPath: checkout.path) { refreshCount += 1 }
        let metadata = fixture.commonDirectory.appendingPathComponent("gh-stack")
        let beforeCreation = watcher.events.count
        try #"{"schemaVersion":1,"stacks":[]}"#.write(to: metadata, atomically: true, encoding: .utf8)
        try await waitForEvent(metadata, after: beforeCreation, watcher: watcher)
        #expect(scheduler.scheduledDelays.last == 0.3)
        await scheduler.runScheduled()
        #expect(refreshCount == 1)

        let configuration = gitDirectory.appendingPathComponent("config.worktree")
        let beforeConfiguration = watcher.events.count
        try "[branch \"main\"]\nbase = parent\n".write(to: configuration, atomically: true, encoding: .utf8)
        try await waitForEvent(configuration, after: beforeConfiguration, watcher: watcher)
        #expect(scheduler.scheduledDelays.last == 1.0)
        await scheduler.runScheduled()
        #expect(refreshCount == 2)
    }

    @Test
    func stackObservationUsesTheSharedMetadataFilterWithoutChangingItsWatchHandshake() async throws {
        let fixture = try GitMetadataRefreshRepository(layout: .separate)
        defer { fixture.directory.remove() }
        let watcher = RecordingFileSystemEventWatcher()
        let scheduler = RecordingRefreshScheduler()
        let reader = MetadataObservationReader(commonDirectory: fixture.commonDirectory.path)
        let observation = WorkspaceStackObservation(
            repositoryPath: fixture.root.path, reader: reader, watcher: watcher, scheduler: scheduler)
        defer { observation.stop() }
        var resultCount = 0
        observation.start(onRefreshing: { _ in }, onResult: { _ in resultCount += 1 })
        try await waitUntil { resultCount == 1 }
        #expect(reader.readCount == 2)
        #expect(watcher.startedRoots == [fixture.commonDirectory.path])
        let relevant = [
            "config", "config.worktree", "refs/branch-metadata/feature", "refs/branch-metadata", "packed-refs",
            "refs/remotes/origin/main", "gh-stack", "worktrees/sibling/config.worktree", "worktrees/sibling/gh-stack"
        ]
        for path in relevant { watcher.emit(paths: [fixture.commonDirectory.appendingPathComponent(path).path]) }
        #expect(scheduler.scheduledDelays == Array(repeating: 0.3, count: relevant.count))
        watcher.emit(paths: [fixture.commonDirectory.path])
        #expect(scheduler.scheduledDelays.count == relevant.count + 1)
        watcher.emit(paths: [
            fixture.commonDirectory.appendingPathComponent("index").path, fixture.commonDirectory.path + "-other/config"
        ])
        #expect(scheduler.scheduledDelays.count == relevant.count + 1)
        await scheduler.runScheduled()
        try await waitUntil { resultCount == 2 }
        #expect(reader.readCount == 3)
    }

    private func observePackedGraphite(
        fixture: GitMetadataRefreshRepository, watcher: MetadataRecordingWatcher, scheduler: RecordingRefreshScheduler
    ) async throws {
        let payload = fixture.directory.url.appendingPathComponent("graphite.json")
        try #"{"parentBranchName":"main"}"#.write(to: payload, atomically: true, encoding: .utf8)
        let blob = try TestGit.run(["hash-object", "-w", payload.path], in: fixture.root)
        let looseRef = fixture.commonDirectory.appendingPathComponent("refs/branch-metadata/feature/child")
        let beforeCreation = watcher.events.count
        try TestGit.run(["update-ref", "refs/branch-metadata/feature/child", blob], in: fixture.root)
        try await waitForEvent(looseRef, after: beforeCreation, watcher: watcher)
        #expect(scheduler.scheduledDelays.last == 1.0)
        await scheduler.runScheduled()
        let packedRefs = fixture.commonDirectory.appendingPathComponent("packed-refs")
        let beforePacking = watcher.events.count
        try TestGit.run(["pack-refs", "--all", "--prune"], in: fixture.root)
        try await waitForEvent(packedRefs, after: beforePacking, watcher: watcher)
        #expect(!FileManager.default.fileExists(atPath: looseRef.path))
        #expect(scheduler.scheduledDelays.last == 1.0)
    }

    private func waitForEvent(_ url: URL, after count: Int, watcher: MetadataRecordingWatcher) async throws {
        let matches = {
            watcher.events.dropFirst(count).contains {
                GitMetadataEventPath.relativePath($0, in: url.deletingLastPathComponent().path) == url.lastPathComponent
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !matches(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(
            matches(),
            Comment(rawValue: "Expected an event for \(url.path); received \(Array(watcher.events.dropFirst(count)))"))
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate())
    }
}

private final class MetadataRecordingWatcher: FileSystemEventWatching, @unchecked Sendable {
    private let watcher = FSEventsFileWatcher()
    @MainActor var events: [String] = []

    func start(paths: [String], onEvents: @escaping @MainActor @Sendable ([String]) -> Void) {
        watcher.start(paths: paths) { [weak self] paths in
            self?.events.append(contentsOf: paths)
            onEvents(paths)
        }
    }

    func stop() { watcher.stop() }
}

@MainActor
private final class MetadataObservationReader: WorkspaceStackReading {
    let commonDirectory: String
    var readCount = 0

    init(commonDirectory: String) { self.commonDirectory = commonDirectory }

    func load(repositoryPath: String) async throws -> WorkspaceStackSnapshot {
        readCount += 1
        return WorkspaceStackSnapshot(gitCommonDirectory: commonDirectory, worktrees: [], parents: [:])
    }
}
