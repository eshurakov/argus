// TerminalSurface.swift
// Argus
//
// ObservableObject wrapping ghostty_surface_t. Manages a single terminal's
// lifecycle including creation, focus, sizing, and teardown.

import AppKit
import Combine
import Foundation

@MainActor
final class TerminalSurface: ObservableObject, Identifiable {

    // MARK: - Identity

    let id: UUID

    // MARK: - Published State

    @Published var title: String = ""
    @Published var pwd: String = ""
    @Published var needsDisplay: Bool = false

    // MARK: - Ghostty Surface

    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?

    // MARK: - Configuration

    private let workspaceId: UUID
    private let workingDirectory: String?
    private let additionalEnvironment: [String: String]
    private var surfaceCreated: Bool = false

    // MARK: - Hosted View (lazily created)

    private var _hostedView: TerminalNSView?

    var hostedView: TerminalNSView {
        if let view = _hostedView { return view }
        let view = TerminalNSView(surface: self)
        _hostedView = view
        return view
    }

    // MARK: - Notification Observers

    nonisolated(unsafe) private var notificationObservers: [NSObjectProtocol] = []

    // MARK: - Initializer

    init(
        workspaceId: UUID,
        workingDirectory: String? = nil,
        additionalEnvironment: [String: String] = [:]
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.workingDirectory = workingDirectory
        self.additionalEnvironment = additionalEnvironment

        observeNotifications()
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        // Surface must be freed if still alive
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    // MARK: - Notification Observation

    private func observeNotifications() {
        // These observers are delivered on the main queue. Assert actor
        // isolation synchronously so metadata is current before a snapshot.
        let surfaceId = self.id

        let titleObserver = NotificationCenter.default.addObserver(
            forName: .argusSetSurfaceTitle,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                let notifId = userInfo["surfaceId"] as? UUID,
                notifId == surfaceId,
                let title = userInfo["title"] as? String
            else { return }
            MainActor.assumeIsolated { self?.title = title }
        }

        let pwdObserver = NotificationCenter.default.addObserver(
            forName: .argusSetSurfacePwd,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                let notifId = userInfo["surfaceId"] as? UUID,
                notifId == surfaceId,
                let pwd = userInfo["pwd"] as? String
            else { return }
            MainActor.assumeIsolated { self?.pwd = pwd }
        }

        let renderObserver = NotificationCenter.default.addObserver(
            forName: .argusSurfaceNeedsDisplay,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let notifId = notification.object as? UUID,
                notifId == surfaceId
            else { return }
            MainActor.assumeIsolated {
                self?.needsDisplay = true
                self?._hostedView?.needsDisplay = true
            }
        }

        notificationObservers.append(
            contentsOf: [
                titleObserver,
                pwdObserver,
                renderObserver,
                observeMouseShapeChanges(),
                observeGhosttyStartup(),
                observeConfigurationChanges()
            ]
        )
    }

    private func observeMouseShapeChanges() -> NSObjectProtocol {
        let surfaceId = id
        return NotificationCenter.default.addObserver(
            forName: .argusMouseShapeChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                let notifId = userInfo["surfaceId"] as? UUID,
                notifId == surfaceId,
                let shapeRaw = userInfo["shape"] as? UInt32
            else { return }
            MainActor.assumeIsolated { self?._hostedView?.updateCursor(shape: .init(rawValue: shapeRaw)) }
        }
    }

    private func observeGhosttyStartup() -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .argusGhosttyDidStart,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The view may have reached a window before deferred libghostty
            // startup completed, so retry the otherwise idempotent creation.
            MainActor.assumeIsolated { self?.createSurface() }
        }
    }

    private func observeConfigurationChanges() -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .argusGhosttyConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateWindowBackground() }
        }
    }

    // MARK: - Surface Lifecycle

    /// Creates the Ghostty surface. Called when the NSView is added to a window.
    func createSurface() {
        guard surface == nil, !surfaceCreated else { return }
        // Restored Terminal Panels are constructed before every Workspace has
        // mounted its retained TerminalNSView. The process-wide startup
        // notification reaches all of them, so defer creation until this
        // surface has an actual rendering host.
        guard let hostedView = _hostedView else { return }
        guard GhosttyApp.shared.app != nil else {
            NSLog("TerminalSurface: Cannot create surface — GhosttyApp not initialized")
            return
        }

        surfaceCreated = true

        // Build the surface config
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS

        // Set the platform NSView
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(hostedView).toOpaque()
            )
        )

        // Set userdata to this surface instance so callbacks can find us
        config.userdata = Unmanaged.passUnretained(self).toOpaque()

        // Scale factor
        let scale = _hostedView?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        config.scale_factor = Double(scale)

        // Working directory
        let dir = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        let dirCString = strdup(dir)
        config.working_directory = UnsafePointer(dirCString)

        // Build environment variables
        let envVars = buildEnvironmentVars()

        // Assign environment variables to config
        let envCount = envVars.count
        if envCount > 0 {
            let envBuffer = UnsafeMutablePointer<ghostty_env_var_s>.allocate(capacity: envCount)
            for (i, envVar) in envVars.enumerated() {
                envBuffer[i] = envVar
            }
            config.env_vars = envBuffer
            config.env_var_count = envCount
        }

        // Font size from Ghostty config
        let ghosttyConfig = GhosttyConfig.load()
        if let fontSize = ghosttyConfig.fontSize {
            config.font_size = fontSize
        }

        // Surface context: tab (no splits in Argus)
        config.context = GHOSTTY_SURFACE_CONTEXT_TAB

        // Create the surface
        surface = ghostty_surface_new(GhosttyApp.shared.app, &config)

        // Clean up C strings (Ghostty copies them internally)
        free(dirCString)
        if let envBuffer = config.env_vars {
            for i in 0..<envCount {
                free(UnsafeMutablePointer(mutating: envBuffer[i].key))
                free(UnsafeMutablePointer(mutating: envBuffer[i].value))
            }
            envBuffer.deallocate()
        }

        if surface == nil {
            NSLog("TerminalSurface: ghostty_surface_new returned nil")
            return
        }

        // Restored tabs create the Ghostty surface after SwiftUI's first layout.
        // Apply the remembered Pane size so the grid is not left at Ghostty's
        // default columns until the next window resize.
        hostedView.synchronizeSurfaceGeometry()
        updateWindowBackground()
    }

    /// Build the environment variables to inject into the shell.
    private func buildEnvironmentVars() -> [ghostty_env_var_s] {
        var env: [String: String] = [:]

        // Argus-specific env vars (spec §Terminal Rendering rule 5)
        let socketPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".argus/argus.sock").path
        env["ARGUS_SOCKET_PATH"] = socketPath
        env["ARGUS_WORKSPACE_ID"] = workspaceId.uuidString
        env["ARGUS_SURFACE_ID"] = id.uuidString

        // Merge additional environment (caller-provided overrides)
        for (key, value) in additionalEnvironment {
            env[key] = value
        }

        // Convert to C structs
        return env.map { key, value in
            ghostty_env_var_s(
                key: strdup(key),
                value: strdup(value)
            )
        }
    }

    // MARK: - Surface Control

    /// Apply the hosting window's background without changing keyboard focus,
    /// terminal contents, or the lifetime of the running process.
    func updateWindowBackground() {
        guard let surface,
            let window = _hostedView?.window,
            let config = GhosttyApp.shared.configuration(forKeyWindow: window.isKeyWindow)
        else { return }
        ghostty_surface_update_config(surface, config)
        refresh()
    }

    /// Set focus state on the surface.
    func setFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    /// Restores both Ghostty focus and AppKit first-responder ownership when visible.
    func requestFocus() {
        setFocus(true)
        guard let view = _hostedView,
            let window = view.window,
            window.firstResponder !== view
        else { return }
        window.makeFirstResponder(view)
    }

    /// Update the surface size (in pixels, at backing scale).
    func setSize(width: UInt32, height: UInt32) {
        guard let surface else { return }
        guard width > 0, height > 0 else { return }
        ghostty_surface_set_size(surface, width, height)
    }

    /// Update the content scale factor (for Retina displays).
    func setContentScale(_ scaleX: Double, _ scaleY: Double) {
        guard let surface else { return }
        ghostty_surface_set_content_scale(surface, scaleX, scaleY)
    }

    /// Set whether the surface is occluded.
    func setOcclusion(_ occluded: Bool) {
        guard let surface else { return }
        // Ghostty's embedded API accepts visibility, not occlusion.
        ghostty_surface_set_occlusion(surface, !occluded)
    }

    /// Trigger a surface redraw.
    func refresh() {
        guard let surface else { return }
        ghostty_surface_refresh(surface)
    }

    /// Test override for Ghostty's process-sensitive close heuristic.
    /// Production code must leave this `nil`.
    var needsConfirmQuitOverride: Bool?
}

extension TerminalSurface {
    /// Tear down and free the Ghostty surface.
    func teardownSurface() {
        TerminalClipboardConfirmationPresenter.shared.cancel(surfaceId: id)
        let surfaceToFree = surface
        self.surface = nil

        guard let surfaceToFree else { return }

        // Workspace closure mutates the SwiftUI hierarchy that still hosts this
        // surface. Freeing it synchronously can re-enter Ghostty and AppKit while
        // that mutation is in progress. Defer the runtime teardown until the next
        // main-actor turn, retaining the Surface and its platform NSView until
        // libghostty has finished with their unretained callback pointers.
        Task { @MainActor [self] in
            ghostty_surface_free(surfaceToFree)
            _ = self
        }
    }

    /// Whether the shell process has exited.
    var processExited: Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    /// Whether the surface needs quit confirmation (running process).
    var needsConfirmQuit: Bool {
        if let needsConfirmQuitOverride {
            return needsConfirmQuitOverride
        }
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    /// Get the current size information.
    var surfaceSize: ghostty_surface_size_s? {
        guard let surface else { return nil }
        return ghostty_surface_size(surface)
    }
}
