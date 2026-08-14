import Foundation
import Testing

@testable import Argus

@Suite
struct WorkspaceRootMutationTests {
    @Test
    @MainActor
    func changingStandaloneWorkspaceRootAffectsNewTabsWithoutMovingExistingTerminals() throws {
        let defaults = try #require(UserDefaults(suiteName: "ArgusTests.StandaloneWorkspaceRoot"))
        defaults.removePersistentDomain(forName: "ArgusTests.StandaloneWorkspaceRoot")
        defer { defaults.removePersistentDomain(forName: "ArgusTests.StandaloneWorkspaceRoot") }
        let manager = WorkspaceManager(
            settings: AppSettings(defaults: defaults),
            sessionSnapshotURL: temporarySnapshotURL(),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
        let workspace = try #require(manager.selectedWorkspace)
        let existingTerminal = try #require(workspace.activePanel as? TerminalPanel)
        let existingDirectory = existingTerminal.directory
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-workspace-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = manager.workspaceContextRevision

        #expect(manager.setStandaloneWorkspaceRoot(workspace.id, directoryURL: root))
        #expect(workspace.currentDirectory == root.standardizedFileURL.path)
        #expect(existingTerminal.directory == existingDirectory)
        #expect(manager.workspaceContextRevision == revision + 1)

        let newTerminal = try #require(manager.addTab())
        #expect(newTerminal.directory == root.standardizedFileURL.path)
        #expect(workspace.snapshot().currentDirectory == root.standardizedFileURL.path)
    }

    @Test
    @MainActor
    func changingStandaloneWorkspaceRootAcceptsAnEnteredPath() throws {
        let defaults = try #require(UserDefaults(suiteName: "ArgusTests.EnteredWorkspaceRootPath"))
        defaults.removePersistentDomain(forName: "ArgusTests.EnteredWorkspaceRootPath")
        defer { defaults.removePersistentDomain(forName: "ArgusTests.EnteredWorkspaceRootPath") }
        let manager = WorkspaceManager(
            settings: AppSettings(defaults: defaults),
            sessionSnapshotURL: temporarySnapshotURL(),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
        let workspace = try #require(manager.selectedWorkspace)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-entered-workspace-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(manager.setStandaloneWorkspaceRoot(workspace.id, path: root.path))
        #expect(workspace.currentDirectory == root.standardizedFileURL.path)
    }

    @Test
    @MainActor
    func workspaceRootMutationRejectsNonStandaloneWorkspacesAndMissingDirectories() throws {
        let defaults = try #require(UserDefaults(suiteName: "ArgusTests.WorkspaceRootValidation"))
        defaults.removePersistentDomain(forName: "ArgusTests.WorkspaceRootValidation")
        defer { defaults.removePersistentDomain(forName: "ArgusTests.WorkspaceRootValidation") }
        let manager = WorkspaceManager(
            settings: AppSettings(defaults: defaults),
            sessionSnapshotURL: temporarySnapshotURL(),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
        let workspace = try #require(manager.selectedWorkspace)
        let originalRoot = workspace.currentDirectory
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-missing-root-\(UUID().uuidString)", isDirectory: true)

        #expect(!manager.setStandaloneWorkspaceRoot(workspace.id, directoryURL: missingRoot))
        #expect(workspace.currentDirectory == originalRoot)

        workspace.workspaceType = .mainCheckout
        #expect(
            !manager.setStandaloneWorkspaceRoot(
                workspace.id,
                directoryURL: FileManager.default.temporaryDirectory
            )
        )
        #expect(workspace.currentDirectory == originalRoot)
    }

    private func temporarySnapshotURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("session.json")
    }
}
