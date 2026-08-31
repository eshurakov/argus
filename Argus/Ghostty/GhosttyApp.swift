// GhosttyApp.swift
// Argus
//
// Singleton managing the ghostty_app_t lifecycle. Provides the bridge between
// Ghostty's C runtime and Argus's Swift layer. All terminal surfaces share
// this single app instance.

import AppKit
import Combine
import Foundation

// MARK: - GhosttyApp

@MainActor
final class GhosttyApp: ObservableObject {

    static let shared = GhosttyApp()
    private static let terminalThemeResource = "ArgusTerminalTheme"

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private var unfocusedConfig: ghostty_config_t?
    private(set) var defaultBackgroundColor: NSColor = .windowBackgroundColor
    private(set) var defaultForegroundColor: NSColor = .textColor
    private(set) var defaultBackgroundOpacity: Double = 1.0
    @Published private(set) var chromePalette = ChromePalette.fallback
    private var appObservers: [NSObjectProtocol] = []
    private var hasStarted = false

    private init() {
        configureGhosttyEnvironment()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        initializeGhostty()
    }

    isolated deinit {
        for observer in appObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
        if let unfocusedConfig { ghostty_config_free(unfocusedConfig) }
    }

    // MARK: - Environment Setup

    /// Configure environment variables Ghostty expects before initialization.
    private func configureGhosttyEnvironment() {
        // GHOSTTY_RESOURCES_DIR: Point to the framework's resources if needed.
        // Ghostty looks for this to find themes and shaders.
        if let resourcesPath = Bundle.main.resourcePath {
            setenv("GHOSTTY_RESOURCES_DIR", resourcesPath, 0)
        }

        // Terminal identification
        setenv("TERM", "xterm-256color", 0)
        setenv("TERM_PROGRAM", "Argus", 1)
        setenv("COLORTERM", "truecolor", 0)

        // Ensure common tool directories are in PATH
        ensurePathContains([
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin"
        ])
    }

    /// Adds directories to PATH if not already present.
    private func ensurePathContains(_ directories: [String]) {
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let pathComponents = Set(currentPath.split(separator: ":").map(String.init))

        var newComponents: [String] = []
        for dir in directories where !pathComponents.contains(dir) {
            if FileManager.default.fileExists(atPath: dir) {
                newComponents.append(dir)
            }
        }

        if !newComponents.isEmpty {
            let updatedPath = (newComponents + [currentPath]).joined(separator: ":")
            setenv("PATH", updatedPath, 1)
        }
    }

    // MARK: - Initialization

    private func initializeGhostty() {
        // 1. Initialize the Ghostty library
        let argc = CommandLine.argc
        let argv = CommandLine.unsafeArgv
        let result = ghostty_init(UInt(argc), argv)

        // libghostty applies the environment locale process-wide. A non-dot
        // decimal separator breaks C numeric parsing in AppKit on macOS 27,
        // including SF Symbol metrics. Ghostty still retains its UTF-8 LC_CTYPE.
        guard setlocale(LC_NUMERIC, "C") != nil else {
            fatalError("GhosttyApp: failed to restore the C numeric locale after ghostty_init")
        }

        guard result == GHOSTTY_SUCCESS else {
            NSLog("GhosttyApp: ghostty_init failed with code \(result)")
            return
        }

        // 2. Create and load config
        guard let cfg = makeConfiguration() else { return }
        self.config = cfg
        unfocusedConfig = makeUnfocusedConfiguration(from: cfg)

        // 3. Extract terminal colors for window and content chrome.
        extractChromePalette(from: cfg)

        // 4. Create runtime config with callbacks
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = false
        runtimeConfig.wakeup_cb = ghosttyWakeupCallback
        runtimeConfig.action_cb = ghosttyActionCallback
        runtimeConfig.read_clipboard_cb = ghosttyReadClipboardCallback
        runtimeConfig.confirm_read_clipboard_cb = ghosttyConfirmReadClipboardCallback
        runtimeConfig.write_clipboard_cb = ghosttyWriteClipboardCallback
        runtimeConfig.close_surface_cb = ghosttyCloseSurfaceCallback

        // 5. Create the app
        guard let ghosttyApp = ghostty_app_new(&runtimeConfig, cfg) else {
            NSLog("GhosttyApp: ghostty_app_new returned nil")
            return
        }
        self.app = ghosttyApp
        NotificationCenter.default.post(name: .argusGhosttyDidStart, object: nil)

        observeApplicationFocus()
    }

    private func makeConfiguration() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else {
            NSLog("GhosttyApp: ghostty_config_new returned nil")
            return nil
        }

        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        loadTerminalTheme(into: config)
        ghostty_config_finalize(config)
        logDiagnostics(for: config)
        return config
    }

    /// Clone the loaded configuration once; focus changes never reload user
    /// files or replace Terminal Surfaces and their running processes.
    private func makeUnfocusedConfiguration(from focusedConfig: ghostty_config_t) -> ghostty_config_t? {
        guard let config = ghostty_config_clone(focusedConfig) else { return nil }
        loadTerminalTheme(into: config, resource: "ArgusUnfocusedTerminalTheme")
        ghostty_config_finalize(config)
        logDiagnostics(for: config)
        return config
    }

    func configuration(forKeyWindow isKeyWindow: Bool) -> ghostty_config_t? {
        isKeyWindow ? config : unfocusedConfig ?? config
    }

    private func loadTerminalTheme(
        into config: ghostty_config_t,
        resource: String = GhosttyApp.terminalThemeResource
    ) {
        guard
            let themeURL = Bundle.main.url(
                forResource: resource,
                withExtension: "ghostty"
            )
        else {
            NSLog("GhosttyApp: missing Argus terminal theme resource")
            return
        }

        themeURL.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                NSLog("GhosttyApp: invalid Argus terminal theme path")
                return
            }
            ghostty_config_load_file(config, path)
        }
    }

    private func logDiagnostics(for config: ghostty_config_t) {
        let diagnosticCount = ghostty_config_diagnostics_count(config)
        for index in 0..<diagnosticCount {
            let diagnostic = ghostty_config_get_diagnostic(config, index)
            if let message = diagnostic.message {
                NSLog("GhosttyConfig diagnostic: %@", String(cString: message))
            }
        }
    }

    private func observeApplicationFocus() {
        let activateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let app = self?.app else { return }
                ghostty_app_set_focus(app, true)
            }
        }

        let deactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let app = self?.app else { return }
                ghostty_app_set_focus(app, false)
            }
        }

        appObservers.append(contentsOf: [activateObserver, deactivateObserver])
    }

    /// Extract terminal colors from the finalized Ghostty config for shared chrome.
    private func extractChromePalette(from config: ghostty_config_t) {
        let background =
            configColor(named: "background", from: config)
            ?? NSColor.windowBackgroundColor
        let foreground =
            configColor(named: "foreground", from: config)
            ?? (background.isDark ? NSColor.white : NSColor.black)

        defaultBackgroundColor = background
        defaultForegroundColor = foreground

        var opacity: Double = 1.0
        if ghostty_config_get(config, &opacity, "background-opacity", 18) {
            defaultBackgroundOpacity = opacity
        } else {
            defaultBackgroundOpacity = 1.0
        }

        chromePalette = ChromePalette(
            background: background,
            foreground: foreground,
            revision: chromePalette.revision &+ 1
        )
    }

    private func configColor(named name: String, from config: ghostty_config_t) -> NSColor? {
        var color = ghostty_config_color_s(r: 0, g: 0, b: 0)
        guard ghostty_config_get(config, &color, name, UInt(name.utf8.count)) else {
            return nil
        }
        return NSColor(
            srgbRed: CGFloat(color.r) / 255.0,
            green: CGFloat(color.g) / 255.0,
            blue: CGFloat(color.b) / 255.0,
            alpha: 1.0
        )
    }

    // MARK: - Public API

    /// Called by the wakeup callback to process pending Ghostty events.
    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// Reload configuration from disk and apply it.
    func reloadConfiguration(source: String = "user") {
        guard let app else { return }

        NSLog("GhosttyApp: Reloading configuration (source: %@)", source)

        guard let newConfig = makeConfiguration() else { return }
        let newUnfocusedConfig = makeUnfocusedConfiguration(from: newConfig)

        GhosttyConfig.invalidateCache()
        extractChromePalette(from: newConfig)
        ghostty_app_update_config(app, newConfig)

        // Replace our stored config
        if let oldConfig = self.config {
            ghostty_config_free(oldConfig)
        }
        self.config = newConfig
        if let unfocusedConfig { ghostty_config_free(unfocusedConfig) }
        unfocusedConfig = newUnfocusedConfig
        NotificationCenter.default.post(name: .argusGhosttyConfigurationDidChange, object: nil)

        for window in NSApp.windows where window.identifier?.rawValue == "main" {
            window.backgroundColor =
                window.isKeyWindow ? ChromeColors.shellBackgroundNSColor : ChromeColors.unfocusedBackgroundNSColor
            window.contentView?.needsDisplay = true
        }
    }

    /// Create a new surface config with defaults.
    func newSurfaceConfig() -> ghostty_surface_config_s {
        ghostty_surface_config_new()
    }

    /// Update the color scheme on the app level (e.g., when system appearance changes).
    func setColorScheme(_ scheme: ghostty_color_scheme_e) {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, scheme)
    }

    /// Whether any surface needs quit confirmation.
    var needsConfirmQuit: Bool {
        guard let app else { return false }
        return ghostty_app_needs_confirm_quit(app)
    }
}

extension Notification.Name {
    static let argusGhosttyDidStart = Notification.Name("ArgusGhosttyDidStart")
    static let argusGhosttyConfigurationDidChange = Notification.Name("ArgusGhosttyConfigurationDidChange")
}
