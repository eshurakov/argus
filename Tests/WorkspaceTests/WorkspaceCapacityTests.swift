import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct WorkspaceCapacityTests {
    @Test
    func projectCreationCannotExceedTheRestorableWorkspaceLimit() async throws {
        let temporary = try TestTemporaryDirectory(prefix: "argus-workspace-capacity")
        defer { temporary.remove() }
        let repo = temporary.url.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try TestGit.run(["init", "-b", "main", "."], in: repo)

        let defaults = try #require(UserDefaults(suiteName: "ArgusWorkspaceCapacity-\(UUID().uuidString)"))
        let snapshotURL = temporary.url.appendingPathComponent("session.json")
        let manager = WorkspaceManager(
            settings: AppSettings(defaults: defaults),
            sessionSnapshotURL: snapshotURL,
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
        while manager.workspaces.count < WorkspaceManager.maxWorkspaces {
            #expect(manager.addWorkspace() != nil)
        }

        let project = await manager.createProject(
            repositoryPath: repo.path,
            mainBranchOverride: "main"
        )

        #expect(project == nil)
        #expect(manager.workspaces.count == WorkspaceManager.maxWorkspaces)
        let persisted = try JSONDecoder().decode(
            ArgusSessionSnapshot.self,
            from: Data(contentsOf: snapshotURL)
        )
        #expect(persisted.isValidForRestore(maxWorkspaces: WorkspaceManager.maxWorkspaces))
    }
}
