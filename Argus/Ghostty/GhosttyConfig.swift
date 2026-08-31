// GhosttyConfig.swift
// Argus
//
// Loads and parses Ghostty-compatible configuration files for terminal theming.

import AppKit
import Foundation

// MARK: - NSColor Hex Extension

extension NSColor {
    /// Initialize from a hex string (e.g., "#ff0000", "ff0000", "#fff").
    convenience init?(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexString.hasPrefix("#") {
            hexString.removeFirst()
        }

        // Expand 3-char shorthand (#abc -> #aabbcc)
        if hexString.count == 3 {
            hexString = hexString.map { "\($0)\($0)" }.joined()
        }

        guard hexString.count == 6,
            let value = UInt64(hexString, radix: 16)
        else {
            return nil
        }

        let r = CGFloat(Int((value >> 16) & 0xFF)) / 255.0
        let g = CGFloat(Int((value >> 8) & 0xFF)) / 255.0
        let b = CGFloat(Int(value & 0xFF)) / 255.0

        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    /// Relative luminance per WCAG 2.0.
    var luminance: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        let r = rgb.redComponent
        let g = rgb.greenComponent
        let b = rgb.blueComponent

        func linearize(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }

    /// Returns a darkened version of this color.
    func darkened(by factor: CGFloat = 0.2) -> NSColor {
        guard let rgb = usingColorSpace(.sRGB) else { return self }
        return NSColor(
            srgbRed: max(rgb.redComponent * (1 - factor), 0),
            green: max(rgb.greenComponent * (1 - factor), 0),
            blue: max(rgb.blueComponent * (1 - factor), 0),
            alpha: rgb.alphaComponent
        )
    }

    /// Whether this color is considered "dark" (luminance < 0.5).
    var isDark: Bool { luminance < 0.5 }
}

// MARK: - Color Scheme

enum ColorSchemePreference: String, Hashable {
    case light
    case dark

    /// Detect from the current app appearance.
    @MainActor
    static func fromAppAppearance() -> ColorSchemePreference {
        let appearance = NSApp.effectiveAppearance
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return .dark
        }
        return .light
    }
}

// MARK: - GhosttyConfig

struct GhosttyConfig {
    let fontFamily: String?
    let fontSize: Float?
    let theme: String?
    let workingDirectory: String?
    let background: NSColor?
    let backgroundOpacity: Double?
    let foreground: NSColor?
    let cursorColor: NSColor?
    let cursorText: NSColor?
    let selectionBackground: NSColor?
    let selectionForeground: NSColor?
    let palette: [Int: NSColor]

    // MARK: - Cache

    nonisolated(unsafe) private static var cache: [ColorSchemePreference: GhosttyConfig] = [:]
    private static let cacheQueue = DispatchQueue(label: "dev.argus.ghosttyconfig.cache")

    /// Resolve UI appearance on the main actor before reading configuration.
    @MainActor
    static func load() -> GhosttyConfig {
        load(colorScheme: ColorSchemePreference.fromAppAppearance())
    }

    /// Explicit color schemes can be loaded without accessing AppKit state.
    static func load(colorScheme: ColorSchemePreference) -> GhosttyConfig {
        cacheQueue.sync {
            if let cached = cache[colorScheme] {
                return cached
            }
            let config = loadFromDisk(colorScheme: colorScheme)
            cache[colorScheme] = config
            return config
        }
    }

    /// Invalidate the cache (e.g., after config file changes).
    static func invalidateCache() {
        cacheQueue.sync {
            cache.removeAll()
        }
    }

    // MARK: - Parsing

    /// Standard Ghostty configuration file used for user edits from Argus settings.
    static var standardConfigurationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.mitchellh.ghostty/config")
    }

    /// Standard Ghostty config file paths.
    private static var configPaths: [String] {
        var paths: [String] = []

        // XDG_CONFIG_HOME or default
        if let xdgConfig = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            paths.append("\(xdgConfig)/ghostty/config")
        }

        // Standard macOS/Linux path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        paths.append("\(home)/.config/ghostty/config")

        return paths
    }

    /// Load config from disk, resolving theme files for the given color scheme.
    private static func loadFromDisk(colorScheme: ColorSchemePreference) -> GhosttyConfig {
        var values: [String: String] = [:]

        // Read from each config path (later files override earlier ones)
        for path in configPaths {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                parseConfig(contents, into: &values)
            }
        }

        // Resolve theme if specified
        if let themeName = values["theme"] {
            let resolvedTheme = resolveTheme(themeName, colorScheme: colorScheme)
            if let themeContents = loadThemeFile(resolvedTheme) {
                parseConfig(themeContents, into: &values)
            }
        }

        // Parse palette entries
        var palette: [Int: NSColor] = [:]
        for i in 0...15 {
            if let hex = values["palette = \(i)"] ?? values["palette=\(i)"], let color = NSColor(hex: hex) {
                palette[i] = color
            }
        }

        return GhosttyConfig(
            fontFamily: values["font-family"],
            fontSize: values["font-size"].flatMap { Float($0) },
            theme: values["theme"],
            workingDirectory: values["working-directory"],
            background: values["background"].flatMap { NSColor(hex: $0) },
            backgroundOpacity: values["background-opacity"].flatMap { Double($0) },
            foreground: values["foreground"].flatMap { NSColor(hex: $0) },
            cursorColor: values["cursor-color"].flatMap { NSColor(hex: $0) },
            cursorText: values["cursor-text"].flatMap { NSColor(hex: $0) },
            selectionBackground: values["selection-background"].flatMap { NSColor(hex: $0) },
            selectionForeground: values["selection-foreground"].flatMap { NSColor(hex: $0) },
            palette: palette
        )
    }

    /// Parse key=value config, ignoring comments and blank lines.
    private static func parseConfig(_ contents: String, into values: inout [String: String]) {
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and blank lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
                continue
            }

            // Split on first `=`
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)

            guard !key.isEmpty else { continue }

            // Handle palette entries specially: "palette = 0=#1d1f21" → key "palette=0", value "#1d1f21"
            if key == "palette" {
                // Value format: "N=#hex" or "N=hex"
                if let paletteEq = value.firstIndex(of: "=") {
                    let paletteIdx = value[value.startIndex..<paletteEq]
                        .trimmingCharacters(in: .whitespaces)
                    let paletteVal = value[value.index(after: paletteEq)...]
                        .trimmingCharacters(in: .whitespaces)
                    values["palette=\(paletteIdx)"] = paletteVal
                }
            } else {
                values[key] = value
            }
        }
    }

    /// Resolve theme name with light/dark variants.
    /// If the theme name contains commas: "light_theme,dark_theme" → pick based on scheme.
    /// Otherwise use as-is.
    private static func resolveTheme(_ name: String, colorScheme: ColorSchemePreference) -> String {
        let parts = name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 2 {
            return colorScheme == .light ? parts[0] : parts[1]
        }
        return name
    }

    /// Load a theme file from standard Ghostty theme directories.
    private static func loadThemeFile(_ themeName: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searchPaths = [
            "\(home)/.config/ghostty/themes/\(themeName)",
            "/Applications/Ghostty.app/Contents/Resources/ghostty/themes/\(themeName)"
        ]

        for path in searchPaths {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                return contents
            }
        }
        return nil
    }
}
