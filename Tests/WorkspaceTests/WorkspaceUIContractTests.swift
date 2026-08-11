import AppKit
import Testing

@testable import Argus

@Suite
struct WorkspaceUIContractTests {
    @Test
    func singleWindowAndWorkspaceReorderingStayWired() throws {
        let app = try SourceContract("Argus/App/ArgusApp.swift")
        app.contains("Window(\"Argus\", id: \"main\")", "Argus must expose one main window")
        app.excludes("WindowGroup", "v1 must not expose multiple main windows")

        try SourceContract("Argus/Views/MainWindowView.swift").containsAll(
            [
                "GeometryReader",
                "SidebarLayout.liveLeftMaxWidth(",
                "SidebarLayout.liveRightMaxWidth(",
                "SidebarLayout.centerMinWidth",
                "clampSidebarWidths(windowWidth:"
            ], "main window layout")
        try SourceContract("Argus/Views/Sidebar/SidebarState.swift").containsAll(
            [
                "static func clampWidths(",
                "windowWidth - centerMinWidth",
                "case (true, true):",
                "leftMinWidth + rightMinWidth",
                "static func liveLeftMaxWidth(",
                "static func liveRightMaxWidth("
            ], "coupled responsive sidebar bounds")
        try SourceContract("Argus/Views/Content/ContentAreaView.swift").contains(
            "TitlebarView()",
            "content column must mount the custom titlebar"
        )
        try SourceContract("Argus/Views/Content/ContentAreaView.swift").excludes(
            "TitlebarView()\n                .allowsHitTesting(false)",
            "titlebar sidebar controls must accept input"
        )
        try SourceContract("Argus/Views/Content/TabBarView.swift").containsAll(
            [
                "PanelTabDropDelegate", ".onDrag", ".onDrop"
            ], "tab drag and drop")
        try SourceContract("Argus/Models/Workspace.swift").contains(
            "destination <= panelOrder.count",
            "panel reorder must accept the end insertion index"
        )
        try SourceContract("Argus/Views/Sidebar/SidebarView.swift").containsAll(
            [
                "SidebarWorkspaceDropDelegate", ".onDrop"
            ], "workspace drag and drop")
        try SourceContract("Argus/Services/WorkspaceManager.swift").containsAll(
            [
                "func reorderWorkspace(", "in projectId: UUID", "project.moveWorkspace"
            ], "project-scoped workspace reorder")
    }

    @Test
    func responsiveSidebarsPreserveTheCenterColumn() {
        let windowWidth: CGFloat = 800
        let widths = SidebarLayout.clampWidths(
            leftWidth: 300,
            rightWidth: 400,
            windowWidth: windowWidth,
            leftVisible: true,
            rightVisible: true)
        let availableSidebarWidth =
            windowWidth
            - SidebarLayout.centerMinWidth
            - (2 * SidebarLayout.dividerWidth)

        #expect(widths.left + widths.right <= availableSidebarWidth + 0.001)
        #expect(widths.left >= SidebarLayout.leftMinWidth)
        #expect(widths.right >= SidebarLayout.rightMinWidth)

        let constrained = SidebarLayout.clampWidths(
            leftWidth: 200,
            rightWidth: 250,
            windowWidth: 500,
            leftVisible: true,
            rightVisible: true)
        #expect(
            constrained.left + constrained.right
                <= 500 - SidebarLayout.centerMinWidth - (2 * SidebarLayout.dividerWidth) + 0.001)
    }

    @Test
    func newTerminalSelectionUsesTheNormalFocusLifecycle() throws {
        let workspace = try SourceContract("Argus/Models/Workspace.swift")
        let addTerminal = try workspace.section(
            after: "func addTerminalPanel(workingDirectory: String? = nil) -> TerminalPanel",
            before: "func openFilePanel(rootPath: String, relativePath: String)"
        )

        #expect(addTerminal.contains("selectPanel(panel.id)"))
        #expect(addTerminal.contains("panelOrder.append(panel.id)"))
        #expect(!addTerminal.contains("panelOrder.insert"))
        try SourceContract("Argus/Views/Content/ContentAreaView.swift").contains(
            ".id(terminalPanel.surface.id)",
            "terminal content must be keyed by surface id"
        )
    }

    @Test
    func terminalTabActivationReconcilesResolvedGeometry() throws {
        try SourceContract("Argus/Views/Content/ContentAreaView.swift").containsAll(
            [
                "GeometryReader { geometry in",
                "targetSize: geometry.size",
                "ForEach(workspace.panelOrder, id: \\.self)",
                ".opacity(isVisible ? 1 : 0)",
                ".allowsHitTesting(isVisible)",
                ".accessibilityHidden(!isVisible)"
            ], "terminal panes must pass resolved SwiftUI geometry to AppKit")
        try SourceContract("Argus/Ghostty/TerminalView.swift").containsAll(
            [
                "nsView.synchronizeSurfaceGeometry(to: targetSize)",
                "nsView.surface?.refresh()",
                "surface.setOcclusion(!isVisible)"
            ], "terminal visibility must reconcile geometry, redraw, and occlusion")
        try SourceContract("Argus/Ghostty/TerminalSurface.swift").contains(
            "ghostty_surface_set_occlusion(surface, !occluded)",
            "Ghostty visibility must invert the Argus occlusion state"
        )
        try SourceContract("Argus/Ghostty/TerminalNSViewSupport.swift").contains(
            "guard let window else { return }",
            "terminal geometry must wait for an attached window's backing scale"
        )
    }

    @Test
    func newTabUsesCommandT() throws {
        let app = try SourceContract("Argus/App/ArgusApp.swift")
        let newTab = try app.section(
            after: "Button(\"New Tab\")",
            before: "Button(\"Split Vertically\")"
        )

        #expect(newTab.contains("workspaceManager.addTab()"))
        #expect(newTab.contains(".keyboardShortcut(\"t\", modifiers: [.command])"))
        #expect(!newTab.contains(".keyboardShortcut(\"n\", modifiers: [.command])"))
    }

    @Test
    func splitPaneCommandsAndRenderingStayConnected() throws {
        try verifySplitPaneModel()
        try verifySplitPaneCommandsAndRendering()
        try verifySplitPaneFocusLifecycle()
    }

    private func verifySplitPaneModel() throws {
        try SourceContract("Argus/Models/Workspace.swift").containsAll(
            [
                "enum PanelSplitDirection", "case vertical", "case horizontal",
                "indirect enum PanelLayoutNode", "case split(direction:",
                "func splitActiveTerminal(direction: PanelSplitDirection)",
                "func closeTab(_ tabId: UUID)",
                "func closePane(_ panelId: UUID)",
                "guard oldLayout.leaves.count > 1 else",
                "closeTab(tabId)",
                "func closeActivePaneOrTab()",
                "closePane(activePanelId)"
            ], "workspace split-pane model")
        let panelOperations = try SourceContract("Argus/Models/Workspace+Panels.swift")
        let splitBody = try panelOperations.section(
            after: "func splitActiveTerminal(direction: PanelSplitDirection)",
            before: "func removePanel(_ panelId: UUID)"
        )
        #expect(!splitBody.contains("panelOrder.insert"))
        #expect(!splitBody.contains("panelOrder.append"))
    }

    private func verifySplitPaneCommandsAndRendering() throws {
        try SourceContract("Argus/Services/WorkspaceManager.swift").contains(
            "func splitActiveTerminal(direction: PanelSplitDirection)",
            "workspace manager must expose split commands"
        )
        try SourceContract("Argus/Services/WorkspaceManager.swift").containsAll(
            [
                "workspace.closePane(surfaceId)",
                "requestCloseTab(activeTabId, in: workspace.id)",
                "workspace.closeTab(panelId)"
            ], "close commands preserve Pane and Top-level Tab scope")
        try SourceContract("Argus/Services/WorkspaceManager+Navigation.swift").contains(
            "requestClosePane(activePanelId, in: workspace.id)",
            "active Pane closure stays in the navigation owner"
        )
        try SourceContract("Argus/Views/Content/ContentAreaView.swift").containsAll(
            ["PanelSplitLayoutView", "workspace.layout(for: tabId)", "isVisible: isVisible"],
            "content area must render each terminal split tree with active visibility"
        )
        try SourceContract("Argus/Views/Content/TabBarView.swift").contains(
            "isActive: panelId == workspace.activeTabId",
            "tab selection must remain scoped to top-level tabs"
        )
        try SourceContract("Argus/App/ArgusApp.swift").containsAll(
            [
                "Button(\"Split Vertically\")",
                ".keyboardShortcut(\"d\", modifiers: [.command])",
                "Button(\"Split Horizontally\")",
                ".keyboardShortcut(\"d\", modifiers: [.command, .shift])",
                "terminalSurfaceDidBecomeFirstResponder"
            ], "split shortcuts and focus notification")
    }

    private func verifySplitPaneFocusLifecycle() throws {
        try SourceContract("Argus/Ghostty/TerminalNSView.swift").containsAll(
            [
                "NotificationCenter.default.post(",
                "name: .terminalSurfaceDidBecomeFirstResponder"
            ], "terminal focus must notify the workspace manager")

        let terminalView = try SourceContract("Argus/Ghostty/TerminalView.swift")
        let dismantleBody = try terminalView.section(
            after: "static func dismantleNSView",
            before: "func sizeThatFits"
        )
        #expect(dismantleBody.contains("DispatchQueue.main.async"))
        #expect(dismantleBody.contains("nsView.window == nil"))
        #expect(dismantleBody.contains("nsView.surface?.setOcclusion(true)"))
    }
}

@Suite
struct WorkspaceTabAndChromeUIContractTests {
    @Test
    func terminalTabsUseOrdinalTitlesAndSupportRenaming() throws {
        let workspace = try SourceContract("Argus/Models/Workspace.swift")
        workspace.contains("func tabDisplayTitle(for panelId: UUID) -> String", "ordinal title API")
        let formatter = try workspace.section(
            after: "func tabDisplayTitle(for panelId: UUID) -> String",
            before: "\n    ///"
        )
        #expect(formatter.contains(#""Terminal \(index + 1)""#))
        #expect(formatter.contains("terminalCustomTitles[panelId]"))

        let tabBar = try SourceContract("Argus/Views/Content/TabBarView.swift")
        tabBar.containsAll(
            [
                "workspace.tabDisplayTitle(for: panelId)",
                "let title: String",
                "Text(title)",
                ".contextMenu {",
                "Button(\"Close\", action: onClose)",
                "Button(\"Rename\", action: onRename)",
                "workspace.renameTerminalPanel(renamePanelId, title: renameText)",
                "workspaceManager.requestCloseTab(panelId, in: workspace.id)",
                "Button(action: onSelect)",
                ".help(\"Select \\(title)\")",
                ".accessibilityLabel(title)",
                ".accessibilityValue(tabAccessibilityValue)",
                ".accessibilityAddTraits(isActive ? .isSelected : [])",
                "Button(\"Move Left\", action: onMoveLeft)",
                "Button(\"Move Right\", action: onMoveRight)",
                ".accessibilityLabel(\"Close \\(title)\")"
            ], "tab bar must render and rename explicit terminal titles")
        tabBar.excludes(
            "Text(panel.displayTitle)",
            "tab items must not use terminal path or process titles"
        )
    }

    @Test
    func customWindowChromeRemainsAuthoritative() throws {
        let delegate = try SourceContract("Argus/App/AppDelegate.swift")
        delegate.containsAll(
            [
                "window.titleVisibility = .hidden",
                "window.titlebarAppearsTransparent = true",
                "window.styleMask.insert(.fullSizeContentView)",
                "targetWindow?.title =",
                "workspaceManager?.activeWorkspaceTitle"
            ], "custom window chrome")
        delegate.excludes("window.titleVisibility = .visible", "native title must remain hidden")
        try SourceContract("Argus/App/ArgusApp.swift").contains(
            ".windowStyle(.hiddenTitleBar)",
            "scene must use the custom titlebar"
        )

        let titlebar = try SourceContract("Argus/Views/Titlebar/TitlebarView.swift")
        titlebar.containsAll(
            [
                "workspaceManager.selectedWorkspace",
                "workspaceManager.project(for: workspace.id)",
                "project.displayName",
                "workspace.displayTitle",
                "gitContext.visibleText",
                "Text(\"/\")"
            ], "custom titlebar breadcrumb")
        titlebar.excludes(
            "workspace.workspaceType.icon",
            "titlebar breadcrumb must not duplicate Workspace type icon")
        try SourceContract("Argus/Views/MainWindowView.swift").containsAll(
            [
                "@ObservedObject private var ghosttyApp = GhosttyApp.shared",
                ".background(ChromeColors.shellBackground)",
                ".environment(\\.colorScheme, ghosttyApp.chromePalette.isDark ? .dark : .light)"
            ], "black window shell with Ghostty-derived appearance")
    }

    @Test
    func terminalSurfaceCreationRequiresItsRenderingHost() throws {
        let surface = try SourceContract("Argus/Ghostty/TerminalSurface.swift")
        let creation = try surface.section(
            after: "func createSurface()",
            before: "/// Build the environment variables"
        )
        for fragment in [
            "guard let hostedView = _hostedView else { return }",
            "nsview: Unmanaged.passUnretained(hostedView).toOpaque()"
        ] {
            #expect(creation.contains(fragment))
        }
        #expect(!creation.contains("if let view = _hostedView"))
        surface.containsAll(
            [
                "self?.createSurface()",
                "guard let hostedView = _hostedView else { return }"
            ],
            "restored Terminal Surfaces must wait for their retained TerminalNSView"
        )
    }

    @Test
    func titlebarTogglesBothSidebarsAccessibly() throws {
        let titlebar = try SourceContract("Argus/Views/Titlebar/TitlebarView.swift")
        titlebar.containsAll(
            [
                "@EnvironmentObject private var sidebarState: SidebarState",
                "@EnvironmentObject private var gitSidebarState: GitSidebarState",
                "systemImage: \"sidebar.left\"",
                "systemImage: \"sidebar.right\"",
                "HoverStateView { isHovered in",
                "sidebarState.isVisible ? 8 : 72",
                "NotificationCenter.default.post(name: .toggleSidebar, object: nil)",
                "NotificationCenter.default.post(name: .toggleGitSidebar, object: nil)",
                ".frame(width: 24, height: 24)",
                ".contentShape(Rectangle())",
                ".cursor(.pointingHand)",
                ".help(actionName)",
                ".accessibilityLabel(actionName)",
                ".accessibilityValue(isVisible ? \"Visible\" : \"Hidden\")"
            ], "titlebar sidebar toggle controls")
        titlebar.excludes("isLeftSidebarToggleHovered", "left toggle hover state must remain control-local")
        titlebar.excludes("isRightSidebarToggleHovered", "right toggle hover state must remain control-local")
    }

    @Test
    func newTabMenuKeepsHoverStateOutsideTabBarRoot() throws {
        let tabBar = try SourceContract("Argus/Views/Content/TabBarView.swift")
        tabBar.containsAll(
            [
                "HoverStateView { isHovered in",
                "Button(\"New Terminal Tab\")",
                "Button(\"New Browser Tab\")",
                ".fill(isHovered ? ChromeColors.hoveredTabFill : Color.clear)",
                ".frame(width: 20, height: 20)",
                ".help(\"Add tab\")",
                ".accessibilityLabel(\"Add tab\")"
            ], "new Top-level Tab menu hover locality")
        tabBar.excludes("isNewTabHovered", "new-tab hover state must not invalidate complete tab bar")
    }

    @Test
    func freshWorkspaceAndRepositoryActionsUseExplicitLabels() throws {
        try SourceContract("Argus/Models/Workspace.swift").containsAll(
            [
                "init(id: UUID = UUID(), title: String = \"Terminal\"",
                "title: String = \"Terminal\"",
                "return title.isEmpty ? \"Terminal\" : title"
            ], "fresh Workspace labels")
        try SourceContract("Argus/Services/WorkspaceManager.swift").contains(
            "title: title ?? \"Terminal\"",
            "new Workspace uses Terminal label")
        try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift").containsAll(
            [
                "Text(\"Initialize Git Repository\")",
                "Text(\"Refresh Changes\")"
            ], "verb-object Changes labels")
    }

}
