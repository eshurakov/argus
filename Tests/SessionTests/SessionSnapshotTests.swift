import Foundation
import Testing

@testable import Argus

@Suite
struct SessionSnapshotTests {
    @Test
    func sessionSnapshotRoundTripsCurrentSchemaAndRejectsFutureSchema() throws {
        let projectId = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let workspaceId = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

        let project = ProjectSnapshot(
            id: projectId,
            repositoryPath: "/tmp/repo",
            isCatchAll: false,
            displayName: "Repo",
            mainBranch: "main",
            workspaceIds: [workspaceId],
            isExpanded: false,
            color: .blue
        )
        let workspace = WorkspaceSnapshot(
            id: workspaceId,
            projectId: projectId,
            branchName: "feature/persist",
            workspaceType: .worktree,
            worktreePath: "/tmp/worktree",
            title: "feature/persist",
            customTitle: "Persist Work",
            currentDirectory: "/tmp/worktree",
            panelCount: 1
        )
        let snapshot = ArgusSessionSnapshot(
            schemaVersion: ArgusSessionSnapshot.currentSchemaVersion,
            selectedWorkspaceId: workspaceId,
            projects: [project],
            workspaces: [workspace]
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ArgusSessionSnapshot.self, from: encoded)

        assertEqual(
            decoded.schemaVersion, ArgusSessionSnapshot.currentSchemaVersion, "schema version round-trips"
        )
        assertEqual(decoded.projects.first?.id, projectId, "project id round-trips")
        assertEqual(decoded.projects.first?.isExpanded, false, "project expansion state round-trips")
        assertEqual(decoded.workspaces.first?.projectId, projectId, "workspace project id round-trips")
        assertEqual(
            decoded.workspaces.first?.branchName, "feature/persist", "workspace branch round-trips")
        assertEqual(
            decoded.workspaces.first?.worktreePath, "/tmp/worktree", "workspace worktree path round-trips"
        )
        assertEqual(decoded.selectedWorkspaceId, workspaceId, "selected workspace id round-trips")
        assertEqual(decoded.isCompatible, true, "current schema is compatible")

        assertFutureSchemaIsIncompatible(project: project, workspace: workspace, workspaceId: workspaceId)
    }

    @Test
    @MainActor
    func workspaceMetadataIsCheckpointedBeforeTermination() throws {
        let defaults = try #require(UserDefaults(suiteName: "ArgusTests.WorkspaceMetadataCheckpoint"))
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-session-\(UUID().uuidString).json")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-workspace-root-\(UUID().uuidString)", isDirectory: true)
        defaults.removePersistentDomain(forName: "ArgusTests.WorkspaceMetadataCheckpoint")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: "ArgusTests.WorkspaceMetadataCheckpoint")
            try? FileManager.default.removeItem(at: snapshotURL)
            try? FileManager.default.removeItem(at: root)
        }

        let settings = AppSettings(defaults: defaults)
        let manager = WorkspaceManager(
            settings: settings,
            sessionSnapshotURL: snapshotURL,
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
        let workspace = try #require(manager.selectedWorkspace)

        manager.renameWorkspace(workspace.id, title: "Crash-safe Workspace")

        // Constructing a new manager models relaunch after a crash: no normal
        // termination callback is invoked between the mutation and restore.
        let restoredAfterRename = WorkspaceManager(
            settings: settings,
            sessionSnapshotURL: snapshotURL,
            environment: [:]
        )
        let renamedWorkspace = try #require(restoredAfterRename.selectedWorkspace)
        #expect(renamedWorkspace.customTitle == "Crash-safe Workspace")

        #expect(manager.setStandaloneWorkspaceRoot(workspace.id, directoryURL: root))
        let restoredAfterRootChange = WorkspaceManager(
            settings: settings,
            sessionSnapshotURL: snapshotURL,
            environment: [:]
        )
        let restoredWorkspace = try #require(restoredAfterRootChange.selectedWorkspace)
        #expect(restoredWorkspace.customTitle == "Crash-safe Workspace")
        #expect(restoredWorkspace.currentDirectory == root.standardizedFileURL.path)
    }

    private func assertFutureSchemaIsIncompatible(
        project: ProjectSnapshot,
        workspace: WorkspaceSnapshot,
        workspaceId: UUID
    ) {
        let incompatible = ArgusSessionSnapshot(
            schemaVersion: 999,
            selectedWorkspaceId: workspaceId,
            projects: [project],
            workspaces: [workspace]
        )
        assertEqual(incompatible.isCompatible, false, "future schema is incompatible")
    }

    /// Test instances must persist in a temporary per-process location rather
    /// than reading or writing the production Session Snapshot.
    @Test
    @MainActor
    func testInstancesUseIsolatedSessionSnapshotLocations() throws {
        let suiteName = "ArgusTests.TestSessionLocation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let productionURL = WorkspaceManager.defaultSessionSnapshotURL
        let productionSnapshot = try? Data(contentsOf: productionURL)
        var isolatedURLs = Set<URL>()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            for url in isolatedURLs {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let overrides = [
            "XCTestConfigurationFilePath",
            "ARGUS_DISABLE_SESSION_RESTORE",
            "ARGUS_UNDER_TEST"
        ]
        for override in overrides {
            let manager = WorkspaceManager(
                settings: AppSettings(defaults: defaults),
                environment: [override: "1"]
            )
            isolatedURLs.insert(manager.sessionSnapshotURL)

            #expect(manager.sessionSnapshotURL != productionURL)
            manager.renameWorkspace(
                try #require(manager.selectedWorkspace).id,
                title: "Test-run workspace"
            )
            manager.saveSession()

            #expect(FileManager.default.fileExists(atPath: manager.sessionSnapshotURL.path))
            #expect(
                (try? Data(contentsOf: productionURL)) == productionSnapshot,
                Comment(rawValue: "\(override) must not touch the production Session Snapshot")
            )
        }
    }

    /// Tests that supply their own snapshot URL must still use that location,
    /// including when a test environment override is present.
    @Test
    @MainActor
    func anExplicitSnapshotURLStillPersistsUnderTest() throws {
        let suiteName = "ArgusTests.ExplicitSnapshotPersists.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-session-\(UUID().uuidString).json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: snapshotURL)
        }

        let manager = WorkspaceManager(
            settings: AppSettings(defaults: defaults),
            sessionSnapshotURL: snapshotURL,
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
        manager.renameWorkspace(
            try #require(manager.selectedWorkspace).id,
            title: "Persisted workspace"
        )

        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }
}
