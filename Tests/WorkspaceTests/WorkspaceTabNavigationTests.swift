import Foundation
import Testing

@testable import Argus

private final class CloseConfirmationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var workspaceId: UUID?
    private var requestedByLastTerminalTab = false

    func record(_ notification: Notification) {
        lock.lock()
        workspaceId = notification.userInfo?["workspaceId"] as? UUID
        requestedByLastTerminalTab =
            notification.userInfo?["requestedByLastTerminalTab"] as? Bool ?? false
        lock.unlock()
    }

    func values() -> (workspaceId: UUID?, requestedByLastTerminalTab: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (workspaceId, requestedByLastTerminalTab)
    }
}

@Suite
struct WorkspaceTabNavigationTests {
    @Test
    func commandBracketsStayWiredToTabCycling() throws {
        let app = try SourceContract("Argus/App/ArgusApp.swift")
        app.containsAll(
            [
                "Button(\"Select Previous Tab\")",
                "workspaceManager.selectPreviousTab()",
                ".keyboardShortcut(\"[\", modifiers: [.command])",
                "Button(\"Select Next Tab\")",
                "workspaceManager.selectNextTab()",
                ".keyboardShortcut(\"]\", modifiers: [.command])"
            ], "tab cycling commands")
    }

    @Test
    @MainActor
    func cyclingSelectsAdjacentTabsWithWraparound() throws {
        let workspace = Workspace(workingDirectory: "/tmp")
        let firstTab = try #require(workspace.panelOrder.first)
        let secondTab = workspace.addTerminalPanel(workingDirectory: "/tmp/second").id
        let lastTab = workspace.addTerminalPanel(workingDirectory: "/tmp/last").id

        workspace.selectNextTab()
        #expect(workspace.activeTabId == firstTab)

        workspace.selectPreviousTab()
        #expect(workspace.activeTabId == lastTab)

        workspace.selectPanel(secondTab)
        workspace.selectPreviousTab()
        #expect(workspace.activeTabId == firstTab)

        workspace.selectNextTab()
        #expect(workspace.activeTabId == secondTab)
    }

    @Test
    @MainActor
    func closingLastTerminalRequestsWorkspaceConfirmationWithoutChangingSelection() throws {
        let defaults = try #require(UserDefaults(suiteName: "ArgusTests.LastTerminalClose"))
        defaults.removePersistentDomain(forName: "ArgusTests.LastTerminalClose")
        defer { defaults.removePersistentDomain(forName: "ArgusTests.LastTerminalClose") }
        let manager = WorkspaceManager(
            settings: AppSettings(defaults: defaults),
            sessionSnapshotURL: temporarySnapshotURL(),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
        let workspace = try #require(manager.selectedWorkspace)
        let terminalId = try #require(workspace.activePanelId)
        let confirmation = CloseConfirmationRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: .showCloseWorkspaceConfirmation,
            object: nil,
            queue: nil
        ) { notification in
            confirmation.record(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        manager.requestCloseTab(terminalId, in: workspace.id)

        let confirmationValues = confirmation.values()
        #expect(confirmationValues.workspaceId == workspace.id)
        #expect(confirmationValues.requestedByLastTerminalTab)
        #expect(manager.workspaces.contains(where: { $0.id == workspace.id }))
        #expect(workspace.panelOrder == [terminalId])
        #expect(workspace.activePanelId == terminalId)
    }

    @Test
    @MainActor
    func closingTerminalDirectlyStillWorksWhenAnotherTabRemains() throws {
        let defaults = try #require(UserDefaults(suiteName: "ArgusTests.NonLastTerminalClose"))
        defaults.removePersistentDomain(forName: "ArgusTests.NonLastTerminalClose")
        defer { defaults.removePersistentDomain(forName: "ArgusTests.NonLastTerminalClose") }
        let manager = WorkspaceManager(
            settings: AppSettings(defaults: defaults),
            sessionSnapshotURL: temporarySnapshotURL(),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
        let workspace = try #require(manager.selectedWorkspace)
        let firstTerminalId = try #require(workspace.panelOrder.first)
        let remainingTerminalId = workspace.addTerminalPanel(workingDirectory: "/tmp").id

        manager.requestCloseTab(firstTerminalId, in: workspace.id)

        #expect(workspace.panelOrder == [remainingTerminalId])
        #expect(workspace.activePanelId == remainingTerminalId)
    }

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
