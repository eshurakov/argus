// SidebarView.swift
// Argus
//
// Left sidebar showing the two-level project hierarchy (Phase 2).
// Projects appear as collapsible headers; workspaces are children.
// The catch-all project shows standalone workspaces under "Workspaces".

import AppKit
import SwiftUI

// Source membership is explicit in project.pbxproj, which this refactor must not modify.

// MARK: - Command Shortcut Overlay

enum WorkspaceShortcutNumber {
    static func digit(forPosition position: Int, totalCount: Int) -> Int? {
        guard position >= 1, totalCount >= 1, position <= totalCount else { return nil }
        if position <= 8 {
            return position
        }
        if position == totalCount {
            return 9
        }
        return nil
    }
}

private struct CommandKeyHeldKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isCommandKeyHeld: Bool {
        get { self[CommandKeyHeldKey.self] }
        set { self[CommandKeyHeldKey.self] = newValue }
    }
}

/// Transient Command-key tracking for Workspace shortcut overlays.
/// The held state is window-local and clears when Argus or the main window
/// resigns focus so the overlay cannot stick.
@MainActor
final class CommandKeyMonitor: ObservableObject {
    @Published private(set) var isCommandHeld = false

    private let tokens = MonitorTokens()

    init() {
        start()
    }

    func start() {
        guard tokens.eventMonitor == nil else { return }
        refresh()
        tokens.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.refresh(from: event.modifierFlags)
            }
            return event
        }
        let center = NotificationCenter.default
        tokens.observers = [
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.clearHeldState()
                }
            },
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            },
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                let isMainWindow = MainActor.assumeIsolated { window.identifier?.rawValue == "main" }
                guard isMainWindow else { return }
                Task { @MainActor [weak self] in
                    self?.clearHeldState()
                }
            },
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
        ]
    }

    func stop() {
        tokens.invalidate()
        clearHeldState()
    }

    func refresh(
        from flags: NSEvent.ModifierFlags = NSEvent.modifierFlags,
        isApplicationActive: Bool = NSApp.isActive,
        isHostWindowKey: Bool = NSApp.keyWindow?.identifier?.rawValue == "main"
    ) {
        let nextValue = flags.contains(.command) && isApplicationActive && isHostWindowKey
        if isCommandHeld != nextValue {
            isCommandHeld = nextValue
        }
    }

    func clearHeldState() {
        if isCommandHeld {
            isCommandHeld = false
        }
    }

    func setCommandHeldForTesting(_ isHeld: Bool) {
        isCommandHeld = isHeld
    }

    private final class MonitorTokens: @unchecked Sendable {
        var eventMonitor: Any?
        var observers: [NSObjectProtocol] = []

        func invalidate() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }

        deinit {
            invalidate()
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let showNewProjectSheet = Notification.Name("ArgusShowNewProjectSheet")
    static let showNewWorkspaceSheet = Notification.Name("ArgusShowNewWorkspaceSheet")
    static let showRenameProjectSheet = Notification.Name("ArgusShowRenameProjectSheet")
    static let showRenameWorkspaceSheet = Notification.Name("ArgusShowRenameWorkspaceSheet")
    static let showChangeWorkspaceRootSheet = Notification.Name("ArgusShowChangeWorkspaceRootSheet")
    static let showCloseWorkspaceConfirmation = Notification.Name("ArgusShowCloseWorkspaceConfirmation")
    static let showRunningProcessConfirmation = Notification.Name("ArgusShowRunningProcessConfirmation")
    static let confirmApplicationQuit = Notification.Name("ArgusConfirmApplicationQuit")
    static let cancelApplicationQuit = Notification.Name("ArgusCancelApplicationQuit")
}

// MARK: - SidebarView

struct SidebarView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @StateObject var commandKeyMonitor = CommandKeyMonitor()
}
