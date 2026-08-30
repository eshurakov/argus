// SidebarState.swift
// Argus
//
// Observable state for the left workspace sidebar and right git sidebar.
// Tracks visibility and user-adjusted width for each panel.

import SwiftUI

extension SidebarLayout {
    static var centerMinWidth: CGFloat { 320 }
    static var rightMinWidth: CGFloat { 180 }
    static var rightMaxWidth: CGFloat { 600 }
    static var dividerWidth: CGFloat { 1 }

    static func clampWidths(
        leftWidth: CGFloat,
        rightWidth: CGFloat,
        windowWidth: CGFloat,
        leftVisible: Bool,
        rightVisible: Bool
    ) -> (left: CGFloat, right: CGFloat) {
        var left = clampLeftWidth(leftWidth, windowWidth: windowWidth)
        var right = min(max(rightWidth, rightMinWidth), rightMaxWidth)
        let visibleDividerCount = CGFloat((leftVisible ? 1 : 0) + (rightVisible ? 1 : 0))
        let available = max(
            0,
            windowWidth - centerMinWidth - (visibleDividerCount * dividerWidth)
        )

        switch (leftVisible, rightVisible) {
        case (true, true):
            let minimumTotal = leftMinWidth + rightMinWidth
            guard available >= minimumTotal else {
                let scale = minimumTotal > 0 ? available / minimumTotal : 0
                return (leftMinWidth * scale, rightMinWidth * scale)
            }

            let overflow = max(0, left + right - available)
            let leftReducible = left - leftMinWidth
            let rightReducible = right - rightMinWidth
            let totalReducible = leftReducible + rightReducible
            if overflow > 0, totalReducible > 0 {
                let leftReduction = overflow * (leftReducible / totalReducible)
                left -= leftReduction
                right -= overflow - leftReduction
            }
        case (true, false):
            left = min(left, available)
        case (false, true):
            right = min(right, available)
        case (false, false):
            break
        }

        return (left, right)
    }

    static func liveLeftMaxWidth(
        windowWidth: CGFloat,
        rightWidth: CGFloat,
        rightVisible: Bool
    ) -> CGFloat {
        let dividerCount: CGFloat = rightVisible ? 2 : 1
        let available =
            windowWidth
            - centerMinWidth
            - (dividerCount * dividerWidth)
            - (rightVisible ? rightWidth : 0)
        return min(leftMaxWidth(forWindowWidth: windowWidth), max(0, available))
    }

    static func liveRightMaxWidth(
        windowWidth: CGFloat,
        leftWidth: CGFloat,
        leftVisible: Bool
    ) -> CGFloat {
        let dividerCount: CGFloat = leftVisible ? 2 : 1
        let available =
            windowWidth
            - centerMinWidth
            - (dividerCount * dividerWidth)
            - (leftVisible ? leftWidth : 0)
        return min(rightMaxWidth, max(0, available))
    }
}

/// State for the left (workspace) sidebar.
@MainActor
final class SidebarState: ObservableObject {
    private enum Keys {
        static let isVisible = "Argus.sidebar.isVisible"
        static let width = "Argus.sidebar.width"
    }

    private let defaults: UserDefaults
    static let defaultWidth: CGFloat = 200
    static let minWidth: CGFloat = 80
    static let maxPersistedWidth: CGFloat = 600

    /// Whether the sidebar is currently shown.
    @Published var isVisible: Bool {
        didSet { defaults.set(isVisible, forKey: Keys.isVisible) }
    }

    /// Current width in points. Constrained to 80–600 by persisted restore;
    /// live drag constraints may apply a smaller geometry-based max.
    @Published var width: CGFloat {
        didSet { defaults.set(Double(width), forKey: Keys.width) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Keys.isVisible) == nil {
            self.isVisible = true
        } else {
            self.isVisible = defaults.bool(forKey: Keys.isVisible)
        }

        if defaults.object(forKey: Keys.width) == nil {
            self.width = Self.defaultWidth
        } else {
            self.width = Self.clamp(defaults.double(forKey: Keys.width))
        }
    }

    /// Toggle sidebar visibility.
    func toggle() { isVisible.toggle() }

    static func clamp(_ width: Double) -> CGFloat {
        min(max(CGFloat(width), minWidth), maxPersistedWidth)
    }
}

/// State for the right git-status sidebar (Phase 3 placeholder).
@MainActor
final class GitSidebarState: ObservableObject {
    private enum Keys {
        static let isVisible = "Argus.gitSidebar.isVisible"
        static let width = "Argus.gitSidebar.width"
        static let selectedView = "Argus.gitSidebar.selectedView"
        static let defaultSelectedView = "Argus.settings.general.defaultRightSidebarView"
    }

    private let defaults: UserDefaults
    static let defaultWidth: CGFloat = 250
    static let minWidth: CGFloat = 180
    static let maxWidth: CGFloat = 600

    /// Whether the git sidebar is currently shown. Off by default until
    /// Phase 3 is implemented.
    @Published var isVisible: Bool {
        didSet { defaults.set(isVisible, forKey: Keys.isVisible) }
    }

    /// Current width in points. Constrained to 180–600 by persisted restore;
    /// the divider gesture applies the same live range.
    @Published var width: CGFloat {
        didSet { defaults.set(Double(width), forKey: Keys.width) }
    }

    @Published var selectedView: AppSettings.RightSidebarView {
        didSet { defaults.set(selectedView.rawValue, forKey: Keys.selectedView) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Keys.isVisible) == nil {
            self.isVisible = false
        } else {
            self.isVisible = defaults.bool(forKey: Keys.isVisible)
        }

        if defaults.object(forKey: Keys.width) == nil {
            self.width = Self.defaultWidth
        } else {
            self.width = Self.clamp(defaults.double(forKey: Keys.width))
        }

        let selectedRaw =
            defaults.string(forKey: Keys.selectedView)
            ?? defaults.string(forKey: Keys.defaultSelectedView)
        self.selectedView = AppSettings.RightSidebarView(rawValue: selectedRaw ?? "") ?? .changes
    }

    /// Toggle git sidebar visibility.
    func toggle() { isVisible.toggle() }

    static func clamp(_ width: Double) -> CGFloat {
        min(max(CGFloat(width), minWidth), maxWidth)
    }
}
