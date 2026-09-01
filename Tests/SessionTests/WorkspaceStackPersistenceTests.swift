import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct WorkspaceStackPersistenceTests {
    @Test
    func olderProjectSnapshotsDefaultToExpandedStackGroups() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let original = fixture.project.snapshot()
        let legacy = ProjectSnapshot(
            id: original.id, repositoryPath: original.repositoryPath, isCatchAll: false,
            displayName: original.displayName, mainBranch: original.mainBranch,
            workspaceIds: original.workspaceIds, isExpanded: false, color: original.color
        )
        let data = try JSONEncoder().encode(legacy)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["collapsedStackIds"] == nil)
        let decoded = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
        #expect(decoded.collapsedStackIds == nil)
        let restored = Project(snapshot: decoded)
        #expect(restored.collapsedStackIds.isEmpty)
        #expect(!restored.isExpanded)
        #expect(restored.workspaceIds == original.workspaceIds)
    }

    @Test
    func disclosureRoundTripsWithoutSavingLoadedGraphsOrChangingSchema() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let group = try #require(manager.stackGroup(for: fixture.child.id, in: fixture.project.id))
        fixture.project.isExpanded = false
        manager.toggleWorkspaceStack(group.id, in: fixture.project.id)
        let data = try Data(contentsOf: manager.sessionSnapshotURL)
        let saved = try JSONDecoder().decode(ArgusSessionSnapshot.self, from: data)
        #expect(saved.schemaVersion == 1)
        #expect(saved.projects.first?.collapsedStackIds == [group.id])
        #expect(saved.projects.first?.workspaceIds == fixture.project.workspaceIds)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["schemaVersion", "selectedWorkspaceId", "projects", "workspaces"])
        let projects = try #require(json["projects"] as? [[String: Any]])
        for key in ["stacks", "parents", "trunkBranches", "conflicts", "diagnostics", "worktrees", "gitCommonDirectory"]
        {
            #expect(projects.allSatisfy { $0[key] == nil })
        }

        let restoredManager = WorkspaceManager(
            settings: AppSettings(defaults: fixture.defaults),
            sessionSnapshotURL: fixture.root.appendingPathComponent("restored-session.json"),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
        #expect(restoredManager.restoreSession(from: saved))
        let project = try #require(restoredManager.projects.first { $0.id == fixture.project.id })
        #expect(project.collapsedStackIds == [group.id])
        #expect(!project.isExpanded)
        #expect(restoredManager.workspaceStackSnapshots.isEmpty)
        #expect(restoredManager.workspaceStackErrors.isEmpty)
        #expect(restoredManager.workspaceRevealRevision == 0)
        restoredManager.workspaceStackSnapshots[project.id] = fixture.snapshot
        #expect(restoredManager.sidebarOrderedWorkspaces.map(\.workspace.id) == fixture.orderedIds)
        restoredManager.toggleWorkspaceStack(group.id, in: project.id)
        let expanded = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: Data(contentsOf: restoredManager.sessionSnapshotURL)
        )
        #expect(expanded.projects.first?.collapsedStackIds == [])
    }

    @Test
    func legacyCollapsedKeySurvivesProviderNeutralForkDiscovery() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        fixture.project.collapsedStackIds = [fixture.stackId]
        let data = try JSONEncoder().encode(fixture.manager.makeSessionSnapshot())
        let saved = try JSONDecoder().decode(ArgusSessionSnapshot.self, from: data)
        let manager = WorkspaceManager(
            settings: AppSettings(defaults: fixture.defaults),
            sessionSnapshotURL: fixture.root.appendingPathComponent("fork-restored-session.json"),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
        #expect(manager.restoreSession(from: saved))
        let restored = try #require(manager.projects.first { $0.id == fixture.project.id })
        #expect(manager.workspaceStackSnapshots.isEmpty)
        manager.workspaceStackSnapshots[restored.id] = WorkspaceStackSnapshot(
            gitCommonDirectory: fixture.snapshot.gitCommonDirectory,
            worktrees: fixture.snapshot.worktrees,
            parents: fixture.snapshot.parents.merging(
                ["unrelated": "feature/parent"], uniquingKeysWith: { _, new in new }
            ), diagnostics: ["Unrelated metadata warning"]
        )
        let group = try #require(manager.stackGroup(for: fixture.child.id, in: restored.id))
        #expect(group.id == fixture.stackId)
        #expect(restored.collapsedStackIds.contains(group.id))
        #expect(group.laneCount == 2)
        #expect(group.workspaceIds == [fixture.parent.id, fixture.child.id, fixture.ordinary.id])
        #expect(saved.schemaVersion == 1)
    }

    @Test
    func reconciliationRetainsDisclosureWhileRepairingWorkspaceMembership() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let project = fixture.project
        project.collapsedStackIds = [fixture.stackId, "previous-stack-key"]
        project.workspaceIds = [UUID(), fixture.parent.id, fixture.parent.id]
        let catchAll = try #require(fixture.manager.catchAllProject)
        catchAll.collapsedStackIds = ["retained-catch-all-key"]
        let snapshot = fixture.manager.makeSessionSnapshot()
        let reconciled = snapshot.reconciledForRestore()
        let named = try #require(reconciled.projects.first { $0.id == project.id })
        let restoredCatchAll = try #require(reconciled.projects.first { $0.isCatchAll })
        #expect(named.workspaceIds == [fixture.parent.id, fixture.child.id, fixture.ordinary.id])
        #expect(named.collapsedStackIds == project.collapsedStackIds)
        #expect(restoredCatchAll.collapsedStackIds == catchAll.collapsedStackIds)
        #expect(reconciled.schemaVersion == 1)
        #expect(
            reconciled.reconciledForRestore().projects.map(\.collapsedStackIds)
                == reconciled.projects.map(\.collapsedStackIds))
    }
}
