import AppKit
import SwiftUI

@main
struct ArgusApp: App {
    @StateObject private var workspaceManager: WorkspaceManager
    @StateObject private var agentStatusStore: AgentStatusStore
    @StateObject private var appSettings: AppSettings
    @StateObject private var turnCompletionAttentionStore: TurnCompletionAttentionStore
    @StateObject private var kiloIntegration: KiloIntegrationModel
    @StateObject private var piIntegration: PiIntegrationModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let settings = AppSettings()
        let attentionStore = TurnCompletionAttentionStore()
        let statusStore = AgentStatusStore()
        let manager = WorkspaceManager(settings: settings)
        let agentStatusRuntime = AgentStatusRuntime(workspaceManager: manager, store: statusStore)
        _appSettings = StateObject(wrappedValue: settings)
        _workspaceManager = StateObject(wrappedValue: manager)
        _agentStatusStore = StateObject(wrappedValue: statusStore)
        _turnCompletionAttentionStore = StateObject(wrappedValue: attentionStore)
        let kiloIntegration = KiloIntegrationModel()
        let piIntegration = PiIntegrationModel()
        _kiloIntegration = StateObject(wrappedValue: kiloIntegration)
        _piIntegration = StateObject(wrappedValue: piIntegration)
        let runtime = TurnCompletionRuntime(
            workspaceManager: manager,
            attentionStore: attentionStore,
            isMainWindowKey: {
                NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.isKeyWindow }
            },
            onAcceptedUnviewed: {
                if settings.agentCompletionSound {
                    TurnCompletionSoundPlayer.play()
                }
            }
        )
        manager.setTurnCompletionRuntime(runtime)
        manager.setAgentStatusRuntime(agentStatusRuntime)
        appDelegate.configureTurnCompletion(
            workspaceManager: manager,
            runtime: runtime,
            agentStatusRuntime: agentStatusRuntime
        )
        appDelegate.configureSettings(
            settings: settings,
            kiloIntegration: kiloIntegration,
            piIntegration: piIntegration
        )

        // Initialize GhosttyApp singleton — this triggers ghostty_init and
        // configures the terminal environment (TERM, PATH, GHOSTTY_RESOURCES_DIR).
        _ = GhosttyApp.shared
    }

    var body: some Scene {
        Window("Argus", id: "main") {
            MainWindowView()
                .environmentObject(workspaceManager)
                .environmentObject(agentStatusStore)
                .environmentObject(appSettings)
                .environmentObject(turnCompletionAttentionStore)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            // File menu — replace default "New" with workspace/tab commands
            CommandGroup(replacing: .newItem) {
                Button("New Project\u{2026}") {
                    NotificationCenter.default.post(
                        name: .showNewProjectSheet, object: nil
                    )
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("New Workspace") {
                    workspaceManager.addWorkspace()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("New Tab") {
                    workspaceManager.addTab()
                }
                .keyboardShortcut("t", modifiers: [.command])

                Button("New Browser Tab") {
                    workspaceManager.addBrowserTab()
                }

                Button("Split Vertically") {
                    workspaceManager.splitActiveTerminal(direction: .vertical)
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button("Split Horizontally") {
                    workspaceManager.splitActiveTerminal(direction: .horizontal)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }

            CommandGroup(after: .textEditing) {
                Divider()

                Button("Find\u{2026}") {
                    workspaceManager.requestFindInActiveBrowser()
                }
                .keyboardShortcut("f", modifiers: [.command])
            }

            // Close commands — placed after new-item group
            CommandGroup(after: .newItem) {
                Button("Close Tab") {
                    workspaceManager.closeCurrentTab()
                }
                .keyboardShortcut("w", modifiers: [.command])
            }

            // View menu — sidebar toggles and workspace selection
            CommandGroup(after: .toolbar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(
                        name: .toggleSidebar, object: nil
                    )
                }
                .keyboardShortcut("b", modifiers: [.command])

                Button("Toggle Right Sidebar") {
                    NotificationCenter.default.post(
                        name: .toggleGitSidebar, object: nil
                    )
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Divider()

                Button("Select Previous Tab") {
                    workspaceManager.selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command])

                Button("Select Next Tab") {
                    workspaceManager.selectNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command])

                Divider()

                // Workspace selection: Cmd+1 through Cmd+9
                ForEach(1...9, id: \.self) { number in
                    Button("Workspace \(number)") {
                        workspaceManager.handleWorkspaceShortcut(number: number)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(number)")),
                        modifiers: .command
                    )
                }
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Toggle the workspace sidebar visibility.
    static let toggleSidebar = Notification.Name("ArgusToggleSidebar")
    /// Toggle the git status sidebar visibility.
    static let toggleGitSidebar = Notification.Name("ArgusToggleGitSidebar")
    /// Active workspace context changed; synchronize titlebar/window metadata.
    static let workspaceContextDidChange = Notification.Name("ArgusWorkspaceContextDidChange")
    /// Terminal NSView focus changed; synchronize the active split pane.
    static let terminalSurfaceDidBecomeFirstResponder = Notification.Name("ArgusTerminalSurfaceDidBecomeFirstResponder")
}
