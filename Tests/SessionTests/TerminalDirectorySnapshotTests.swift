import Foundation
import Testing

@testable import Argus

@Suite @MainActor
struct TerminalDirectorySnapshotTests {
    @Test
    func terminalMetadataRoundTrips() throws {
        let projectId = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let workspaceId = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

        let workspace = WorkspaceSnapshot(
            id: workspaceId,
            projectId: projectId,
            branchName: "feature/cwd",
            workspaceType: .worktree,
            worktreePath: "/repo/.argus/worktree",
            title: "feature/cwd",
            customTitle: nil,
            currentDirectory: "/repo/.argus/worktree",
            panelCount: 3,
            terminalDirectories: [
                "/repo/.argus/worktree/app",
                "/repo/.argus/worktree/docs",
                "/tmp/scratch"
            ],
            terminalCustomTitles: ["Server", nil, "Scratch"]
        )

        let encoded = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: encoded)
        assertEqual(
            decoded.terminalDirectories,
            ["/repo/.argus/worktree/app", "/repo/.argus/worktree/docs", "/tmp/scratch"],
            "terminal directories round-trip"
        )
        assertEqual(
            decoded.restoredTerminalDirectories,
            decoded.terminalDirectories,
            "restore uses persisted terminal directories"
        )
        assertEqual(
            decoded.restoredTerminalCustomTitles,
            ["Server", nil, "Scratch"],
            "terminal custom titles round-trip by tab order"
        )
    }

    @Test
    func legacySnapshotUsesWorkspaceDirectory() throws {
        let legacyJSON = Data(
            """
            {
              "id": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
              "projectId": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
              "branchName": "main",
              "workspaceType": "worktree",
              "worktreePath": "/repo/worktree",
              "title": "main",
              "customTitle": null,
              "currentDirectory": "/repo/worktree",
              "panelCount": 2
            }
            """.utf8)
        let legacy = try JSONDecoder().decode(WorkspaceSnapshot.self, from: legacyJSON)
        assertEqual(
            legacy.restoredTerminalDirectories,
            ["/repo/worktree", "/repo/worktree"],
            "legacy snapshots fall back to workspace directory for each terminal"
        )
        assertEqual(
            legacy.restoredTerminalCustomTitles,
            [nil, nil],
            "legacy snapshots restore ordinal terminal titles"
        )
    }

    @Test
    func liveTerminalDirectoryIsRestored() throws {
        let workspace = Workspace(title: "Terminal", workingDirectory: "/repo")
        let terminal = try #require(workspace.activePanel as? TerminalPanel)

        NotificationCenter.default.post(
            name: .argusSetSurfacePwd,
            object: nil,
            userInfo: ["surfaceId": terminal.id, "pwd": "/repo/packages/app"]
        )

        let snapshot = workspace.snapshot()
        let restoredWorkspace = Workspace(snapshot: snapshot)
        let restoredTerminal = try #require(restoredWorkspace.activePanel as? TerminalPanel)

        assertEqual(
            snapshot.terminalDirectories,
            ["/repo/packages/app"],
            "snapshot captures the latest Terminal Working Directory"
        )
        assertEqual(
            restoredTerminal.directory,
            "/repo/packages/app",
            "restored terminal starts in its persisted working directory"
        )
    }

    @Test
    func reconciliationPreservesTerminalMetadata() {
        let projectId = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let workspaceId = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let invalidProject = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let reconciled = ArgusSessionSnapshot(
            selectedWorkspaceId: workspaceId,
            projects: [
                ProjectSnapshot(
                    id: projectId,
                    repositoryPath: "/repo",
                    isCatchAll: true,
                    displayName: "Workspaces",
                    mainBranch: "",
                    workspaceIds: [],
                    isExpanded: true,
                    color: nil
                )
            ],
            workspaces: [
                WorkspaceSnapshot(
                    id: workspaceId,
                    projectId: invalidProject,
                    branchName: nil,
                    workspaceType: .external,
                    worktreePath: nil,
                    title: "Terminal",
                    customTitle: nil,
                    currentDirectory: "/repo",
                    panelCount: 2,
                    terminalDirectories: ["/repo/api", "/repo/web"],
                    terminalCustomTitles: [nil, "Frontend"]
                )
            ]
        ).reconciledForRestore()
        assertEqual(
            reconciled.workspaces[0].terminalDirectories,
            ["/repo/api", "/repo/web"],
            "reconciliation preserves terminal directories"
        )
        assertEqual(
            reconciled.workspaces[0].terminalCustomTitles,
            [nil, "Frontend"],
            "reconciliation preserves terminal custom titles"
        )
    }

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }
}
