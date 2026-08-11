import Testing

@Suite
struct ProcessCloseUIContractTests {
    @Test
    func runningProcessCloseUsesInViewConfirmationWithoutAModalRunLoop() throws {
        let confirmation = try SourceContract(
            "Argus/Views/Dialogs/RunningProcessConfirmationView.swift"
        )
        confirmation.containsAll(
            [
                "Button(\"Cancel\", action: onCancel)",
                "Button(confirmTitle, action: onConfirm)",
                ".foregroundStyle(.red)",
                "This terminal still has a running process.",
                "Closing it will terminate that process.",
                "Quit Argus?"
            ], "in-view running-process close choices"
        )
        confirmation.excludes("NSAlert", "Running-process close must not open an AppKit alert")
        confirmation.excludes("runModal()", "Running-process close must not start a modal run loop")
        confirmation.excludes("role: .destructive", "Running-process close avoids destructive roles")
    }

    @Test
    func closeCommandsQueryGhosttyBeforeMutatingState() throws {
        let manager = try SourceContract("Argus/Services/WorkspaceManager.swift")
        manager.containsAll(
            [
                "func requestCloseTab(",
                "confirmingRunningProcess: Bool = false",
                "func requestClosePane(",
                "workspace.runningProcessCount(inTab: tabId)",
                "workspace.terminalNeedsConfirmQuit(panelId)",
                "name: .showRunningProcessConfirmation",
                "func completeSurfaceClose(_ surfaceId: UUID)"
            ], "close paths consult Ghostty before teardown"
        )
        try SourceContract("Argus/Ghostty/TerminalSurface.swift").contains(
            "ghostty_surface_needs_confirm_quit",
            "process liveness uses Ghostty's close-confirmation heuristic"
        )
        try SourceContract("Argus/Ghostty/GhosttyCallbacks.swift").contains(
            "userInfo: [\"processAlive\": processAlive]",
            "Ghostty close callbacks forward process liveness"
        )
        try SourceContract("Argus/App/AppDelegate.swift").containsAll(
            [
                "func applicationShouldTerminate",
                "requestApplicationQuitConfirmation()",
                "MainWindowCloseGuard"
            ], "application and window close confirm running processes"
        )
    }

    @Test
    func mainWindowPresentsRunningProcessConfirmation() throws {
        let window = try SourceContract("Argus/Views/MainWindowView.swift")
        window.containsAll(
            [
                "@State private var runningProcessRequest: RunningProcessCloseRequest?",
                "RunningProcessConfirmationView(",
                "confirmRunningProcessClose(runningProcessRequest)",
                "workspaceManager.requestCloseTab(",
                "confirmingRunningProcess: true",
                "workspaceManager.completeSurfaceClose(surfaceId)",
                "name: .confirmApplicationQuit"
            ], "main window hosts running-process confirmation"
        )
    }
}
