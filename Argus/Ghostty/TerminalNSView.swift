// TerminalNSView.swift
// Argus
//
// NSView subclass that hosts the Metal-rendered Ghostty terminal surface.
// This is the key rendering bridge: it sets up a CAMetalLayer, forwards
// keyboard/mouse events to the Ghostty surface, and manages the Metal
// pipeline lifecycle.

import AppKit
import Metal
import QuartzCore

class TerminalNSView: NSView {

    // MARK: - Properties

    weak var surface: TerminalSurface?
    private var trackingArea: NSTrackingArea?
    var currentCursor: NSCursor = .iBeam

    // MARK: - NSView Configuration

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override class var defaultFocusRingType: NSFocusRingType { .none }

    // MARK: - Metal Layer

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = true
        metalLayer.allowsNextDrawableTimeout = false
        return metalLayer
    }

    // MARK: - Initializers

    init(surface: TerminalSurface) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize

        // Configure the Metal layer after initialization
        setupMetalLayer()

        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalNSView does not support NSCoder")
    }

    // MARK: - Metal Setup

    private func setupMetalLayer() {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.framebufferOnly = true
    }
}

extension TerminalNSView {
    // MARK: - View Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window != nil {
            surface?.createSurface()
            updateContentScale()
            synchronizeSurfaceGeometry()
            updateTrackingArea()

            if let surface = surface?.surface,
                let screen = window?.screen,
                let displayId = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? CGDirectDisplayID
            {
                ghostty_surface_set_display_id(surface, displayId)
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentScale()
        synchronizeSurfaceGeometry()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateTrackingArea()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        synchronizeSurfaceGeometry()
    }

    // MARK: - Sizing

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        synchronizeSurfaceGeometry()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        synchronizeSurfaceGeometry()
    }

    private func updateContentScale() {
        guard let ghosttySurface = surface?.surface else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        ghostty_surface_set_content_scale(ghosttySurface, Double(scale), Double(scale))

        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.contentsScale = scale
        }
    }

    // MARK: - Drawing

    override func updateLayer() {
        guard let ghosttySurface = surface?.surface else { return }
        ghostty_surface_draw(ghosttySurface)
        surface?.needsDisplay = false
    }

    // MARK: - Tracking Area (for mouse move events)

    private func updateTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseMoved,
                .mouseEnteredAndExited,
                .activeInKeyWindow,
                .inVisibleRect
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    // MARK: - First Responder

    override func becomeFirstResponder() -> Bool {
        surface?.setFocus(true)
        if let surfaceId = surface?.id {
            NotificationCenter.default.post(
                name: .terminalSurfaceDidBecomeFirstResponder,
                object: surfaceId
            )
        }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        surface?.setFocus(false)
        return super.resignFirstResponder()
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        guard let ghosttySurface = surface?.surface else {
            super.keyDown(with: event)
            return
        }

        // Ghostty's Cmd+V binding can paste only text. Let a running TUI
        // inspect an image-only system clipboard using its Ctrl+V behavior.
        if let fallback = terminalImagePasteFallback(for: event) {
            fallback.withCString { pointer in
                ghostty_surface_text(ghosttySurface, pointer, UInt(fallback.utf8.count))
            }
            return
        }

        var keyInput = ghosttyKeyEvent(
            from: event,
            action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        )

        // Provide printable text only. Control characters (e.g. Ctrl+C/Ctrl+S)
        // must be encoded by Ghostty from keycode+mods; passing AppKit's raw
        // control-character text makes Ghostty emit CSI-u sequences like
        // "3;5u"/"19;5u" that readline and editors may insert literally.
        if let chars = ghosttyText(from: event), !chars.isEmpty,
            let firstByte = chars.utf8.first, firstByte >= 0x20
        {
            chars.withCString { ptr in
                keyInput.text = ptr
                _ = ghostty_surface_key(ghosttySurface, keyInput)
            }
        } else {
            _ = ghostty_surface_key(ghosttySurface, keyInput)
        }

    }

    override func keyUp(with event: NSEvent) {
        guard let ghosttySurface = surface?.surface else {
            super.keyUp(with: event)
            return
        }

        var keyInput = ghosttyKeyEvent(from: event, action: GHOSTTY_ACTION_RELEASE)
        keyInput.text = nil

        _ = ghostty_surface_key(ghosttySurface, keyInput)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let ghosttySurface = surface?.surface else {
            super.flagsChanged(with: event)
            return
        }

        // Determine if this is a press or release based on whether the flag is set
        let isPress = isModifierPress(event: event)

        var keyInput = ghosttyKeyEvent(from: event, action: isPress ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
        keyInput.text = nil

        _ = ghostty_surface_key(ghosttySurface, keyInput)
    }
}

extension TerminalNSView {
    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }

    override func mouseUp(with event: NSEvent) {
        handleMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event)
    }

    override func rightMouseDown(with event: NSEvent) {
        handleMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event)
    }

    override func rightMouseUp(with event: NSEvent) {
        handleMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event)
    }

    override func otherMouseDown(with event: NSEvent) {
        let button = ghosttyMouseButton(from: event.buttonNumber)
        handleMouseButton(GHOSTTY_MOUSE_PRESS, button, event)
    }

    override func otherMouseUp(with event: NSEvent) {
        let button = ghosttyMouseButton(from: event.buttonNumber)
        handleMouseButton(GHOSTTY_MOUSE_RELEASE, button, event)
    }

    override func mouseMoved(with event: NSEvent) {
        handleMousePosition(event)
    }

    override func mouseDragged(with event: NSEvent) {
        handleMousePosition(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        handleMousePosition(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        handleMousePosition(event)
    }

    override func scrollWheel(with event: NSEvent) {
        handleScroll(event)
    }

    override func pressureChange(with event: NSEvent) {
        guard let ghosttySurface = surface?.surface else { return }
        ghostty_surface_mouse_pressure(
            ghosttySurface,
            UInt32(event.stage),
            Double(event.pressure)
        )
    }

    // MARK: - Mouse Helpers

    private func handleMouseButton(
        _ state: ghostty_input_mouse_state_e,
        _ button: ghostty_input_mouse_button_e,
        _ event: NSEvent
    ) {
        guard let ghosttySurface = surface?.surface else { return }
        let mods = ghosttyMods(from: event.modifierFlags)

        // Update position before button state
        handleMousePosition(event)

        let consumed = ghostty_surface_mouse_button(ghosttySurface, state, button, mods)
        if !consumed && state == GHOSTTY_MOUSE_PRESS && button == GHOSTTY_MOUSE_RIGHT {
            // Show context menu if Ghostty didn't consume the right-click
            super.rightMouseDown(with: event)
        }
    }

    private func handleMousePosition(_ event: NSEvent) {
        guard let ghosttySurface = surface?.surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        let mods = ghosttyMods(from: event.modifierFlags)

        // Ghostty expects unflipped coordinates with origin at top-left
        ghostty_surface_mouse_pos(
            ghosttySurface,
            Double(pos.x),
            Double(pos.y),
            mods
        )
    }

    private func handleScroll(_ event: NSEvent) {
        guard let ghosttySurface = surface?.surface else { return }

        var scrollX = event.scrollingDeltaX
        var scrollY = event.scrollingDeltaY

        // For pixel-based scrolling (trackpad), the values are already in pixels.
        // For line-based scrolling (mouse wheel), multiply by a factor.
        if !event.hasPreciseScrollingDeltas {
            scrollX *= 10
            scrollY *= 10
        }

        // Build scroll mods
        var scrollMods: ghostty_input_scroll_mods_t = 0

        // Momentum phase
        if event.momentumPhase == .began {
            scrollMods |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue) << 16
        } else if event.momentumPhase == .changed {
            scrollMods |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue) << 16
        } else if event.momentumPhase == .ended {
            scrollMods |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue) << 16
        } else if event.momentumPhase == .cancelled {
            scrollMods |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue) << 16
        }

        // Precise scrolling flag
        if event.hasPreciseScrollingDeltas {
            scrollMods |= 1  // Precise bit
        }

        ghostty_surface_mouse_scroll(
            ghosttySurface,
            scrollX,
            scrollY,
            scrollMods
        )
    }

}
