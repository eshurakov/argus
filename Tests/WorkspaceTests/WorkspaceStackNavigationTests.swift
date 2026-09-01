import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct WorkspaceStackNavigationTests {
    @Test
    func orderingAndShortcutCountsIgnoreDisclosureAndReferences() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        for index in 1...8 {
            _ = try #require(manager.addWorkspace(title: "Standalone \(index)", workingDirectory: fixture.root.path))
        }
        let group = try #require(manager.stackGroup(for: fixture.child.id, in: fixture.project.id))
        #expect(group.rows.map(\.branch) == ["feature/parent", "feature/gap", "feature/child"])
        #expect(group.rows.filter { $0.workspaceId == nil }.count == 1)
        let ordered = fixture.orderedIds
        let manualOrder = fixture.project.workspaceIds
        fixture.project.isExpanded = false
        manager.toggleWorkspaceStack(group.id, in: fixture.project.id)
        manager.selectedWorkspaceId = fixture.child.id

        #expect(fixture.orderedIds == ordered)
        #expect(Array(ordered.prefix(3)) == [fixture.parent.id, fixture.child.id, fixture.ordinary.id])
        #expect(ordered.count == 11)
        #expect(ordered.map { manager.workspaceShortcutDigit(for: $0) } == [1, 2, 3, 4, 5, 6, 7, 8, nil, nil, 9])
        #expect(manager.selectedWorkspaceIndex == 1)
        #expect(fixture.project.workspaceIds == manualOrder)
        manager.handleWorkspaceShortcut(number: 1)
        #expect(manager.selectedWorkspaceId == fixture.parent.id)
        manager.handleWorkspaceShortcut(number: 8)
        #expect(manager.selectedWorkspaceId == ordered[7])
        manager.handleWorkspaceShortcut(number: 9)
        #expect(manager.selectedWorkspaceId == ordered.last)
    }

    @Test
    func adjacentNavigationUsesProjectedOrderAndWraparound() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        manager.selectWorkspace(fixture.parent.id)
        manager.selectNextWorkspace()
        #expect(manager.selectedWorkspaceId == fixture.child.id)
        manager.selectNextWorkspace()
        #expect(manager.selectedWorkspaceId == fixture.ordinary.id)
        manager.selectNextWorkspace()
        #expect(manager.selectedWorkspaceId == fixture.parent.id)
        manager.selectPreviousWorkspace()
        #expect(manager.selectedWorkspaceId == fixture.ordinary.id)
        manager.selectPreviousWorkspace()
        #expect(manager.selectedWorkspaceId == fixture.child.id)
    }

    @Test
    func sameIdSelectionRevealsWhileCollapsePreservesActiveTab() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let terminal = try #require(fixture.child.addTerminalPanel(workingDirectory: fixture.root.path))
        let group = try #require(manager.stackGroup(for: fixture.child.id, in: fixture.project.id))
        fixture.project.isExpanded = false
        fixture.project.collapsedStackIds = [group.id]
        let revision = manager.workspaceRevealRevision
        manager.selectWorkspace(fixture.child.id)

        #expect(manager.workspaceRevealRevision == revision + 1)
        #expect(manager.selectedWorkspaceId == fixture.child.id)
        #expect(fixture.project.isExpanded)
        #expect(!fixture.project.collapsedStackIds.contains(group.id))
        #expect(fixture.child.activePanelId == terminal.id)
        manager.toggleWorkspaceStack(group.id, in: fixture.project.id)
        #expect(fixture.project.collapsedStackIds.contains(group.id))
        #expect(manager.workspaceRevealRevision == revision + 1)
        #expect(manager.selectedWorkspaceId == fixture.child.id)
        #expect(fixture.child.activePanelId == terminal.id)
        manager.selectWorkspace(fixture.child.id)
        #expect(manager.workspaceRevealRevision == revision + 2)
        manager.selectWorkspace(UUID())
        #expect(manager.workspaceRevealRevision == revision + 2)
    }

    @Test
    func movingEitherMemberMovesWholeGroupInBothDirections() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let projectId = fixture.project.id
        let selection = manager.selectedWorkspaceId
        let revision = manager.workspaceRevealRevision
        #expect(!manager.canMoveWorkspace(in: projectId, moving: fixture.child.id, offset: -1))
        #expect(manager.canMoveWorkspace(in: projectId, moving: fixture.parent.id, offset: 1))
        #expect(manager.moveWorkspace(in: projectId, moving: fixture.child.id, offset: 1))
        #expect(fixture.project.workspaceIds == [fixture.ordinary.id, fixture.parent.id, fixture.child.id])
        #expect(fixture.orderedIds == fixture.project.workspaceIds)
        #expect(!manager.canMoveWorkspace(in: projectId, moving: fixture.parent.id, offset: 1))
        #expect(manager.moveWorkspace(in: projectId, moving: fixture.parent.id, offset: -1))
        #expect(fixture.project.workspaceIds == [fixture.parent.id, fixture.child.id, fixture.ordinary.id])
        #expect(!manager.moveWorkspace(in: projectId, moving: fixture.child.id, offset: 0))
        #expect(!manager.moveWorkspace(in: projectId, moving: fixture.child.id, offset: 2))
        #expect(manager.selectedWorkspaceId == selection)
        #expect(manager.workspaceRevealRevision == revision)
    }

    @Test
    func dropsRejectSameBlockCrossProjectAndVisualNoOps() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let projectId = fixture.project.id
        let standalone = try #require(manager.addWorkspace(workingDirectory: fixture.root.path))
        let manualOrder = fixture.project.workspaceIds
        #expect(!manager.reorderWorkspace(in: projectId, moving: fixture.parent.id, before: fixture.child.id))
        #expect(!manager.reorderWorkspace(in: projectId, moving: fixture.child.id, before: fixture.parent.id))
        #expect(!manager.reorderWorkspace(in: projectId, moving: fixture.child.id, before: fixture.ordinary.id))
        #expect(!manager.reorderWorkspace(in: projectId, moving: standalone.id, before: fixture.parent.id))
        #expect(!manager.reorderWorkspace(in: projectId, moving: fixture.child.id, before: standalone.id))
        #expect(!manager.reorderWorkspace(in: projectId, moving: UUID(), before: fixture.child.id))
        #expect(fixture.project.workspaceIds == manualOrder)
        #expect(manager.reorderWorkspace(in: projectId, moving: fixture.ordinary.id, before: fixture.child.id))
        #expect(fixture.project.workspaceIds == [fixture.ordinary.id, fixture.parent.id, fixture.child.id])
        #expect(manager.reorderWorkspace(in: projectId, moving: fixture.child.id, before: fixture.ordinary.id))
        #expect(fixture.project.workspaceIds == [fixture.parent.id, fixture.child.id, fixture.ordinary.id])
    }
}

extension WorkspaceStackNavigationTests {
    @Test
    func movesAndDropsTreatAnotherGroupAsOneBlock() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let project = fixture.project
        let parent = fixture.makeWorkspace(branch: "other/parent")
        let child = fixture.makeWorkspace(branch: "other/child")
        manager.workspaces += [child, parent]
        project.workspaceIds = [fixture.child.id, child.id, fixture.ordinary.id, fixture.parent.id, parent.id]
        manager.workspaceStackSnapshots[project.id] = WorkspaceStackSnapshot(
            gitCommonDirectory: fixture.snapshot.gitCommonDirectory,
            worktrees: fixture.snapshot.worktrees + [
                WorkspaceStackWorktree(path: try #require(parent.worktreePath), branch: "other/parent"),
                WorkspaceStackWorktree(path: try #require(child.worktreePath), branch: "other/child")
            ],
            parents: fixture.snapshot.parents.merging(
                ["other/parent": "main", "other/child": "other/parent"], uniquingKeysWith: { _, new in new }
            )
        )
        #expect(manager.moveWorkspace(in: project.id, moving: fixture.child.id, offset: 1))
        #expect(project.workspaceIds == [parent.id, child.id, fixture.parent.id, fixture.child.id, fixture.ordinary.id])
        #expect(manager.reorderWorkspace(in: project.id, moving: fixture.parent.id, before: child.id))
        #expect(project.workspaceIds == [fixture.parent.id, fixture.child.id, parent.id, child.id, fixture.ordinary.id])
    }

    @Test
    func selectedCloseUsesProjectedNeighborAndKeepsSiblingIndependent() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let terminal = try #require(fixture.child.addTerminalPanel(workingDirectory: fixture.root.path))
        fixture.manager.selectWorkspace(fixture.parent.id)
        fixture.manager.removeWorkspace(fixture.parent.id)
        #expect(fixture.manager.selectedWorkspaceId == fixture.child.id)
        #expect(fixture.manager.workspaces.contains { $0.id == fixture.child.id })
        #expect(fixture.child.panelOrder == [terminal.id])
        #expect(fixture.manager.stackGroup(for: fixture.child.id, in: fixture.project.id) == nil)
        #expect(fixture.project.workspaceIds == [fixture.child.id, fixture.ordinary.id])
    }

    @Test
    func closingLastProjectedWorkspaceSelectsPreviousWorkspace() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        fixture.manager.selectWorkspace(fixture.ordinary.id)
        fixture.manager.removeWorkspace(fixture.ordinary.id)
        #expect(fixture.manager.selectedWorkspaceId == fixture.child.id)
        #expect(fixture.orderedIds == [fixture.parent.id, fixture.child.id])
    }

    @Test
    func classifiedRootsBindWithoutUsingStoredBranchLabels() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        fixture.parent.currentDirectory = fixture.root.appendingPathComponent("elsewhere").path
        fixture.parent.worktreePath = fixture.child.worktreePath
        fixture.child.currentDirectory = fixture.project.repositoryPath
        let standalone = fixture.makeWorkspace(branch: "feature/parent")
        standalone.workspaceType = .external
        standalone.currentDirectory = fixture.project.repositoryPath
        standalone.worktreePath = fixture.child.worktreePath
        fixture.manager.workspaces.append(standalone)
        fixture.project.addWorkspace(standalone.id)

        let group = try #require(fixture.manager.stackGroup(for: fixture.parent.id, in: fixture.project.id))
        #expect(group.workspaceIds == [fixture.parent.id, fixture.child.id])
        #expect(fixture.manager.stackGroup(for: standalone.id, in: fixture.project.id) == nil)
        #expect(fixture.parent.branchName == "stored-parent")
        #expect(fixture.child.branchName == "stored-child")
    }

    @Test(arguments: [false, true])
    func adoptingUnobservedWorktreeRevealsDespiteUnrelatedDiagnostics(_ hasDiagnostic: Bool) async throws {
        let reader = ControlledWorkspaceStackReader()
        let fixture = try WorkspaceStackTestFixture(reader: reader)
        defer {
            fixture.cleanup()
            reader.cancelAll()
        }
        await reader.startAndLoad(fixture)
        let manager = fixture.manager
        let workspace = try fixture.adoptGapWorkspace()
        let revision = manager.workspaceRevealRevision
        let contextRevision = manager.workspaceContextRevision
        let activePanelId = workspace.activePanelId
        #expect(manager.stackGroup(for: workspace.id, in: fixture.project.id) == nil)
        #expect(workspace.branchName == "outdated-branch-label")
        #expect(!fixture.project.collapsedStackIds.isEmpty)
        await waitForStackState { reader.requests.count == 3 }
        manager.cancelPendingWorkspaceStackReveal(in: manager.catchAllProject.id)
        let refreshed = WorkspaceStackSnapshot(
            gitCommonDirectory: fixture.snapshot.gitCommonDirectory,
            worktrees: fixture.snapshotIncludingGap.worktrees, parents: fixture.snapshot.parents,
            conflicts: hasDiagnostic ? ["unrelated": "Unrelated conflicting parents"] : [:],
            diagnostics: hasDiagnostic ? ["Another provider is unavailable"] : []
        )
        reader.complete(2, with: .success(refreshed))
        await waitForStackState { manager.workspaceRevealRevision == revision + 1 }
        #expect(manager.workspaceStackErrors[fixture.project.id] == refreshed.issue)
        #expect(manager.selectedWorkspaceId == workspace.id)
        #expect(fixture.project.isExpanded)
        #expect(fixture.project.collapsedStackIds.isEmpty)
        #expect(fixture.orderedIds == [fixture.parent.id, workspace.id, fixture.child.id, fixture.ordinary.id])
        #expect(workspace.activePanelId == activePanelId)
        #expect(manager.workspaceContextRevision == contextRevision)
        #expect(manager.pendingWorkspaceStackReveal == nil)
        manager.toggleWorkspaceStack(fixture.stackId, in: fixture.project.id)
        manager.refreshWorkspaceStacks(in: fixture.project.id)
        await waitForStackState { reader.requests.count == 4 }
        reader.complete(3, with: .success(fixture.snapshotIncludingGap))
        await waitForStackState { !manager.refreshingWorkspaceStackProjectIds.contains(fixture.project.id) }
        #expect(!fixture.project.collapsedStackIds.isEmpty)
        #expect(manager.workspaceRevealRevision == revision + 1)
    }

    @Test(arguments: WorkspaceStackRevealInterruption.allCases)
    func laterUserIntentPreventsDelayedStackExpansion(_ interruption: WorkspaceStackRevealInterruption) async throws {
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
        switch interruption {
        case .selection:
            manager.selectWorkspace(fixture.ordinary.id)
        case .stackDisclosure:
            manager.toggleWorkspaceStack(fixture.stackId, in: fixture.project.id)
            manager.toggleWorkspaceStack(fixture.stackId, in: fixture.project.id)
        case .projectDisclosure:
            manager.cancelPendingWorkspaceStackReveal(in: fixture.project.id)
            fixture.project.isExpanded.toggle()
            fixture.project.isExpanded.toggle()
        case .collapsedProject:
            fixture.project.isExpanded = false
        }
        let revision = manager.workspaceRevealRevision
        let selection = manager.selectedWorkspaceId
        let isExpanded = fixture.project.isExpanded
        reader.complete(2, with: .success(fixture.snapshotIncludingGap))
        await waitForStackState { manager.workspaceStackSnapshots[fixture.project.id] == fixture.snapshotIncludingGap }
        #expect(fixture.project.collapsedStackIds == [fixture.stackId])
        #expect(fixture.project.isExpanded == isExpanded)
        #expect(manager.selectedWorkspaceId == selection)
        #expect(manager.workspaceRevealRevision == revision)
        #expect(manager.pendingWorkspaceStackReveal == nil)
    }

    @Test
    func forksNavigateAndMoveAsOneBlockWithoutCascadingClosure() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let sibling = fixture.makeWorkspace(branch: "feature/sibling")
        manager.workspaces.append(sibling)
        fixture.project.addWorkspace(sibling.id)
        manager.workspaceStackSnapshots[fixture.project.id] = WorkspaceStackSnapshot(
            gitCommonDirectory: fixture.snapshot.gitCommonDirectory,
            worktrees: fixture.snapshot.worktrees + [
                WorkspaceStackWorktree(path: sibling.currentDirectory, branch: "feature/sibling")
            ],
            parents: fixture.snapshot.parents.merging(
                ["feature/sibling": "feature/parent"], uniquingKeysWith: { _, new in new }
            )
        )
        let terminal = try #require(sibling.addTerminalPanel(workingDirectory: fixture.root.path))
        let group = try #require(manager.stackGroup(for: sibling.id, in: fixture.project.id))
        #expect(group.id == fixture.stackId)
        #expect(group.workspaceIds == [fixture.parent.id, fixture.child.id, sibling.id])
        manager.selectWorkspace(fixture.child.id)
        manager.selectNextWorkspace()
        #expect(manager.selectedWorkspaceId == sibling.id)
        #expect(manager.workspaceShortcutDigit(for: sibling.id) == 3)
        #expect(!manager.reorderWorkspace(in: fixture.project.id, moving: sibling.id, before: fixture.child.id))
        #expect(manager.moveWorkspace(in: fixture.project.id, moving: sibling.id, offset: 1))
        #expect(fixture.orderedIds == [fixture.ordinary.id, fixture.parent.id, fixture.child.id, sibling.id])
        manager.selectWorkspace(fixture.parent.id)
        manager.removeWorkspace(fixture.parent.id)
        #expect(manager.selectedWorkspaceId == fixture.child.id)
        let surviving = try #require(manager.stackGroup(for: sibling.id, in: fixture.project.id))
        #expect(surviving.id == group.id)
        #expect(surviving.rows.first?.workspaceId == nil)
        #expect(surviving.workspaceIds == [fixture.child.id, sibling.id])
        #expect(sibling.activePanelId == terminal.id)
    }

    @Test
    func standaloneReorderKeepsBeforeSemantics() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let first = try #require(manager.addWorkspace(workingDirectory: fixture.root.path))
        let second = try #require(manager.addWorkspace(workingDirectory: fixture.root.path))
        let last = try #require(manager.addWorkspace(workingDirectory: fixture.root.path))
        let project = try #require(manager.catchAllProject)
        #expect(!manager.reorderWorkspace(in: project.id, moving: first.id, before: second.id))
        #expect(manager.reorderWorkspace(in: project.id, moving: last.id, before: first.id))
        #expect(project.workspaceIds == [last.id, first.id, second.id])
        #expect(manager.moveWorkspace(in: project.id, moving: last.id, offset: 1))
        #expect(project.workspaceIds == [first.id, last.id, second.id])
    }
}

enum WorkspaceStackRevealInterruption: CaseIterable, Sendable {
    case selection
    case stackDisclosure
    case projectDisclosure
    case collapsedProject
}

@MainActor
final class WorkspaceStackTestFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("argus-stack-tests-\(UUID().uuidString)", isDirectory: true)
        .resolvingSymlinksInPath()
    let defaultsName = "ArgusTests.WorkspaceStacks.\(UUID().uuidString)"
    let defaults: UserDefaults
    let manager: WorkspaceManager
    let project: Project
    let parent: Workspace
    let child: Workspace
    let ordinary: Workspace
    let snapshot: WorkspaceStackSnapshot
    let stackId = "gh-stack:4:main:14:feature/parent"

    var orderedIds: [UUID] { manager.sidebarOrderedWorkspaces.map(\.workspace.id) }

    var snapshotIncludingGap: WorkspaceStackSnapshot {
        WorkspaceStackSnapshot(
            gitCommonDirectory: snapshot.gitCommonDirectory,
            worktrees: snapshot.worktrees + [
                WorkspaceStackWorktree(path: root.appendingPathComponent("gap").path, branch: "feature/gap")
            ],
            parents: snapshot.parents
        )
    }

    func adoptGapWorkspace() throws -> Workspace {
        project.isExpanded = false
        project.collapsedStackIds = [stackId]
        return try #require(
            manager.adoptOrphanedWorktree(
                OrphanedWorktreeInfo(
                    path: root.appendingPathComponent("gap").path,
                    branchName: "outdated-branch-label", projectId: project.id
                )
            ))
    }

    init(reader: any WorkspaceStackReading = WorkspaceStackService()) throws {
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        manager = WorkspaceManager(
            settings: AppSettings(defaults: defaults),
            sessionSnapshotURL: root.appendingPathComponent("session.json"),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"],
            workspaceStackReader: reader
        )
        project = Project(repositoryPath: root.appendingPathComponent("repository").path, mainBranch: "main")
        parent = Self.workspace(
            project: project, branch: "stored-parent", path: project.repositoryPath, type: .mainCheckout)
        child = Self.workspace(
            project: project, branch: "stored-child", path: root.appendingPathComponent("child").path)
        ordinary = Self.workspace(
            project: project, branch: "unrelated", path: root.appendingPathComponent("ordinary").path)
        snapshot = WorkspaceStackSnapshot(
            gitCommonDirectory: root.appendingPathComponent("common.git").path,
            worktrees: [
                WorkspaceStackWorktree(path: project.repositoryPath, branch: "feature/parent"),
                WorkspaceStackWorktree(path: child.currentDirectory, branch: "feature/child"),
                WorkspaceStackWorktree(path: ordinary.currentDirectory, branch: "unrelated")
            ],
            parents: ["feature/parent": "main", "feature/gap": "feature/parent", "feature/child": "feature/gap"]
        )
        manager.catchAllProject.workspaceIds = []
        manager.workspaces = [child, ordinary, parent]
        project.workspaceIds = manager.workspaces.map(\.id)
        manager.projects.insert(project, at: 0)
        manager.selectedWorkspaceId = child.id
        manager.workspaceStackSnapshots[project.id] = snapshot
    }

    func makeWorkspace(branch: String) -> Workspace {
        Self.workspace(project: project, branch: branch, path: root.appendingPathComponent(branch).path)
    }

    func cleanup() {
        manager.stopWorkspaceStackObservations()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }

    private static func workspace(
        project: Project,
        branch: String,
        path: String,
        type: WorkspaceType = .worktree
    ) -> Workspace {
        Workspace(
            snapshot: WorkspaceSnapshot(
                id: UUID(), projectId: project.id, branchName: branch, workspaceType: type,
                worktreePath: type == .worktree ? path : nil, title: branch, customTitle: nil,
                currentDirectory: path, panelCount: 0
            ))
    }
}
