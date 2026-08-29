import AppKit
import Observation
import SwiftUI

/// Presentation-only state for the hosting window. SwiftUI's generic active
/// appearance can also describe a non-key window in the active application.
@MainActor
@Observable
final class WindowFocusState {
    private(set) var isKeyWindow = false
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func attach(to window: NSWindow?) {
        guard self.window !== window else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        self.window = window
        refresh()
        guard let window else { return }

        observers = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    private func refresh() {
        isKeyWindow = window?.isKeyWindow ?? false
        window?.backgroundColor =
            isKeyWindow ? ChromeColors.shellBackgroundNSColor : ChromeColors.unfocusedBackgroundNSColor
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

struct WindowFocusReader: NSViewRepresentable {
    let focus: WindowFocusState

    func makeNSView(context: Context) -> FocusTrackingView {
        let view = FocusTrackingView()
        view.focus = focus
        return view
    }

    func updateNSView(_ nsView: FocusTrackingView, context: Context) {}

    static func dismantleNSView(_ nsView: FocusTrackingView, coordinator: Void) {
        nsView.focus?.attach(to: nil)
    }

    final class FocusTrackingView: NSView {
        weak var focus: WindowFocusState?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focus?.attach(to: window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Only changes the backdrop, not foregrounds or authored content colors.
/// Auxiliary surfaces without the main window's focus state keep their normal background.
struct WindowFocusBackground: View {
    let focusedColor: NSColor
    @Environment(WindowFocusState.self) private var focus: WindowFocusState?

    var body: some View {
        Color(nsColor: focus?.isKeyWindow == false ? ChromeColors.unfocusedBackgroundNSColor : focusedColor)
    }
}

/// Apply only to ordinary chrome, never Panel content or Agent Status and
/// Turn Completion Attention indicators. Selection remains visible separately.
private struct WindowFocusChromeModifier: ViewModifier {
    @Environment(WindowFocusState.self) private var focus
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.opacity(focus.isKeyWindow || contrast == .increased ? 1 : 0.65)
    }
}

extension View {
    func windowFocusChrome() -> some View {
        modifier(WindowFocusChromeModifier())
    }
}
