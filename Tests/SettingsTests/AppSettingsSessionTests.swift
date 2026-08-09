import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct AppSettingsSessionTests {
    @Test
    func restorePreferenceAndEnvironmentOverridesSkipSessionRestore() async throws {
        try await MainActor.run {
            let defaults = makeDefaults()
            defer { clear(defaults) }
            let snapshotURL = temporarySnapshotURL()
            defer { try? FileManager.default.removeItem(at: snapshotURL) }
            try makeRestorableSnapshot(directory: "/restored").write(to: snapshotURL)

            let enabled = AppSettings(defaults: defaults)
            let restoredManager = WorkspaceManager(
                settings: enabled,
                sessionSnapshotURL: snapshotURL,
                environment: [:]
            )
            #expect(restoredManager.selectedWorkspace?.currentDirectory == "/restored")

            enabled.restorePreviousSession = false
            let disabledManager = WorkspaceManager(
                settings: enabled,
                sessionSnapshotURL: snapshotURL,
                environment: [:]
            )
            #expect(disabledManager.selectedWorkspace?.currentDirectory != "/restored")

            enabled.restorePreviousSession = true
            let overriddenManager = WorkspaceManager(
                settings: enabled,
                sessionSnapshotURL: snapshotURL,
                environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
            )
            #expect(overriddenManager.selectedWorkspace?.currentDirectory != "/restored")
        }
    }

    @Test
    func standaloneWorkspaceDefaultDirectoryOnlyAppliesWithoutExplicitPath() async throws {
        await MainActor.run {
            let defaults = makeDefaults()
            defer { clear(defaults) }
            let settings = AppSettings(defaults: defaults)
            settings.defaultStandaloneWorkspaceDirectory = "/preferred"
            let snapshotURL = temporarySnapshotURL()
            defer { try? FileManager.default.removeItem(at: snapshotURL) }
            let manager = WorkspaceManager(
                settings: settings,
                sessionSnapshotURL: snapshotURL,
                environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
            )

            #expect(manager.selectedWorkspace?.currentDirectory == "/preferred")
            #expect(manager.addWorkspace()?.currentDirectory == "/preferred")
            #expect(manager.addWorkspace(workingDirectory: "/explicit")?.currentDirectory == "/explicit")

            let lastWorkspace = manager.workspaces.last!
            manager.removeWorkspace(lastWorkspace.id)
            manager.removeWorkspace(manager.workspaces[0].id)
            manager.removeWorkspace(manager.workspaces[0].id)
            #expect(manager.selectedWorkspace?.currentDirectory == "/preferred")
        }
    }

    @Test
    func audibleBellPolicyUsesIsolatedDefaults() {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let policy = AudibleBellPolicy(defaults: defaults)

        #expect(policy.shouldPlay())
        defaults.set(false, forKey: AudibleBellPolicy.defaultsKey)
        #expect(!policy.shouldPlay())
        defaults.set(true, forKey: AudibleBellPolicy.defaultsKey)
        #expect(policy.shouldPlay())
    }
}

@MainActor
func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "com.argus.tests.settings.\(UUID().uuidString)")!
}

func clear(_ defaults: UserDefaults) {
    defaults.dictionaryRepresentation().keys.forEach { defaults.removeObject(forKey: $0) }
}

func temporarySnapshotURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("argus-settings-\(UUID().uuidString).json")
}

@MainActor
func makeRestorableSnapshot(directory: String) throws -> Data {
    let workspaceId = UUID()
    let catchAll = Project.catchAll()
    let snapshot = ArgusSessionSnapshot(
        selectedWorkspaceId: workspaceId,
        projects: [
            ProjectSnapshot(
                id: catchAll.id,
                repositoryPath: "",
                isCatchAll: true,
                displayName: "Workspaces",
                mainBranch: "",
                workspaceIds: [workspaceId],
                isExpanded: true,
                color: nil
            )
        ],
        workspaces: [
            WorkspaceSnapshot(
                id: workspaceId,
                projectId: catchAll.id,
                branchName: nil,
                workspaceType: .external,
                worktreePath: nil,
                title: "Restored",
                customTitle: nil,
                currentDirectory: directory,
                panelCount: 1
            )
        ]
    )
    return try JSONEncoder().encode(snapshot)
}
