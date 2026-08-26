import AppKit
import Testing

@testable import Argus

@Suite
struct TerminalFileDropTargetTests {
    /// Every terminal tab stays mounted in the same frame, so the frontmost
    /// view AppKit hands the drag to is often a hidden tab.
    @Test
    @MainActor
    func dropOnHiddenTabResolvesToTheVisibleTab() {
        let visible = TerminalSurface(workspaceId: UUID()).hostedView
        let hidden = TerminalSurface(workspaceId: UUID()).hostedView
        let window = stackedTabsWindow(views: [visible, hidden])
        visible.isInActiveTab = true
        hidden.isInActiveTab = false

        let point = NSPoint(x: 100, y: 100)
        #expect(window.contentView?.hitTest(point) === hidden)
        #expect(hidden.fileDropTarget(atWindowPoint: point) === visible)
        #expect(visible.fileDropTarget(atWindowPoint: point) === visible)
    }

    @Test
    @MainActor
    func dropResolvesToTheVisiblePaneUnderThePointer() {
        let leftPane = TerminalSurface(workspaceId: UUID()).hostedView
        let rightPane = TerminalSurface(workspaceId: UUID()).hostedView
        let hidden = TerminalSurface(workspaceId: UUID()).hostedView
        let window = stackedTabsWindow(views: [leftPane, rightPane, hidden])
        leftPane.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
        rightPane.frame = NSRect(x: 200, y: 0, width: 200, height: 400)
        leftPane.isInActiveTab = true
        rightPane.isInActiveTab = true
        hidden.isInActiveTab = false
        _ = window

        #expect(hidden.fileDropTarget(atWindowPoint: NSPoint(x: 50, y: 100)) === leftPane)
        #expect(hidden.fileDropTarget(atWindowPoint: NSPoint(x: 300, y: 100)) === rightPane)
    }

    /// A browser or file tab renders in front of the mounted terminal tabs.
    /// Nothing visible accepts the paths, so the drop must be refused instead
    /// of typing into a tab the user cannot see.
    @Test
    @MainActor
    func dropIsRefusedWhenNoTerminalTabIsVisible() {
        let hidden = TerminalSurface(workspaceId: UUID()).hostedView
        let alsoHidden = TerminalSurface(workspaceId: UUID()).hostedView
        let window = stackedTabsWindow(views: [hidden, alsoHidden])
        hidden.isInActiveTab = false
        alsoHidden.isInActiveTab = false
        _ = window

        #expect(alsoHidden.fileDropTarget(atWindowPoint: NSPoint(x: 100, y: 100)) == nil)
    }

    /// Mirrors ContentAreaView's ZStack: one frame per tab, later tabs in front.
    @MainActor
    private func stackedTabsWindow(views: [TerminalNSView]) -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let contentView = NSView(frame: frame)
        window.contentView = contentView
        for view in views {
            view.frame = frame
            contentView.addSubview(view)
        }
        return window
    }
}
