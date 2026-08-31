import AppKit
import Foundation

enum TerminalClipboardConfirmationKind: Sendable {
    case unsafePaste
    case terminalRead
    case terminalWrite

    var title: String {
        switch self {
        case .unsafePaste: "Paste potentially unsafe text?"
        case .terminalRead: "Allow terminal clipboard access?"
        case .terminalWrite: "Allow terminal to change the clipboard?"
        }
    }

    var message: String {
        switch self {
        case .unsafePaste:
            "The clipboard contains text that may execute commands when pasted."
        case .terminalRead:
            "A program in this terminal requested the current system clipboard contents."
        case .terminalWrite:
            "A program in this terminal requested permission to replace the system clipboard contents."
        }
    }
}

struct TerminalClipboardDecision: @unchecked Sendable {
    let surfaceId: UUID
    let complete: @MainActor (Bool) -> Void
}

struct TerminalClipboardRequestState: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
}

struct TerminalClipboardRequestResolution: Equatable, Sendable {
    let content: String
    let confirmed: Bool

    static func resolve(content: String, approved: Bool) -> Self {
        // Ghostty's final Boolean means "skip confirmation", not "approved".
        // Complete denied requests with no clipboard data so request state is
        // released without pasting or exposing the rejected content.
        Self(content: approved ? content : "", confirmed: true)
    }
}

@MainActor
final class TerminalClipboardDecisionStore {
    private var pending: [UUID: TerminalClipboardDecision] = [:]

    func register(surfaceId: UUID, completion: @escaping @MainActor (Bool) -> Void) {
        cancel(surfaceId: surfaceId)
        pending[surfaceId] = TerminalClipboardDecision(surfaceId: surfaceId, complete: completion)
    }

    func resolve(surfaceId: UUID, approved: Bool) {
        pending.removeValue(forKey: surfaceId)?.complete(approved)
    }

    func cancel(surfaceId: UUID) {
        resolve(surfaceId: surfaceId, approved: false)
    }
}

@MainActor
final class TerminalClipboardConfirmationPresenter {
    static let shared = TerminalClipboardConfirmationPresenter()

    private let decisions = TerminalClipboardDecisionStore()
    private var alerts: [UUID: NSAlert] = [:]

    func present(
        kind: TerminalClipboardConfirmationKind,
        surfaceId: UUID,
        preview: String?,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        cancel(surfaceId: surfaceId)
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible),
            window.attachedSheet == nil
        else {
            completion(false)
            return
        }

        decisions.register(surfaceId: surfaceId, completion: completion)
        let alert = makeAlert(kind: kind, preview: preview)
        alerts[surfaceId] = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.alerts.removeValue(forKey: surfaceId)
                self?.decisions.resolve(
                    surfaceId: surfaceId,
                    approved: response == .alertFirstButtonReturn
                )
            }
        }
    }

    func cancel(surfaceId: UUID) {
        if let alert = alerts.removeValue(forKey: surfaceId), let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .abort)
        }
        decisions.cancel(surfaceId: surfaceId)
    }

    private func makeAlert(kind: TerminalClipboardConfirmationKind, preview: String?) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = kind.title
        let boundedPreview = preview.map { String($0.prefix(500)) }
        alert.informativeText = [kind.message, boundedPreview]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert
    }
}
