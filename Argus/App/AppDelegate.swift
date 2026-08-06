import AppKit
import SwiftUI

/// NSApplicationDelegate handling window lifecycle and configuration.
///
/// The delegate is connected to the SwiftUI lifecycle via
/// `@NSApplicationDelegateAdaptor` in `ArgusApp`. It receives a reference
/// to `WorkspaceManager` on first window appear so it can update the
/// window title when the active workspace changes.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    private var workspaceManager: WorkspaceManager?
    private var turnCompletionRuntime: TurnCompletionRuntime?
    private var agentStatusRuntime: AgentStatusRuntime?
    private var agentSocketServer: AgentSocketServer?
    private var settings: AppSettings?
    private var kiloIntegration: KiloIntegrationModel?
    private var piIntegration: PiIntegrationModel?
    private var settingsWindowController: SettingsWindowController?

    // MARK: - NSApplicationDelegate

    /// Tracks windows we've already configured to avoid redundant work.
    private var configuredWindows: Set<ObjectIdentifier> = []
    private var windowTitleObserver: NSObjectProtocol?
    private var windowKeyObservers: [NSObjectProtocol] = []

    func configureTurnCompletion(
        workspaceManager: WorkspaceManager,
        runtime: TurnCompletionRuntime,
        agentStatusRuntime: AgentStatusRuntime
    ) {
        self.workspaceManager = workspaceManager
        turnCompletionRuntime = runtime
        self.agentStatusRuntime = agentStatusRuntime
        startAgentSocketIfReady()
    }

    func configureSettings(
        settings: AppSettings,
        kiloIntegration: KiloIntegrationModel,
        piIntegration: PiIntegrationModel
    ) {
        self.settings = settings
        self.kiloIntegration = kiloIntegration
        self.piIntegration = piIntegration
    }

    func showSettings() {
        if let settingsWindowController {
            settingsWindowController.showWindow(nil)
            settingsWindowController.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let settings, let kiloIntegration, let piIntegration else { return }

        let controller = SettingsWindowController(
            settings: settings,
            kiloIntegration: kiloIntegration,
            piIntegration: piIntegration
        )
        settingsWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ application: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure any existing windows
        for window in NSApp.windows {
            configureWindow(window)
        }

        // Observe new windows becoming key — SwiftUI may create them after
        // applicationDidFinishLaunching, so we configure them on first focus.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                let window = notification.object as? NSWindow
            else { return }
            self.configureWindow(window)
        }

        windowTitleObserver = NotificationCenter.default.addObserver(
            forName: .workspaceContextDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateWindowTitle()
        }
        windowKeyObservers = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow,
                    window.identifier?.rawValue == "main"
                else { return }
                Task { @MainActor [weak self] in
                    self?.workspaceManager?.acknowledgeSelectedActiveTabIfViewed()
                }
            },
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: nil,
                queue: .main
            ) { _ in }
        ]
        startAgentSocketIfReady()

        // Start Ghostty after the initial view hierarchy is mounted. GhosttyApp
        // restores the C numeric locale synchronously before startup returns.
        DispatchQueue.main.async {
            GhosttyApp.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspaceManager?.saveSession()
        if let windowTitleObserver {
            NotificationCenter.default.removeObserver(windowTitleObserver)
        }
        windowKeyObservers.forEach(NotificationCenter.default.removeObserver)
        if let agentSocketServer {
            let shutdown = DispatchSemaphore(value: 0)
            Task.detached {
                await agentSocketServer.shutdown()
                shutdown.signal()
            }
            shutdown.wait()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    // MARK: - Window Configuration

    private func configureWindow(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard !configuredWindows.contains(id) else { return }
        configuredWindows.insert(id)

        // Only the main terminal shell window gets the black, chrome-less
        // styling below — auxiliary windows (Settings, panels, alerts) must
        // keep their normal system appearance. `Window("Argus", id: "main")`
        // in ArgusApp gives that window this identifier.
        guard window.identifier?.rawValue == "main" else { return }

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = ChromeColors.shellBackgroundNSColor
        window.isRestorable = false

        // Window sizing
        window.minSize = NSSize(width: 600, height: 400)

        // Set initial title (visible in Mission Control / Exposé).
        window.title = "Argus"
    }

    /// Updates the window title to reflect the active workspace.
    ///
    /// Falls back to "Argus" when no workspace is selected.
    func updateWindowTitle(_ window: NSWindow? = nil) {
        let targetWindow = window ?? NSApp.windows.first { $0.identifier?.rawValue == "main" }
        targetWindow?.title =
            workspaceManager?.activeWorkspaceTitle
            ?? WorkspaceTitleFormatter.fallbackTitle
    }

    private func startAgentSocketIfReady() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard agentSocketServer == nil,
            let turnCompletionRuntime,
            let agentStatusRuntime
        else { return }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".argus/argus.sock").path
        let server = AgentSocketServer(
            path: path,
            deliver: { event in
                turnCompletionRuntime.receive(event)
            },
            deliverStatus: { event in
                agentStatusRuntime.receive(event)
            }
        )
        agentSocketServer = server
        Task {
            do {
                try await server.start()
            } catch {
                self.agentSocketServer = nil
            }
        }
    }
}
