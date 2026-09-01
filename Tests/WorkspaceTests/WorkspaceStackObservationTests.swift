import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct WorkspaceStackObservationTests {
    @Test
    func initialReadIsReplacedByPostWatchInventoryWithoutAnotherEvent() async {
        let fixture = StackObservationFixture()
        defer { fixture.stop() }
        fixture.start()
        await waitForStackState { fixture.reader.requests.count == 1 }
        let changed = WorkspaceStackSnapshot(
            gitCommonDirectory: fixture.snapshot.gitCommonDirectory,
            worktrees: [WorkspaceStackWorktree(path: "/checkout", branch: "changed-before-watch")],
            parents: ["changed-before-watch": "main", "dependent": "changed-before-watch"]
        )
        #expect(fixture.watcher.startedPaths.isEmpty)
        await fixture.complete(0, with: fixture.snapshot)
        await waitForStackState { fixture.reader.requests.count == 2 }
        #expect(fixture.watcher.startedPaths == [fixture.snapshot.gitCommonDirectory])
        #expect(fixture.results.isEmpty)
        #expect(fixture.refreshing.allSatisfy { $0 })
        await fixture.complete(1, with: changed)
        #expect(fixture.results == [changed])
        #expect(fixture.refreshing.last == false)
        #expect(fixture.reader.requests.count == 2)
        #expect(fixture.scheduler.operation == nil)
    }

    @Test
    func watchesAbsentMetadataAndFiltersIndexNoise() async {
        let fixture = StackObservationFixture()
        defer { fixture.stop() }
        await fixture.startAndLoad()
        #expect(fixture.watcher.startedPaths == [fixture.snapshot.gitCommonDirectory])
        let common = fixture.snapshot.gitCommonDirectory
        fixture.watcher.emit([
            common + "/index", common + "/index.lock", common + "/worktrees/feature/index",
            common + "/objects/ab/cdef", common + "/gh-stack.lock", common + "-other/HEAD"
        ])
        #expect(fixture.scheduler.delays.isEmpty)
        let relevant = [
            "gh-stack", "HEAD", "refs/heads/feature", "packed-refs", "logs/HEAD", "worktrees",
            "worktrees/feature", "worktrees/feature/gitdir", "worktrees/feature/commondir",
            "worktrees/feature/HEAD", "worktrees/feature/gh-stack"
        ]
        for path in relevant { fixture.watcher.emit([common + "/" + path]) }
        #expect(fixture.scheduler.delays == Array(repeating: 0.3, count: relevant.count))
        await fixture.scheduler.runScheduled()
        await waitForStackState { fixture.reader.requests.count == 3 }
        await fixture.complete(2, with: fixture.snapshot)
        #expect(fixture.results.count == 2)
    }

    @Test
    func eventsAndExplicitRequestsCoalesceDuringAnInFlightLoad() async {
        let fixture = StackObservationFixture()
        defer { fixture.stop() }
        await fixture.startAndLoad()
        fixture.observation.refresh()
        await waitForStackState { fixture.reader.requests.count == 3 }
        for _ in 0..<4 {
            fixture.watcher.emit([fixture.snapshot.gitCommonDirectory + "/gh-stack"])
            fixture.observation.refresh()
        }
        #expect(fixture.reader.requests.count == 3)
        let obsolete = WorkspaceStackSnapshot(
            gitCommonDirectory: fixture.snapshot.gitCommonDirectory,
            worktrees: fixture.snapshot.worktrees, parents: fixture.snapshot.parents,
            diagnostics: ["Superseded result"]
        )
        await fixture.complete(2, with: obsolete)
        await waitForStackState { fixture.reader.requests.count == 4 }
        #expect(fixture.results == [fixture.snapshot])
        #expect(fixture.refreshing.last == true)
        await fixture.complete(3, with: fixture.snapshot)
        await fixture.scheduler.runScheduled()
        #expect(fixture.reader.requests.count == 4)
        #expect(fixture.results == [fixture.snapshot, fixture.snapshot])
        #expect(fixture.refreshing.last == false)
    }

    @Test
    func restartDiscardsLateLoadsAndCancelledScheduledCallbacks() async {
        let fixture = StackObservationFixture()
        defer { fixture.stop() }
        await fixture.startAndLoad()
        fixture.watcher.emit([fixture.snapshot.gitCommonDirectory + "/gh-stack"])
        let staleOperation = fixture.scheduler.operation
        let staleEvents = fixture.watcher.onEvents
        fixture.observation.refresh()
        await waitForStackState { fixture.reader.requests.count == 3 }
        fixture.observation.stop()
        fixture.start()
        await waitForStackState { fixture.reader.requests.count == 4 }
        let current = WorkspaceStackSnapshot(
            gitCommonDirectory: fixture.snapshot.gitCommonDirectory,
            worktrees: fixture.snapshot.worktrees, parents: fixture.snapshot.parents,
            diagnostics: ["Current diagnostic"]
        )
        await fixture.complete(3, with: current)
        await waitForStackState { fixture.reader.requests.count == 5 }
        #expect(fixture.results == [fixture.snapshot])
        await fixture.complete(4, with: current)
        await fixture.complete(2, with: fixture.snapshot)
        await staleOperation?()
        staleEvents?([fixture.snapshot.gitCommonDirectory + "/HEAD"])
        #expect(fixture.results == [fixture.snapshot, current])
        #expect(fixture.reader.requests.count == 5)
        #expect(fixture.scheduler.operation == nil)
        #expect(fixture.watcher.stopCount == 1)
    }
}

extension WorkspaceStackObservationTests {
    @Test
    func managerStartsExplicitlyAndDiscardsRemovedProjectResults() async throws {
        let reader = ControlledWorkspaceStackReader()
        let fixture = try WorkspaceStackTestFixture(reader: reader)
        defer {
            fixture.cleanup()
            reader.cancelAll()
        }
        #expect(reader.requests.isEmpty)
        fixture.manager.startWorkspaceStackObservations()
        await waitForStackState { reader.requests.count == 1 }
        #expect(reader.requests == [fixture.project.repositoryPath])
        #expect(fixture.manager.refreshingWorkspaceStackProjectIds == [fixture.project.id])
        _ = try fixture.adoptGapWorkspace()
        #expect(fixture.manager.pendingWorkspaceStackReveal != nil)
        for workspace in fixture.manager.workspaces { workspace.worktreePath = nil }
        await fixture.manager.removeProject(fixture.project.id)
        #expect(fixture.manager.pendingWorkspaceStackReveal == nil)
        reader.complete(0, with: .success(fixture.snapshot))
        await waitForStackState { reader.completed.contains(0) }
        #expect(fixture.manager.workspaceStackSnapshots[fixture.project.id] == nil)
        #expect(fixture.manager.workspaceStackErrors[fixture.project.id] == nil)
        #expect(fixture.manager.refreshingWorkspaceStackProjectIds.isEmpty)
        #expect(fixture.manager.workspaceStackObservations[fixture.project.id] == nil)
        let addedProject = Project(
            repositoryPath: fixture.root.appendingPathComponent("added").path, mainBranch: "main")
        fixture.manager.projects.insert(addedProject, at: 0)
        await waitForStackState { reader.requests.count == 2 }
        #expect(reader.requests.last == addedProject.repositoryPath)
        #expect(fixture.manager.refreshingWorkspaceStackProjectIds == [addedProject.id])
    }

    @Test
    func restoredProjectIdentityAndStopRejectOldCompletions() async throws {
        let reader = ControlledWorkspaceStackReader()
        let fixture = try WorkspaceStackTestFixture(reader: reader)
        defer {
            fixture.cleanup()
            reader.cancelAll()
        }
        let manager = fixture.manager
        manager.startWorkspaceStackObservations()
        await waitForStackState { reader.requests.count == 1 }
        #expect(manager.restoreSession(from: manager.makeSessionSnapshot()))
        await waitForStackState { reader.requests.count == 2 }
        #expect(manager.projects.first !== fixture.project)
        let current = WorkspaceStackSnapshot(
            gitCommonDirectory: fixture.snapshot.gitCommonDirectory,
            worktrees: fixture.snapshot.worktrees, parents: fixture.snapshot.parents,
            diagnostics: ["Replacement Project"]
        )
        reader.complete(1, with: .success(current))
        await waitForStackState { reader.requests.count == 3 }
        #expect(manager.workspaceStackSnapshots[fixture.project.id] == nil)
        reader.complete(2, with: .success(current))
        await waitForStackState { manager.workspaceStackSnapshots[fixture.project.id] == current }
        reader.complete(0, with: .success(fixture.snapshot))
        await waitForStackState { reader.completed.contains(0) }
        #expect(manager.workspaceStackSnapshots[fixture.project.id] == current)
        let workspace = try #require(
            manager.adoptOrphanedWorktree(
                OrphanedWorktreeInfo(
                    path: fixture.root.appendingPathComponent("gap").path,
                    branchName: "feature/gap", projectId: fixture.project.id)
            ))
        await waitForStackState { reader.requests.count == 4 }
        #expect(manager.pendingWorkspaceStackReveal?.workspaceId == workspace.id)
        manager.stopWorkspaceStackObservations()
        #expect(manager.pendingWorkspaceStackReveal == nil)
        reader.complete(3, with: .success(fixture.snapshot))
        await waitForStackState { reader.completed.contains(3) }
        manager.refreshWorkspaceStacks(in: fixture.project.id)
        #expect(manager.workspaceStackSnapshots.isEmpty)
        #expect(manager.workspaceStackErrors.isEmpty)
        #expect(manager.refreshingWorkspaceStackProjectIds.isEmpty)
        #expect(reader.requests.count == 4)
    }

    @Test
    func refreshKeepsOrderDisclosureAndSelectionAndFallsBackOnIssues() async throws {
        let reader = ControlledWorkspaceStackReader()
        let fixture = try WorkspaceStackTestFixture(reader: reader)
        defer {
            fixture.cleanup()
            reader.cancelAll()
        }
        let manager = fixture.manager
        let project = fixture.project
        let group = try #require(manager.stackGroup(for: fixture.child.id, in: project.id))
        project.collapsedStackIds = [group.id]
        project.isExpanded = false
        fixture.child.customTitle = "Keep this title"
        let order = project.workspaceIds
        let selection = manager.selectedWorkspaceId
        let revision = manager.workspaceRevealRevision
        await reader.startAndLoad(fixture)
        #expect(fixture.parent.branchName == "feature/parent")
        #expect(fixture.child.branchName == "feature/child")
        #expect(fixture.child.customTitle == "Keep this title")
        #expect(fixture.child.title == "stored-child")
        manager.refreshWorkspaceStacks(in: project.id)
        await waitForStackState { reader.requests.count == 3 }
        #expect(manager.stackGroup(for: fixture.child.id, in: project.id) == group)
        let unavailable = WorkspaceStackSnapshot(
            gitCommonDirectory: fixture.snapshot.gitCommonDirectory,
            worktrees: fixture.snapshot.worktrees, parents: [:],
            conflicts: ["feature/parent": "Conflicting local tracking"]
        )
        reader.complete(2, with: .success(unavailable))
        await waitForStackState { manager.workspaceStackErrors[project.id] == unavailable.issue }
        #expect(manager.sidebarItems(for: project) == order.map { .workspace($0) })
        manager.refreshWorkspaceStacks(in: project.id)
        await waitForStackState { reader.requests.count == 4 }
        reader.complete(3, with: .failure(StackObservationError.unavailable))
        await waitForStackState { manager.workspaceStackSnapshots[project.id] == nil }
        #expect(manager.workspaceStackErrors[project.id] == "Stack discovery unavailable")
        #expect(manager.sidebarItems(for: project) == order.map { .workspace($0) })
        manager.refreshWorkspaceStacks(in: project.id)
        await waitForStackState { reader.requests.count == 5 }
        reader.complete(4, with: .success(fixture.snapshot))
        await waitForStackState { manager.workspaceStackErrors[project.id] == nil }
        #expect(manager.stackGroup(for: fixture.child.id, in: project.id) == group)
        #expect(project.workspaceIds == order)
        #expect(project.collapsedStackIds == [group.id])
        #expect(!project.isExpanded)
        #expect(manager.selectedWorkspaceId == selection)
        #expect(manager.workspaceRevealRevision == revision)
    }

    @Test(arguments: [false, true])
    func unavailableInventoryCancelsPendingRevealBeforeRetry(_ metadataIssue: Bool) async throws {
        let reader = ControlledWorkspaceStackReader()
        let fixture = try WorkspaceStackTestFixture(reader: reader)
        defer {
            fixture.cleanup()
            reader.cancelAll()
        }
        await reader.startAndLoad(fixture)
        let manager = fixture.manager
        _ = try fixture.adoptGapWorkspace()
        await waitForStackState { reader.requests.count == 3 }
        let unavailable = WorkspaceStackSnapshot(
            gitCommonDirectory: fixture.snapshot.gitCommonDirectory,
            worktrees: fixture.snapshotIncludingGap.worktrees, parents: [:],
            diagnostics: ["Unavailable local tracking"]
        )
        reader.complete(2, with: metadataIssue ? .success(unavailable) : .failure(StackObservationError.unavailable))
        await waitForStackState { manager.workspaceStackErrors[fixture.project.id] != nil }
        #expect(manager.pendingWorkspaceStackReveal == nil)
        let revision = manager.workspaceRevealRevision
        manager.refreshWorkspaceStacks(in: fixture.project.id)
        await waitForStackState { reader.requests.count == 4 }
        reader.complete(3, with: .success(fixture.snapshotIncludingGap))
        await waitForStackState { !manager.refreshingWorkspaceStackProjectIds.contains(fixture.project.id) }
        #expect(fixture.project.collapsedStackIds == [fixture.stackId])
        #expect(manager.workspaceRevealRevision == revision)
    }
}

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

private enum StackObservationError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Stack discovery unavailable" }
}

@MainActor
private final class StackObservationFixture {
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

private final class StackEventWatcher: FileSystemEventWatching, @unchecked Sendable {
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
private final class StackRefreshScheduler: RefreshScheduling {
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
