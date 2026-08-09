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
struct WorkspaceTabNavigationTests {  // swiftlint:disable:this type_body_length
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
    func closingLastTerminalCanRetainAnEmptyWorkspaceAndReopenItsRoot() throws {
        let defaults = try #require(UserDefaults(suiteName: "ArgusTests.RetainLastTerminalClose"))
        defaults.removePersistentDomain(forName: "ArgusTests.RetainLastTerminalClose")
        defer { defaults.removePersistentDomain(forName: "ArgusTests.RetainLastTerminalClose") }
        let settings = AppSettings(defaults: defaults)
        settings.keepWorkspaceOpenAfterLastTerminalCloses = true
        let manager = WorkspaceManager(
            settings: settings,
            sessionSnapshotURL: temporarySnapshotURL(),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
        let workspace = try #require(manager.selectedWorkspace)
        let workspaceId = workspace.id
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

        manager.requestCloseTab(terminalId, in: workspaceId)

        let confirmationValues = confirmation.values()
        #expect(confirmationValues.workspaceId == nil)
        #expect(manager.selectedWorkspaceId == workspaceId)
        #expect(manager.workspaces.contains { $0.id == workspaceId })
        #expect(workspace.panelOrder.isEmpty)
        #expect(workspace.panels.isEmpty)
        #expect(workspace.tabLayouts.isEmpty)
        #expect(workspace.terminalCustomTitles.isEmpty)
        #expect(workspace.activePanelId == nil)
        #expect(workspace.activeTabId == nil)

        let snapshot = workspace.snapshot()
        #expect(snapshot.panelCount == 0)
        #expect(snapshot.terminalDirectories.isEmpty)
        #expect(snapshot.terminalCustomTitles.isEmpty)

        let reopened = try #require(manager.addTab())
        #expect(reopened.directory == workspace.currentDirectory)
        #expect(workspace.panelOrder == [reopened.id])
        #expect(workspace.activePanelId == reopened.id)
        #expect(workspace.activeTabId == reopened.id)
        #expect(manager.selectedWorkspaceId == workspaceId)
    }

    @Test
    @MainActor
    func finalSplitTerminalCloseEvaluatesRetentionBeforeClosingPanes() throws {
        let defaults = try #require(UserDefaults(suiteName: "ArgusTests.RetainSplitClose"))
        defaults.removePersistentDomain(forName: "ArgusTests.RetainSplitClose")
        defer { defaults.removePersistentDomain(forName: "ArgusTests.RetainSplitClose") }
        let settings = AppSettings(defaults: defaults)
        let manager = WorkspaceManager(
            settings: settings,
            sessionSnapshotURL: temporarySnapshotURL(),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
        let workspace = try #require(manager.selectedWorkspace)
        let tabId = try #require(workspace.activeTabId)
        let splitPanel = try #require(manager.splitActiveTerminal(direction: .vertical))
        let leavesBeforeClose = workspace.layout(for: tabId).leaves

        manager.requestCloseTab(tabId, in: workspace.id)

        #expect(workspace.panelOrder == [tabId])
        #expect(workspace.layout(for: tabId).leaves == leavesBeforeClose)
        #expect(workspace.panels.count == leavesBeforeClose.count)

        settings.keepWorkspaceOpenAfterLastTerminalCloses = true
        manager.requestCloseTab(tabId, in: workspace.id)

        #expect(workspace.panelOrder.isEmpty)
        #expect(workspace.panels.isEmpty)
        #expect(splitPanel.id != tabId)
        #expect(manager.selectedWorkspaceId == workspace.id)
    }

    @Test
    @MainActor
    func finalNonterminalTabStillUsesWorkspaceRemovalLifecycle() throws {
        let defaults = try #require(UserDefaults(suiteName: "ArgusTests.NonterminalFinalTab"))
        defaults.removePersistentDomain(forName: "ArgusTests.NonterminalFinalTab")
        defer { defaults.removePersistentDomain(forName: "ArgusTests.NonterminalFinalTab") }
        let settings = AppSettings(defaults: defaults)
        settings.keepWorkspaceOpenAfterLastTerminalCloses = true
        let manager = WorkspaceManager(
            settings: settings,
            sessionSnapshotURL: temporarySnapshotURL(),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
        let workspace = try #require(manager.selectedWorkspace)
        let workspaceId = workspace.id
        let terminalId = try #require(workspace.activePanelId)
        manager.requestCloseTab(terminalId, in: workspaceId)

        let browser = try #require(manager.addBrowserTab())
        #expect(workspace.panelOrder == [browser.id])
        #expect(workspace.activeTabId == browser.id)

        manager.requestCloseTab(browser.id, in: workspaceId)

        #expect(!manager.workspaces.contains { $0.id == workspaceId })
        #expect(manager.selectedWorkspace?.panelCount == 1)
    }

    @Test
    @MainActor
    func terminalSurfaceCloseFollowsRetentionPreference() throws {
        let disabledDefaults = try #require(UserDefaults(suiteName: "ArgusTests.SurfaceCloseDisabled"))
        disabledDefaults.removePersistentDomain(forName: "ArgusTests.SurfaceCloseDisabled")
        defer { disabledDefaults.removePersistentDomain(forName: "ArgusTests.SurfaceCloseDisabled") }
        let disabledManager = WorkspaceManager(
            settings: AppSettings(defaults: disabledDefaults),
            sessionSnapshotURL: temporarySnapshotURL(),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
        let removedWorkspace = try #require(disabledManager.selectedWorkspace)
        let removedWorkspaceId = removedWorkspace.id
        let removedSurfaceId = try #require(removedWorkspace.activePanelId)

        NotificationCenter.default.post(name: .argusCloseSurface, object: removedSurfaceId)

        #expect(!disabledManager.workspaces.contains { $0.id == removedWorkspaceId })

        let enabledDefaults = try #require(UserDefaults(suiteName: "ArgusTests.SurfaceCloseEnabled"))
        enabledDefaults.removePersistentDomain(forName: "ArgusTests.SurfaceCloseEnabled")
        defer { enabledDefaults.removePersistentDomain(forName: "ArgusTests.SurfaceCloseEnabled") }
        let enabledSettings = AppSettings(defaults: enabledDefaults)
        enabledSettings.keepWorkspaceOpenAfterLastTerminalCloses = true
        let enabledManager = WorkspaceManager(
            settings: enabledSettings,
            sessionSnapshotURL: temporarySnapshotURL(),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
        let retainedWorkspace = try #require(enabledManager.selectedWorkspace)
        let retainedWorkspaceId = retainedWorkspace.id
        let retainedSurfaceId = try #require(retainedWorkspace.activePanelId)

        NotificationCenter.default.post(name: .argusCloseSurface, object: retainedSurfaceId)

        #expect(enabledManager.selectedWorkspaceId == retainedWorkspaceId)
        #expect(retainedWorkspace.panelOrder.isEmpty)
        #expect(retainedWorkspace.panels.isEmpty)
    }

    @Test
    @MainActor
    func explicitlyClosingAnEmptyLastWorkspaceStillCreatesFreshTerminalWorkspace() throws {
        let defaults = try #require(UserDefaults(suiteName: "ArgusTests.CloseEmptyWorkspace"))
        defaults.removePersistentDomain(forName: "ArgusTests.CloseEmptyWorkspace")
        defer { defaults.removePersistentDomain(forName: "ArgusTests.CloseEmptyWorkspace") }
        let settings = AppSettings(defaults: defaults)
        settings.keepWorkspaceOpenAfterLastTerminalCloses = true
        let manager = WorkspaceManager(
            settings: settings,
            sessionSnapshotURL: temporarySnapshotURL(),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
        let workspace = try #require(manager.selectedWorkspace)
        let workspaceId = workspace.id
        let terminalId = try #require(workspace.activePanelId)
        manager.requestCloseTab(terminalId, in: workspaceId)

        manager.removeWorkspace(workspaceId)

        #expect(!manager.workspaces.contains { $0.id == workspaceId })
        #expect(manager.workspaces.count == 1)
        #expect(manager.selectedWorkspace?.panelCount == 1)
        #expect(manager.selectedWorkspace?.workspaceType == .external)
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
