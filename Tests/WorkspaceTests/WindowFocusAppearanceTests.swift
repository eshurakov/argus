import AppKit
import GhosttyKit
import SwiftUI
import Testing

@testable import Argus

@Suite
@MainActor
struct WindowFocusAppearanceTests {
    @Test
    func focusTracksOnlyItsHostingWindowAndDetachesCleanly() {
        let window = FocusTestWindow()
        let settingsWindow = FocusTestWindow()
        let focus = WindowFocusState()
        let notifications = NotificationCenter.default
        let originalResponder = window.firstResponder

        window.simulatedIsKeyWindow = true
        focus.attach(to: window)
        #expect(focus.isKeyWindow)
        #expect(window.backgroundColor == ChromeColors.shellBackgroundNSColor)

        window.simulatedIsKeyWindow = false
        notifications.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!focus.isKeyWindow)
        #expect(window.backgroundColor == ChromeColors.unfocusedBackgroundNSColor)

        settingsWindow.simulatedIsKeyWindow = true
        notifications.post(name: NSWindow.didBecomeKeyNotification, object: settingsWindow)
        #expect(!focus.isKeyWindow)

        window.simulatedIsKeyWindow = true
        notifications.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(focus.isKeyWindow)
        #expect(window.firstResponder === originalResponder)

        focus.attach(to: settingsWindow)
        window.simulatedIsKeyWindow = false
        notifications.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(focus.isKeyWindow)

        focus.attach(to: nil)
        #expect(!focus.isKeyWindow)
        notifications.post(name: NSWindow.didBecomeKeyNotification, object: settingsWindow)
        #expect(!focus.isKeyWindow)
    }

    @Test
    func unfocusedBackgroundChangesWithoutWashingOutForegroundContent() throws {
        let content = ZStack {
            ChromeColors.shellBackground
            Color.white.frame(width: 20, height: 20)
        }
        let focused = try bitmap(content, isKeyWindow: true)
        let unfocused = try bitmap(content, isKeyWindow: false)
        let focusedBackground = try #require(focused.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
        let unfocusedBackground = try #require(unfocused.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
        #expect(focusedBackground.redComponent == 0)
        let expectedGrey = try bitmap(Color(nsColor: ChromeColors.unfocusedBackgroundNSColor), isKeyWindow: true)
        #expect(unfocused.colorAt(x: 10, y: 10) == expectedGrey.colorAt(x: 10, y: 10))
        #expect(ChromeColors.unfocusedBackgroundNSColor.redComponent == 26.0 / 255)
        #expect(unfocusedBackground.redComponent == unfocusedBackground.greenComponent)
        #expect(unfocusedBackground.greenComponent == unfocusedBackground.blueComponent)
        #expect(unfocusedBackground.alphaComponent == 1)
        #expect(focused.colorAt(x: 60, y: 50) == unfocused.colorAt(x: 60, y: 50))

        let document = try bitmap(ChromeColors.contentBackground, isKeyWindow: false)
        #expect(document.colorAt(x: 10, y: 10) == unfocused.colorAt(x: 10, y: 10))
    }

    @Test
    func terminalConfigurationsChangeOnlyTheOwnedBackground() throws {
        let focused = try #require(GhosttyApp.shared.configuration(forKeyWindow: true))
        let unfocused = try #require(GhosttyApp.shared.configuration(forKeyWindow: false))
        #expect(focused != unfocused)

        for (config, expectedBackground) in [(focused, UInt8(0)), (unfocused, UInt8(26))] {
            var background = ghostty_config_color_s()
            #expect(ghostty_config_get(config, &background, "background", 10))
            #expect(background.r == expectedBackground)
            #expect(background.g == expectedBackground)
            #expect(background.b == expectedBackground)
            var opacity = 0.0
            #expect(ghostty_config_get(config, &opacity, "background-opacity", 18))
            #expect(opacity == 1)
        }

        var focusedForeground = ghostty_config_color_s()
        var unfocusedForeground = ghostty_config_color_s()
        #expect(ghostty_config_get(focused, &focusedForeground, "foreground", 10))
        #expect(ghostty_config_get(unfocused, &unfocusedForeground, "foreground", 10))
        #expect(focusedForeground.r == unfocusedForeground.r)
        #expect(focusedForeground.g == unfocusedForeground.g)
        #expect(focusedForeground.b == unfocusedForeground.b)
        var focusedFontSize: Float = 0
        var unfocusedFontSize: Float = 0
        #expect(ghostty_config_get(focused, &focusedFontSize, "font-size", 9))
        #expect(ghostty_config_get(unfocused, &unfocusedFontSize, "font-size", 9))
        #expect(focusedFontSize == unfocusedFontSize)
    }

    @Test
    func terminalBackgroundWiringPreservesInputFocusAndAppliesAfterReload() throws {
        try SourceContract("Argus/Ghostty/TerminalNSView.swift").contains(
            "observeWindowFocus()", "Terminal views observe their current hosting window")
        try SourceContract("Argus/Ghostty/TerminalNSViewSupport.swift").containsAll(
            [
                "NSWindow.didBecomeKeyNotification", "NSWindow.didResignKeyNotification",
                "name: name, object: window", "surface?.updateWindowBackground()"
            ], "all Terminal Panes follow their hosting window, not the Focused Pane")
        let surface = try SourceContract("Argus/Ghostty/TerminalSurface.swift")
        let update = try surface.section(after: "func updateWindowBackground()", before: "/// Set focus state")
        #expect(update.contains("configuration(forKeyWindow: window.isKeyWindow)"))
        #expect(update.contains("ghostty_surface_update_config(surface, config)"))
        #expect(!update.contains("setFocus"))
        #expect(!update.contains("makeFirstResponder"))
        #expect(!update.contains("createSurface"))
        #expect(!update.contains("ghostty_surface_text"))
        surface.contains(".argusGhosttyConfigurationDidChange", "reload reapplies the window background")
    }

    @Test
    func ordinaryChromeSoftensWhenNotKey() throws {
        let focused = try bitmap(Color.white.windowFocusChrome(), isKeyWindow: true)
        let unfocused = try bitmap(Color.white.windowFocusChrome(), isKeyWindow: false)

        #expect(alpha(focused, x: 60, y: 50) == 1)
        #expect(alpha(unfocused, x: 60, y: 50) > 0.5)
        #expect(alpha(unfocused, x: 60, y: 50) < 1)
    }

    @Test
    func focusTreatmentStaysOutOfPanelContentAndAgentIndicators() throws {
        let window = try SourceContract("Argus/Views/MainWindowView.swift")
        window.excludes("WindowFocusOutline", "focus must not add a perimeter outline")
        window.excludes("WindowFocusStrip", "the background change replaces the titlebar focus strip")
        window.containsAll(
            ["WindowFocusReader(focus: windowFocus)", ".allowsHitTesting(false)", ".accessibilityHidden(true)"],
            "the window focus reader must not intercept input or accessibility")
        window.excludes(".windowFocusChrome()", "the entire window must never be dimmed")
        try SourceContract("Argus/Views/Content/ContentAreaView.swift").excludes(
            ".windowFocusChrome()", "Panel content must remain undimmed")

        let appearance = try SourceContract("Argus/Views/WindowFocusAppearance.swift")
        appearance.containsAll(
            [
                "@Environment(\\.colorSchemeContrast)",
                "focus.isKeyWindow || contrast == .increased ? 1 : 0.65"
            ], "Increased Contrast preserves chrome readability")

        let tabBar = try SourceContract("Argus/Views/Content/TabBarView.swift")
        let tabIndicators = try tabBar.section(after: "if panel.isLoading {", before: "} else if let icon")
        #expect(!tabIndicators.contains(".windowFocusChrome()"))
        let row = try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift")
        let workspaceIndicators = try row.section(after: "case .attention:", before: "case .workspaceType:")
        #expect(!workspaceIndicators.contains(".windowFocusChrome()"))
        let pullRequests = try SourceContract("Argus/Views/Sidebar/PullRequestStatusView.swift")
        let pullRequestIcon = try pullRequests.section(
            after: "struct PullRequestStatusIcon", before: "struct PullRequestStatusSummary")
        #expect(!pullRequestIcon.contains(".windowFocusChrome()"))
    }

    private func bitmap(_ content: some View, isKeyWindow: Bool) throws -> NSBitmapImageRep {
        let window = FocusTestWindow()
        window.simulatedIsKeyWindow = isKeyWindow
        let focus = WindowFocusState()
        focus.attach(to: window)
        defer { focus.attach(to: nil) }
        let renderer = ImageRenderer(
            content:
                content
                .environment(focus)
                .frame(width: 120, height: 100)
        )
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }

    private func alpha(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
        bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }
}

/// Exercise the app-owned notification boundary without activating windows or
/// changing keyboard focus on the machine running the tests.
@MainActor
private final class FocusTestWindow: NSWindow {
    var simulatedIsKeyWindow = false
    override var isKeyWindow: Bool { simulatedIsKeyWindow }
}
