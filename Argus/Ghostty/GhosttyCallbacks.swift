// GhosttyCallbacks.swift
// Argus
//
// C callback bridge between Ghostty and Argus terminal runtime state.

import AppKit
import Foundation

struct AudibleBellPolicy {
    static let defaultsKey = "Argus.settings.terminal.audibleBell"

    let defaults: UserDefaults

    func shouldPlay() -> Bool {
        defaults.object(forKey: Self.defaultsKey) == nil || defaults.bool(forKey: Self.defaultsKey)
    }
}

extension Notification.Name {
    static let argusCloseSurface = Notification.Name("argusCloseSurface")
    static let argusSetSurfaceTitle = Notification.Name("argusSetSurfaceTitle")
    static let argusSetSurfacePwd = Notification.Name("argusSetSurfacePwd")
    static let argusSurfaceNeedsDisplay = Notification.Name("argusSurfaceNeedsDisplay")
    static let argusMouseShapeChanged = Notification.Name("argusMouseShapeChanged")
    static let argusColorChanged = Notification.Name("argusColorChanged")
    static let argusCellSizeChanged = Notification.Name("argusCellSizeChanged")
}

// MARK: - C Callbacks

func ghosttyWakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
    DispatchQueue.main.async {
        GhosttyApp.shared.tick()
    }
}

func ghosttyActionCallback(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    let surfaceId = actionSurfaceId(from: target)
    if let handled = handleSurfaceAction(action, surfaceId: surfaceId) {
        return handled
    }
    return handleApplicationAction(action)
}

func ghosttyReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ clipboard: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    guard let userdata, let state else { return false }
    let terminalSurface = Unmanaged<TerminalSurface>.fromOpaque(userdata).takeUnretainedValue()
    guard let ghosttySurface = terminalSurface.surface else { return false }

    let contents = NSPasteboard.general.string(forType: .string) ?? ""
    contents.withCString { pointer in
        ghostty_surface_complete_clipboard_request(ghosttySurface, pointer, state, false)
    }
    return true
}

func ghosttyConfirmReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ content: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    guard let userdata, let state else { return }
    let terminalSurface = Unmanaged<TerminalSurface>.fromOpaque(userdata).takeUnretainedValue()
    guard let ghosttySurface = terminalSurface.surface else { return }
    ghostty_surface_complete_clipboard_request(ghosttySurface, content, state, true)
}

func ghosttyWriteClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ clipboard: ghostty_clipboard_e,
    _ contents: UnsafePointer<ghostty_clipboard_content_s>?,
    _ count: Int,
    _ confirm: Bool
) {
    guard count > 0, let contents else { return }

    var clipboardContents: [(mimeType: String, text: String)] = []
    clipboardContents.reserveCapacity(count)
    for index in 0..<count {
        let item = contents[index]
        guard let mime = item.mime, let data = item.data else { continue }
        clipboardContents.append((String(cString: mime), String(cString: data)))
    }

    writeTerminalClipboard(clipboardContents, to: .general)
}

func ghosttyCloseSurfaceCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ processAlive: Bool
) {
    guard let surfaceId = callbackSurfaceId(from: userdata) else { return }
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .argusCloseSurface,
            object: surfaceId,
            userInfo: ["processAlive": processAlive]
        )
    }
}

// MARK: - Action Routing

private func actionSurfaceId(from target: ghostty_target_s) -> UUID? {
    guard target.tag == GHOSTTY_TARGET_SURFACE,
        let surface = target.target.surface
    else { return nil }
    return callbackSurfaceId(from: ghostty_surface_userdata(surface))
}

private func handleSurfaceAction(
    _ action: ghostty_action_s,
    surfaceId: UUID?
) -> Bool? {
    switch action.tag {
    case GHOSTTY_ACTION_SET_TITLE:
        return handleSetTitle(action.action.set_title, surfaceId: surfaceId)
    case GHOSTTY_ACTION_PWD:
        return handlePwd(action.action.pwd, surfaceId: surfaceId)
    case GHOSTTY_ACTION_RENDER:
        return handleRender(surfaceId: surfaceId)
    case GHOSTTY_ACTION_CELL_SIZE:
        return handleCellSize(action.action.cell_size, surfaceId: surfaceId)
    case GHOSTTY_ACTION_MOUSE_SHAPE:
        return handleMouseShape(action.action.mouse_shape, surfaceId: surfaceId)
    case GHOSTTY_ACTION_COLOR_CHANGE:
        return handleColorChange(action.action.color_change, surfaceId: surfaceId)
    case GHOSTTY_ACTION_CLOSE_TAB:
        return handleCloseTab(surfaceId: surfaceId)
    default:
        return nil
    }
}

private func handleApplicationAction(_ action: ghostty_action_s) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_RING_BELL:
        if AudibleBellPolicy(defaults: .standard).shouldPlay() {
            NSSound.beep()
        }
        return true
    case GHOSTTY_ACTION_RELOAD_CONFIG:
        DispatchQueue.main.async {
            GhosttyApp.shared.reloadConfiguration(source: "ghostty")
        }
        return true
    default:
        return false
    }
}

private func handleSetTitle(
    _ titleAction: ghostty_action_set_title_s,
    surfaceId: UUID?
) -> Bool {
    guard let surfaceId else { return false }
    let title = string(from: titleAction.title)
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .argusSetSurfaceTitle,
            object: nil,
            userInfo: ["surfaceId": surfaceId, "title": title]
        )
    }
    return true
}

private func handlePwd(
    _ pwdAction: ghostty_action_pwd_s,
    surfaceId: UUID?
) -> Bool {
    guard let surfaceId else { return false }
    let pwd = string(from: pwdAction.pwd)
    let publishPwd = {
        NotificationCenter.default.post(
            name: .argusSetSurfacePwd,
            object: nil,
            userInfo: ["surfaceId": surfaceId, "pwd": pwd]
        )
    }
    if Thread.isMainThread {
        publishPwd()
    } else {
        DispatchQueue.main.async(execute: publishPwd)
    }
    return true
}

private func handleRender(surfaceId: UUID?) -> Bool {
    guard let surfaceId else { return false }
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .argusSurfaceNeedsDisplay, object: surfaceId)
    }
    return true
}

private func handleCellSize(
    _ cellSize: ghostty_action_cell_size_s,
    surfaceId: UUID?
) -> Bool {
    guard let surfaceId else { return false }
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .argusCellSizeChanged,
            object: nil,
            userInfo: [
                "surfaceId": surfaceId,
                "width": cellSize.width,
                "height": cellSize.height
            ]
        )
    }
    return true
}

private func handleMouseShape(
    _ shape: ghostty_action_mouse_shape_e,
    surfaceId: UUID?
) -> Bool {
    guard let surfaceId else { return false }
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .argusMouseShapeChanged,
            object: nil,
            userInfo: ["surfaceId": surfaceId, "shape": shape.rawValue]
        )
    }
    return true
}

private func handleColorChange(
    _ colorChange: ghostty_action_color_change_s,
    surfaceId: UUID?
) -> Bool {
    guard let surfaceId else { return false }
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .argusColorChanged,
            object: nil,
            userInfo: [
                "surfaceId": surfaceId,
                "kind": colorChange.kind.rawValue,
                "r": colorChange.r,
                "g": colorChange.g,
                "b": colorChange.b
            ]
        )
    }
    return true
}

private func handleCloseTab(surfaceId: UUID?) -> Bool {
    guard let surfaceId else { return false }
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .argusCloseSurface, object: surfaceId)
    }
    return true
}

// MARK: - Callback Helpers

private func callbackSurfaceId(from userdata: UnsafeMutableRawPointer?) -> UUID? {
    guard let userdata else { return nil }
    let surfaceRef = Unmanaged<AnyObject>.fromOpaque(userdata).takeUnretainedValue()
    return (surfaceRef as? TerminalSurface)?.id
}

private func string(from pointer: UnsafePointer<CChar>?) -> String {
    guard let pointer else { return "" }
    return String(cString: pointer)
}

func writeTerminalClipboard(
    _ contents: [(mimeType: String, text: String)],
    to pasteboard: NSPasteboard
) {
    pasteboard.clearContents()

    for content in contents {
        let mimeType = content.mimeType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let pasteboardType: NSPasteboard.PasteboardType
        switch mimeType {
        case "text/plain":
            pasteboardType = .string
        case "text/html":
            pasteboardType = .html
        default:
            continue
        }

        pasteboard.setString(content.text, forType: pasteboardType)
    }
}
