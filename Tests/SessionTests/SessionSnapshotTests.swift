import Foundation
import Testing

@testable import Argus

@Suite
struct SessionSnapshotTests {
    @Test
    func buildRunQuitsOnlyExistingArgusProcesses() throws {
        let script = try SourceContract("scripts/build.sh")

        script.containsAll(
            [
                "pgrep -x \"${APP_NAME}\"",
                "NSRunningApplication.runningApplicationWithProcessIdentifier(${pid})",
                "if (app) app.terminate",
                "kill -0 \"${pid}\""
            ],
            "run and install must gracefully terminate the exact running app before replacement"
        )
        script.excludes(
            "tell application \\\"${APP_NAME}\\\" to quit",
            "name-based quit can launch another registered Argus bundle and overwrite its session"
        )
        let runSection = try script.section(after: "do_run() {", before: "do_install() {")
        let runQuit = try #require(runSection.range(of: "quit_running"))
        let runBuild = try #require(runSection.range(of: "do_build"))
        #expect(runQuit.lowerBound < runBuild.lowerBound)

        let installSection = try script.section(after: "do_install() {", before: "do_clean() {")
        let installQuit = try #require(installSection.range(of: "quit_running"))
        let installBuild = try #require(installSection.range(of: "do_build"))
        #expect(installQuit.lowerBound < installBuild.lowerBound)
    }

    @Test
    func coveredBehaviors() throws {
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

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }
}
