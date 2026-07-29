// ChromeColors.swift
// Argus
//
// Shared window-chrome colors. The shell uses a fixed black surface while
// content colors and chrome contrast derive from the active Ghostty theme.

import AppKit
import SwiftUI

/// A compact semantic icon rendered through AppKit rather than SwiftUI's
/// vector-glyph path, which can receive a zero target size during transitions.
@MainActor
struct SemanticIcon: View {
    let name: String
    let pointSize: CGFloat
    let weight: Font.Weight?

    init(name: String, pointSize: CGFloat, weight: Font.Weight? = nil) {
        self.name = name
        self.pointSize = pointSize
        self.weight = weight
    }

    var body: some View {
        let safePointSize = Self.clampedPointSize(pointSize)
        Image(nsImage: Self.resolvedImage(name: name, pointSize: safePointSize, weight: weight))
            .renderingMode(.template)
            .frame(width: safePointSize, height: safePointSize)
    }

    static func clampedPointSize(_ pointSize: CGFloat) -> CGFloat {
        guard pointSize.isFinite, pointSize > 0 else { return 1 }
        return max(pointSize, 1)
    }

    static func resolvedImage(name: String, pointSize: CGFloat, weight: Font.Weight? = nil) -> NSImage {
        SemanticIconImageCache.shared.image(name: name, pointSize: pointSize, weight: weight)
    }
}

@MainActor
private final class SemanticIconImageCache {
    static let shared = SemanticIconImageCache()

    private struct Key: Hashable {
        let name: String
        let pointSize: CGFloat
        let weight: NSFont.Weight
    }

    private let capacity = 256
    private var images: [Key: NSImage] = [:]
    private var insertionOrder: [Key] = []

    func image(name: String, pointSize: CGFloat, weight: Font.Weight?) -> NSImage {
        let safePointSize = SemanticIcon.clampedPointSize(pointSize)
        let symbolWeight = nsFontWeight(for: weight)
        let key = Key(name: name, pointSize: safePointSize, weight: symbolWeight)

        if let image = images[key] {
            return image
        }

        let image = makeImage(name: name, pointSize: safePointSize, weight: symbolWeight)
        images[key] = image
        insertionOrder.append(key)

        if insertionOrder.count > capacity {
            images.removeValue(forKey: insertionOrder.removeFirst())
        }

        return image
    }

    private func makeImage(name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil),
            let image = symbol.withSymbolConfiguration(configuration)?.copy() as? NSImage
        else {
            return fallbackImage(pointSize: pointSize)
        }

        image.isTemplate = true
        ensurePositiveSize(image, pointSize: pointSize)
        return image
    }

    private func fallbackImage(pointSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.isTemplate = true
        ensurePositiveSize(image, pointSize: pointSize)
        return image
    }

    private func ensurePositiveSize(_ image: NSImage, pointSize: CGFloat) {
        guard image.size.width.isFinite, image.size.height.isFinite,
            image.size.width > 0, image.size.height > 0
        else {
            image.size = NSSize(width: pointSize, height: pointSize)
            return
        }
    }

    private func nsFontWeight(for weight: Font.Weight?) -> NSFont.Weight {
        switch weight {
        case .ultraLight?: .ultraLight
        case .thin?: .thin
        case .light?: .light
        default: nonLightNSFontWeight(for: weight)
        }
    }

    private func nonLightNSFontWeight(for weight: Font.Weight?) -> NSFont.Weight {
        switch weight {
        case .regular?: .regular
        case .medium?: .medium
        case .semibold?: .semibold
        case .bold?: .bold
        case .heavy?: .heavy
        case .black?: .black
        default: .regular
        }
    }
}

struct HoverStateView<Content: View>: View {
    let content: (Bool) -> Content

    @State private var isHovered = false

    var body: some View {
        content(isHovered)
            .onHover { isHovered = $0 }
    }
}

struct ChromePalette {
    let background: NSColor
    let foreground: NSColor
    let isDark: Bool
    let revision: UInt

    init(background: NSColor, foreground: NSColor, revision: UInt) {
        self.background = background.usingColorSpace(.sRGB) ?? background
        self.foreground = foreground.usingColorSpace(.sRGB) ?? foreground
        self.isDark = Self.relativeLuminance(of: self.background) < 0.5
        self.revision = revision
    }

    static let fallback = ChromePalette(
        background: .windowBackgroundColor,
        foreground: .textColor,
        revision: 0
    )

    private static func relativeLuminance(of color: NSColor) -> CGFloat {
        guard let color = color.usingColorSpace(.sRGB) else { return 0 }
        return (0.2126 * color.redComponent)
            + (0.7152 * color.greenComponent)
            + (0.0722 * color.blueComponent)
    }
}

enum ChromeColors {
    static var shellBackground: Color {
        Color(nsColor: shellBackgroundNSColor)
    }

    static var contentBackground: Color {
        Color(nsColor: contentBackgroundNSColor)
    }

    static var foreground: Color {
        Color(nsColor: foregroundNSColor)
    }

    static var activeTabFill: Color {
        adaptiveOverlay(darkAlpha: 0.10, lightAlpha: 0.07)
    }

    static var hoveredTabFill: Color {
        adaptiveOverlay(darkAlpha: 0.06, lightAlpha: 0.04)
    }

    static var separator: Color {
        adaptiveOverlay(darkAlpha: 0.12, lightAlpha: 0.10)
    }

    static var contentBackgroundNSColor: NSColor {
        palette.background
    }

    static var shellBackgroundNSColor: NSColor {
        .black
    }

    static var foregroundNSColor: NSColor {
        palette.foreground
    }

    static var colorScheme: ColorScheme {
        palette.isDark ? .dark : .light
    }

    static var backgroundCSS: String {
        cssColor(contentBackgroundNSColor)
    }

    static var foregroundCSS: String {
        cssColor(foregroundNSColor)
    }

    private static func adaptiveOverlay(darkAlpha: CGFloat, lightAlpha: CGFloat) -> Color {
        let color =
            palette.isDark
            ? NSColor.white.withAlphaComponent(darkAlpha)
            : NSColor.black.withAlphaComponent(lightAlpha)
        return Color(nsColor: color)
    }

    private static var palette: ChromePalette {
        GhosttyApp.shared.chromePalette
    }

    private static func cssColor(_ color: NSColor) -> String {
        guard let color = color.usingColorSpace(.sRGB) else { return "rgb(0 0 0)" }
        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        return "rgb(\(red) \(green) \(blue))"
    }
}
