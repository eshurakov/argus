import AppKit

/// Shows a destructive confirmation without using AppKit or SwiftUI destructive
/// button roles. Those roles can trigger a zero-sized CoreUI vector glyph crash
/// on macOS 27 while a menu or sheet is transitioning.
@MainActor
func confirmDestructiveAction(
    title: String,
    message: String,
    confirmTitle: String,
    cancelTitle: String = "Cancel"
) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning

    let confirmButton = alert.addButton(withTitle: confirmTitle)
    confirmButton.contentTintColor = .systemRed
    alert.addButton(withTitle: cancelTitle)

    return alert.runModal() == .alertFirstButtonReturn
}
