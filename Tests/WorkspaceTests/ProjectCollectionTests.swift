import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct ProjectCollectionTests {
    @Test
    func createRenameMoveReorderAndRemoveOnlyOrganizesProjects() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let projects = addProjects(to: fixture)

        let first = try #require(manager.createCollection(name: "  Client Work  "))
        let second = try #require(manager.createCollection(name: "Personal"))
        #expect(first.name == "Client Work")
        #expect(manager.collections.count == 2)
        #expect(manager.projects(in: first.id).isEmpty)
        #expect(manager.renameCollection(first.id, name: "Client aPI"))
        #expect(manager.collections.first?.name == "Client aPI")
        #expect(!manager.renameCollection(first.id, name: " \n"))
        #expect(manager.createCollection(name: " \n") == nil)
        #expect(manager.moveProject(projects[2].id, toCollection: first.id))
        #expect(manager.moveProject(projects[0].id, toCollection: first.id))
        #expect(manager.moveProject(projects[1].id, toCollection: second.id))
        #expect(manager.moveProject(projects[0].id, offset: -1))
        #expect(manager.projects(in: first.id).map(\.id) == [projects[0].id, projects[2].id])
        #expect(manager.moveCollection(second.id, offset: -1))
        #expect(
            manager.sidebarOrderedProjects.map(\.id) == [
                projects[1].id, projects[0].id, projects[2].id, fixture.project.id, manager.catchAllProject.id
            ])
        #expect(manager.moveProject(fixture.project.id, toCollection: second.id))
        manager.toggleCollection(second.id)
        #expect(manager.collections.first?.isExpanded == false)
        #expect(manager.moveProject(projects[1].id, toCollection: first.id))
        manager.removeCollection(first.id)
        #expect(manager.ungroupedProjects.map(\.id) == [projects[0].id, projects[2].id, projects[1].id])
        manager.removeCollection(second.id)
        #expect(
            manager.ungroupedProjects.map(\.id) == [
                projects[0].id, projects[2].id, projects[1].id, fixture.project.id
            ])
        #expect(manager.collections.isEmpty)
        let saved = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: Data(contentsOf: manager.sessionSnapshotURL))
        #expect(saved.collections == nil)
        #expect(saved.projects.map(\.id) == manager.projects.map(\.id))
    }

    @Test
    func collectionMutationsPreserveWorkspaceAttentionAndUncommittedWork() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let projects = addProjects(to: fixture)
        let terminal = try #require(fixture.child.addTerminalPanel(workingDirectory: fixture.root.path))
        let selection = manager.selectedWorkspaceId
        let focus = fixture.child.activePanelId
        let workspaceIds = manager.workspaces.map(\.id)
        let manualOrder = fixture.project.workspaceIds
        let resources = projects.map(\.repositoryPath)
        let worktree = URL(fileURLWithPath: try #require(fixture.child.worktreePath))
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let userFile = worktree.appendingPathComponent("uncommitted.txt")
        try Data("Uncommitted work".utf8).write(to: userFile)
        let attention = TurnCompletionAttentionStore()
        manager.setTurnCompletionRuntime(
            TurnCompletionRuntime(
                workspaceManager: manager, attentionStore: attention, isMainWindowKey: { false }))
        let target = TurnCompletionAttentionTarget(workspaceId: fixture.child.id, tabId: terminal.id)
        _ = attention.record(agentKey: "test", eventId: "completed", target: target, isViewed: false)

        let first = try #require(manager.createCollection(name: "First"))
        let second = try #require(manager.createCollection(name: "Second"))
        manager.moveProject(fixture.project.id, toCollection: first.id)
        manager.moveProject(projects[0].id, toCollection: first.id)
        manager.moveProject(fixture.project.id, offset: 1)
        manager.renameCollection(first.id, name: "Renamed")
        manager.toggleCollection(first.id)
        manager.moveCollection(first.id, offset: 1)
        manager.moveProject(fixture.project.id, toCollection: second.id)
        manager.removeCollection(first.id)
        manager.removeCollection(second.id)
        #expect(manager.selectedWorkspaceId == selection)
        #expect(fixture.child.activePanelId == focus)
        #expect(fixture.child.panels[terminal.id] === terminal)
        #expect(manager.workspaces.map(\.id) == workspaceIds)
        #expect(fixture.project.workspaceIds == manualOrder)
        #expect(projects.map(\.repositoryPath) == resources)
        #expect(try Data(contentsOf: userFile) == Data("Uncommitted work".utf8))
        #expect(attention.attentionTargets == [target])
        #expect(manager.workspaceStackSnapshots[fixture.project.id] == fixture.snapshot)
    }

    @Test
    func invalidActionsAndLimitsDoNotChangeTheHierarchy() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let collection = try #require(manager.createCollection(name: "Work"))
        #expect(!manager.moveProject(manager.catchAllProject.id, toCollection: collection.id))
        #expect(!manager.moveProject(UUID(), toCollection: collection.id))
        #expect(!manager.moveProject(fixture.project.id, toCollection: UUID()))
        #expect(!manager.moveProject(fixture.project.id, toCollection: collection.id, at: -1))
        #expect(!manager.moveCollection(collection.id, offset: -1))
        #expect(!manager.moveProject(fixture.project.id, offset: 2))
        #expect(!manager.renameCollection(UUID(), name: "Missing"))
        #expect(manager.createCollection(name: String(repeating: "x", count: 4097)) == nil)
        for index in 1..<ProjectCollection.maximumCount {
            #expect(manager.createCollection(name: "Empty \(index)") != nil)
        }
        #expect(!manager.canCreateCollection)
        #expect(manager.createCollection(name: "Too many") == nil)
        #expect(manager.collections.count == 128)
        #expect(manager.ungroupedProjects.map(\.id) == [fixture.project.id])
    }

    @Test(arguments: 0..<8)
    func sameIdSelectionRevealsEveryAncestorWithoutChangingTabOrNumber(disclosure: Int) throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let collection = try #require(manager.createCollection(name: "Work"))
        manager.moveProject(fixture.project.id, toCollection: collection.id)
        let terminal = try #require(fixture.child.addTerminalPanel(workingDirectory: fixture.root.path))
        let order = fixture.orderedIds
        if disclosure & 1 != 0 { manager.toggleCollection(collection.id) }
        fixture.project.isExpanded = disclosure & 2 == 0
        if disclosure & 4 != 0 { manager.toggleWorkspaceStack(fixture.stackId, in: fixture.project.id) }
        let revision = manager.workspaceRevealRevision
        manager.selectWorkspace(fixture.child.id)
        #expect(manager.collections.first?.isExpanded == true)
        #expect(fixture.project.isExpanded)
        #expect(fixture.project.collapsedStackIds.isEmpty)
        #expect(manager.selectedWorkspaceId == fixture.child.id)
        #expect(fixture.child.activePanelId == terminal.id)
        #expect(manager.workspaceRevealRevision == revision + 1)
        #expect(fixture.orderedIds == order)
        #expect(manager.workspaceShortcutDigit(for: fixture.child.id) == 2)
    }

    @Test
    func shortcutAdjacentAndCloseNavigationShareTheCollectionProjection() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let projects = addProjects(to: fixture)
        let collection = try #require(manager.createCollection(name: "First"))
        manager.moveProject(projects[1].id, toCollection: collection.id)
        manager.moveProject(fixture.project.id, toCollection: collection.id)
        manager.toggleCollection(collection.id)
        fixture.project.isExpanded = false
        fixture.project.collapsedStackIds = [fixture.stackId]
        let first = try #require(projects[1].workspaceIds.first)
        let expected =
            [first, fixture.parent.id, fixture.child.id, fixture.ordinary.id]
            + projects[0].workspaceIds + projects[2].workspaceIds
        #expect(fixture.orderedIds == expected)
        manager.handleWorkspaceShortcut(number: 1)
        #expect(manager.selectedWorkspaceId == first)
        manager.selectNextWorkspace()
        #expect(manager.selectedWorkspaceId == fixture.parent.id)
        manager.selectPreviousWorkspace()
        #expect(manager.selectedWorkspaceId == first)
        manager.removeWorkspace(first)
        #expect(manager.selectedWorkspaceId == fixture.parent.id)
        manager.handleWorkspaceShortcut(number: 9)
        #expect(manager.selectedWorkspaceId == expected.last)
        manager.selectNextWorkspace()
        #expect(manager.selectedWorkspaceId == fixture.parent.id)
        #expect(manager.collections.first?.isExpanded == true)
    }

    @Test
    func collapsingCollectionCancelsDelayedStackRevealButNotDiscovery() async throws {
        let reader = ControlledWorkspaceStackReader()
        let fixture = try WorkspaceStackTestFixture(reader: reader)
        defer {
            fixture.cleanup()
            reader.cancelAll()
        }
        let manager = fixture.manager
        let collection = try #require(manager.createCollection(name: "Work"))
        manager.moveProject(fixture.project.id, toCollection: collection.id)
        await reader.startAndLoad(fixture)
        let workspace = try fixture.adoptGapWorkspace()
        await waitForStackState { reader.requests.count == 3 }
        let revision = manager.workspaceRevealRevision
        manager.toggleCollection(collection.id)
        #expect(manager.pendingWorkspaceStackReveal == nil)
        reader.complete(2, with: .success(fixture.snapshotIncludingGap))
        await waitForStackState { manager.workspaceStackSnapshots[fixture.project.id] == fixture.snapshotIncludingGap }
        #expect(manager.collections.first?.isExpanded == false)
        #expect(manager.selectedWorkspaceId == workspace.id)
        #expect(manager.workspaceRevealRevision == revision)
        #expect(fixture.project.collapsedStackIds == [fixture.stackId])
        #expect(manager.isObservingWorkspaceStacks)
    }

    private func addProjects(to fixture: WorkspaceStackTestFixture) -> [Project] {
        (1...3).map { index in
            let project = Project(
                repositoryPath: fixture.root.appendingPathComponent("project-\(index)").path, mainBranch: "main")
            let workspace = Workspace(
                snapshot: WorkspaceSnapshot(
                    id: UUID(), projectId: project.id, branchName: "main", workspaceType: .mainCheckout,
                    worktreePath: nil, title: "Project \(index)", customTitle: nil,
                    currentDirectory: project.repositoryPath, panelCount: 0))
            project.addWorkspace(workspace.id)
            fixture.manager.workspaces.append(workspace)
            fixture.manager.projects.insert(project, at: fixture.manager.projects.count - 1)
            return project
        }
    }
}
