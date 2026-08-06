import Testing

@testable import Argus

@Suite
struct BrowserPanelUIContractTests {
    @Test
    func browserStaysInWorkspaceTabsAndUsesPublicWebKitAPIs() throws {
        try SourceContract("Argus/Models/BrowserPanel.swift").containsAll(
            [
                "final class BrowserPanel", "let panelType: PanelType = .browser",
                "let webView: BrowserWKWebView", "webView.isInspectable = developerToolsEnabled",
                "webView.find(trimmedQuery, configuration: configuration)",
                "func unfocus()", "webView.allowsApplicationFocus = false",
                "func setWebContentActive(_ isActive: Bool)"
            ], "browser model lifecycle and public WebKit APIs")
        try SourceContract("Argus/Models/BrowserPanel.swift").excludes(
            "developerExtrasEnabled",
            "browser must not use private developer-tools SPI"
        )

        try SourceContract("Argus/Models/Workspace.swift").containsAll(
            [
                "func addBrowserPanel(",
                "insertAfterActiveTab(panel.id)",
                "panelOrder.insert(panelId, at: activeIndex + 1)",
                "selectPanel(panel.id)"
            ], "Browser Panel top-level tab lifecycle")
        try SourceContract("Argus/Views/Content/ContentAreaView.swift").contains(
            "BrowserView(panel: browserPanel, isActive: isActive)",
            "Browser Panel must render in center workspace content"
        )
        try SourceContract("Argus/Views/Content/ContentAreaView.swift").contains(
            "if panel.panelType == .terminal",
            "pane tap focus must not override Browser Panel controls"
        )
    }

    @Test
    func browserAndAgentStatusUseNormalAccessibleTabLifecycle() throws {
        try SourceContract("Argus/Models/Panel.swift").containsAll(
            [
                "case browser",
                "var isLoading: Bool { get }"
            ], "Browser Panel participates in shared Panel state")
        try SourceContract("Argus/Models/Workspace.swift").containsAll(
            [
                "func addBrowserPanel(",
                "insertAfterActiveTab(panel.id)",
                "panelOrder.insert(panelId, at: activeIndex + 1)",
                "selectPanel(panel.id)",
                "observeBrowserPanel(panel)"
            ], "Browser Panel insertion and observation")
        try SourceContract("Argus/Views/Content/ContentAreaView.swift").containsAll(
            [
                "case .browser:",
                "BrowserView(panel: browserPanel, isActive: isActive)"
            ], "Browser Panel center-tab routing")
        try SourceContract("Argus/Views/Content/TabBarView.swift").containsAll(
            [
                "Button(\"New Browser Tab\")",
                "if panel.isLoading",
                "else if let agentStatus",
                "else if let icon = panel.displayIcon",
                "values.append(\"Agent status: \\(agentStatus.state.label)\")"
            ], "loading, Agent Status, and default tab icon precedence")
    }

    @Test
    func browserChromeFindAndMenusStayWired() throws {
        let browserView = try SourceContract("Argus/Browser/BrowserView.swift")
        browserView.containsAll(
            [
                ".frame(height: 30)", "Enter website address", "Secure HTTPS connection",
                "HoverStateView { isHovered in",
                "enabled && isHovered",
                ".disabled(!enabled)", ".cursor(enabled ? .pointingHand : .arrow)",
                ".help(help)", ".accessibilityLabel(help)", ".onExitCommand",
                "Previous match", "Next match", "matchCountText"
            ], "compact accessible browser chrome and find overlay")
        browserView.excludes("hoveredControl", "browser chrome hover state must remain control-local")
        browserView.excludes("BrowserControl", "browser controls no longer need shared hover identity")

        try SourceContract("Argus/Views/Content/TabBarView.swift").containsAll(
            [
                "Menu {", "Button(\"New Browser Tab\")", "workspaceManager.addBrowserTab()",
                "if panel.isLoading", "ProgressView()", "else if let icon = panel.displayIcon"
            ], "tab add menu and loading-indicator precedence")
        try SourceContract("Argus/App/ArgusApp.swift").containsAll(
            [
                "Button(\"New Browser Tab\")", "workspaceManager.addBrowserTab()",
                "workspaceManager.requestFindInActiveBrowser()",
                ".keyboardShortcut(\"f\", modifiers: [.command])"
            ], "app menu Browser Panel and find commands")
    }
}
