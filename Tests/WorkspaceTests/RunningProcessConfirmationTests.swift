import Foundation
import Testing

@testable import Argus

private final class RunningProcessConfirmationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: RunningProcessCloseRequest?
    private var observer: NSObjectProtocol?

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: .showRunningProcessConfirmation,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.record(notification)
        }
    }

    func record(_ notification: Notification) {
        lock.lock()
        request = notification.object as? RunningProcessCloseRequest
        lock.unlock()
    }

    func value() -> RunningProcessCloseRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

private final class WorkspaceConfirmationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var workspaceId: UUID?
    private var observer: NSObjectProtocol?

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: .showCloseWorkspaceConfirmation,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.record(notification)
        }
    }

    func record(_ notification: Notification) {
        lock.lock()
        workspaceId = notification.userInfo?["workspaceId"] as? UUID
        lock.unlock()
    }

    func value() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return workspaceId
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

@Suite
struct RunningProcessConfirmationTests {
    @Test
    @MainActor
    func closingANonLastTerminalWithARunningProcessRequestsConfirmation() throws {
        let manager = try makeManager(suiteName: "ArgusTests.RunningProcessTabClose")
        let workspace = try #require(manager.selectedWorkspace)
        let firstTerminalId = try #require(workspace.panelOrder.first)
        let remainingTerminalId = workspace.addTerminalPanel(workingDirectory: "/tmp").id
        setNeedsConfirmQuit(true, on: firstTerminalId, in: workspace)
        let confirmation = observeRunningProcessConfirmation()

        manager.requestCloseTab(firstTerminalId, in: workspace.id)

        #expect(confirmation.value()?.scope == .tab(workspaceId: workspace.id, tabId: firstTerminalId))
        #expect(confirmation.value()?.processCount == 1)
        #expect(workspace.panelOrder == [firstTerminalId, remainingTerminalId])
        #expect(workspace.activePanelId == remainingTerminalId)
    }

    @Test
    @MainActor
    func confirmingARunningProcessTabCloseRemovesTheTab() throws {
        let manager = try makeManager(suiteName: "ArgusTests.RunningProcessTabConfirm")
        let workspace = try #require(manager.selectedWorkspace)
        let firstTerminalId = try #require(workspace.panelOrder.first)
        let remainingTerminalId = workspace.addTerminalPanel(workingDirectory: "/tmp").id
        setNeedsConfirmQuit(true, on: firstTerminalId, in: workspace)

        manager.requestCloseTab(firstTerminalId, in: workspace.id)
        manager.requestCloseTab(
            firstTerminalId,
            in: workspace.id,
            confirmingRunningProcess: true
        )

        #expect(workspace.panelOrder == [remainingTerminalId])
        #expect(workspace.activePanelId == remainingTerminalId)
    }

    @Test
    @MainActor
    func closingASplitPaneWithARunningProcessRequestsConfirmation() throws {
        let manager = try makeManager(suiteName: "ArgusTests.RunningProcessPaneClose")
        let workspace = try #require(manager.selectedWorkspace)
        let tabId = try #require(workspace.activeTabId)
        let firstPaneId = try #require(workspace.activePanelId)
        let splitPane = try #require(manager.splitActiveTerminal(direction: .vertical))
        setNeedsConfirmQuit(true, on: splitPane.id, in: workspace)
        let confirmation = observeRunningProcessConfirmation()

        manager.requestClosePane(splitPane.id, in: workspace.id)

        #expect(confirmation.value()?.scope == .pane(workspaceId: workspace.id, panelId: splitPane.id))
        #expect(workspace.layout(for: tabId).leaves.contains(firstPaneId))
        #expect(workspace.layout(for: tabId).leaves.contains(splitPane.id))
    }

    @Test
    @MainActor
    func confirmingARunningProcessPaneCloseRemovesOnlyThatPane() throws {
        let manager = try makeManager(suiteName: "ArgusTests.RunningProcessPaneConfirm")
        let workspace = try #require(manager.selectedWorkspace)
        let tabId = try #require(workspace.activeTabId)
        let firstPaneId = try #require(workspace.activePanelId)
        let splitPane = try #require(manager.splitActiveTerminal(direction: .vertical))
        setNeedsConfirmQuit(true, on: splitPane.id, in: workspace)

        manager.requestClosePane(
            splitPane.id,
            in: workspace.id,
            confirmingRunningProcess: true
        )

        #expect(workspace.panelOrder == [tabId])
        #expect(workspace.layout(for: tabId).leaves == [firstPaneId])
        #expect(workspace.panels[splitPane.id] == nil)
    }

    @Test
    @MainActor
    func keepOpenFinalTerminalWithARunningProcessRequestsProcessConfirmation() throws {
        let manager = try makeManager(
            suiteName: "ArgusTests.RunningProcessKeepOpen",
            keepWorkspaceOpen: true
        )
        let workspace = try #require(manager.selectedWorkspace)
        let terminalId = try #require(workspace.activePanelId)
        setNeedsConfirmQuit(true, on: terminalId, in: workspace)
        let processConfirmation = observeRunningProcessConfirmation()
        let workspaceConfirmation = observeWorkspaceConfirmation()

        manager.requestCloseTab(terminalId, in: workspace.id)

        #expect(processConfirmation.value()?.scope == .tab(workspaceId: workspace.id, tabId: terminalId))
        #expect(workspaceConfirmation.value() == nil)
        #expect(workspace.panelOrder == [terminalId])
    }

    @Test
    @MainActor
    func lastTerminalWorkspaceConfirmationLeavesStateUnchangedWhenAProcessIsRunning() throws {
        let manager = try makeManager(suiteName: "ArgusTests.RunningProcessLastTerminal")
        let workspace = try #require(manager.selectedWorkspace)
        let terminalId = try #require(workspace.activePanelId)
        setNeedsConfirmQuit(true, on: terminalId, in: workspace)
        let processConfirmation = observeRunningProcessConfirmation()
        let workspaceConfirmation = observeWorkspaceConfirmation()

        manager.requestCloseTab(terminalId, in: workspace.id)

        #expect(workspaceConfirmation.value() == workspace.id)
        #expect(processConfirmation.value() == nil)
        #expect(workspace.panelOrder == [terminalId])
        #expect(workspace.activePanelId == terminalId)
        #expect(workspace.runningProcessCount == 1)
    }

    @Test
    @MainActor
    func closingAWorkspaceWithARunningProcessRequestsConfirmation() throws {
        let manager = try makeManager(suiteName: "ArgusTests.RunningProcessWorkspaceClose")
        let workspace = try #require(manager.selectedWorkspace)
        let workspaceId = workspace.id
        let terminalId = try #require(workspace.activePanelId)
        setNeedsConfirmQuit(true, on: terminalId, in: workspace)
        let confirmation = observeWorkspaceConfirmation()

        manager.requestCloseWorkspace(workspaceId)

        #expect(confirmation.value() == workspaceId)
        #expect(manager.workspaces.contains { $0.id == workspaceId })
        #expect(workspace.panelOrder == [terminalId])
    }

    @Test
    @MainActor
    func ghosttySurfaceCloseWithALiveProcessRequestsConfirmation() throws {
        let manager = try makeManager(suiteName: "ArgusTests.RunningProcessSurfaceClose")
        let workspace = try #require(manager.selectedWorkspace)
        let workspaceId = workspace.id
        let surfaceId = try #require(workspace.activePanelId)
        let confirmation = observeRunningProcessConfirmation()

        NotificationCenter.default.post(
            name: .argusCloseSurface,
            object: surfaceId,
            userInfo: ["processAlive": true]
        )

        #expect(confirmation.value()?.scope == .surface(workspaceId: workspaceId, surfaceId: surfaceId))
        #expect(manager.workspaces.contains { $0.id == workspaceId })
        #expect(workspace.panelOrder == [surfaceId])
    }

    @Test
    @MainActor
    func ghosttySurfaceCloseWithoutALiveProcessStillCloses() throws {
        let manager = try makeManager(suiteName: "ArgusTests.ExitedProcessSurfaceClose")
        let workspace = try #require(manager.selectedWorkspace)
        let workspaceId = workspace.id
        let surfaceId = try #require(workspace.activePanelId)

        NotificationCenter.default.post(
            name: .argusCloseSurface,
            object: surfaceId,
            userInfo: ["processAlive": false]
        )

        #expect(!manager.workspaces.contains { $0.id == workspaceId })
    }

    @Test
    @MainActor
    func totalRunningProcessCountAggregatesTerminalSurfaces() throws {
        let manager = try makeManager(suiteName: "ArgusTests.RunningProcessCount")
        let workspace = try #require(manager.selectedWorkspace)
        let first = try #require(workspace.activePanelId)
        let second = workspace.addTerminalPanel(workingDirectory: "/tmp").id
        setNeedsConfirmQuit(true, on: first, in: workspace)
        setNeedsConfirmQuit(true, on: second, in: workspace)

        #expect(workspace.runningProcessCount == 2)
        #expect(manager.totalRunningProcessCount == 2)
    }

    @MainActor
    private func makeManager(
        suiteName: String,
        keepWorkspaceOpen: Bool = false
    ) throws -> WorkspaceManager {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults)
        settings.keepWorkspaceOpenAfterLastTerminalCloses = keepWorkspaceOpen
        return WorkspaceManager(
            settings: settings,
            sessionSnapshotURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathComponent("session.json"),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
    }

    @MainActor
    private func setNeedsConfirmQuit(_ value: Bool, on panelId: UUID, in workspace: Workspace) {
        (workspace.panels[panelId] as? TerminalPanel)?.surface.needsConfirmQuitOverride = value
    }

    @MainActor
    private func observeRunningProcessConfirmation() -> RunningProcessConfirmationRecorder {
        let recorder = RunningProcessConfirmationRecorder()
        recorder.start()
        return recorder
    }

    @MainActor
    private func observeWorkspaceConfirmation() -> WorkspaceConfirmationRecorder {
        let recorder = WorkspaceConfirmationRecorder()
        recorder.start()
        return recorder
    }
}
