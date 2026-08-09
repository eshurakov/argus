import Foundation

@MainActor
final class AppSettings: ObservableObject {
    enum RightSidebarView: String, CaseIterable, Identifiable {
        case files
        case changes

        var id: String { rawValue }

        var title: String {
            switch self {
            case .files:
                "Files"
            case .changes:
                "Changes"
            }
        }
    }

    enum InterfaceDensity: String, CaseIterable, Identifiable {
        case compact
        case comfortable

        var id: String { rawValue }

        var title: String { rawValue.capitalized }
    }

    enum DiffStyle: String, CaseIterable, Identifiable {
        case split
        case unified

        var id: String { rawValue }

        var title: String { rawValue.capitalized }
    }

    enum DiffOverflow: String, CaseIterable, Identifiable {
        case scroll
        case wrap

        var id: String { rawValue }

        var title: String { rawValue.capitalized }
    }

    private enum Keys {
        static let restorePreviousSession = "Argus.settings.general.restorePreviousSession"
        static let keepWorkspaceOpenAfterLastTerminalCloses =
            "Argus.settings.general.keepWorkspaceOpenAfterLastTerminalCloses"
        static let defaultRightSidebarView = "Argus.settings.general.defaultRightSidebarView"
        static let defaultStandaloneWorkspaceDirectory = "Argus.settings.general.defaultStandaloneWorkspaceDirectory"
        static let newBranchPrefix = "Argus.settings.general.newBranchPrefix"
        static let interfaceTextSize = "Argus.settings.appearance.interfaceTextSize"
        static let documentTextSize = "Argus.settings.appearance.documentTextSize"
        static let interfaceDensity = "Argus.settings.appearance.interfaceDensity"
        static let audibleBell = "Argus.settings.terminal.audibleBell"
        static let agentCompletionSound = "Argus.settings.agent.completionSound"
        static let showHiddenFiles = "Argus.settings.filesAndChanges.showHiddenFiles"
        static let wrapSourceLines = "Argus.settings.filesAndChanges.wrapSourceLines"
        static let openMarkdownInPreview = "Argus.settings.filesAndChanges.openMarkdownInPreview"
        static let openSVGInPreview = "Argus.settings.filesAndChanges.openSVGInPreview"
        static let defaultDiffStyle = "Argus.settings.filesAndChanges.defaultDiffStyle"
        static let defaultDiffOverflow = "Argus.settings.filesAndChanges.defaultDiffOverflow"
        static let homepage = "Argus.settings.browser.homepage"
        static let searchProvider = "Argus.settings.browser.searchProvider"
        static let defaultZoom = "Argus.settings.browser.defaultZoom"
        static let webInspectorEnabled = "Argus.settings.browser.webInspectorEnabled"
        static let browserDataStore = "Argus.settings.browser.dataStore"
    }

    private let defaults: UserDefaults

    @Published var restorePreviousSession: Bool {
        didSet { persist(restorePreviousSession, for: Keys.restorePreviousSession) }
    }
    @Published var keepWorkspaceOpenAfterLastTerminalCloses: Bool {
        didSet {
            persist(keepWorkspaceOpenAfterLastTerminalCloses, for: Keys.keepWorkspaceOpenAfterLastTerminalCloses)
        }
    }
    @Published var defaultRightSidebarView: RightSidebarView {
        didSet { persist(defaultRightSidebarView.rawValue, for: Keys.defaultRightSidebarView) }
    }
    @Published var defaultStandaloneWorkspaceDirectory: String {
        didSet {
            let normalized = Self.normalizedDirectoryPath(defaultStandaloneWorkspaceDirectory)
            if normalized != defaultStandaloneWorkspaceDirectory {
                defaultStandaloneWorkspaceDirectory = normalized
            } else {
                persist(normalized, for: Keys.defaultStandaloneWorkspaceDirectory)
            }
        }
    }
    @Published var newBranchPrefix: String {
        didSet {
            let normalized = Self.normalizedBranchPrefix(newBranchPrefix)
            if normalized != newBranchPrefix {
                newBranchPrefix = normalized
            } else {
                persist(normalized, for: Keys.newBranchPrefix)
            }
        }
    }
    @Published var interfaceTextSize: Double {
        didSet {
            let normalized = Self.clamp(interfaceTextSize, to: 10...14)
            if normalized != interfaceTextSize {
                interfaceTextSize = normalized
            } else {
                persist(normalized, for: Keys.interfaceTextSize)
            }
        }
    }
    @Published var documentTextSize: Double {
        didSet {
            let normalized = Self.clamp(documentTextSize, to: 10...24)
            if normalized != documentTextSize {
                documentTextSize = normalized
            } else {
                persist(normalized, for: Keys.documentTextSize)
            }
        }
    }
    @Published var interfaceDensity: InterfaceDensity {
        didSet { persist(interfaceDensity.rawValue, for: Keys.interfaceDensity) }
    }
    @Published var audibleBell: Bool { didSet { persist(audibleBell, for: Keys.audibleBell) } }
    @Published var agentCompletionSound: Bool {
        didSet { persist(agentCompletionSound, for: Keys.agentCompletionSound) }
    }
    @Published var showHiddenFiles: Bool { didSet { persist(showHiddenFiles, for: Keys.showHiddenFiles) } }
    @Published var wrapSourceLines: Bool { didSet { persist(wrapSourceLines, for: Keys.wrapSourceLines) } }
    @Published var openMarkdownInPreview: Bool {
        didSet { persist(openMarkdownInPreview, for: Keys.openMarkdownInPreview) }
    }
    @Published var openSVGInPreview: Bool { didSet { persist(openSVGInPreview, for: Keys.openSVGInPreview) } }
    @Published var defaultDiffStyle: DiffStyle {
        didSet { persist(defaultDiffStyle.rawValue, for: Keys.defaultDiffStyle) }
    }
    @Published var defaultDiffOverflow: DiffOverflow {
        didSet { persist(defaultDiffOverflow.rawValue, for: Keys.defaultDiffOverflow) }
    }
    @Published var homepage: String {
        didSet {
            let normalized = Self.normalizedHomepage(homepage)
            if normalized != homepage {
                homepage = normalized
            } else {
                persist(normalized, for: Keys.homepage)
            }
        }
    }
    @Published var searchProvider: BrowserPanelConfiguration.SearchProvider {
        didSet { persist(searchProvider.rawValue, for: Keys.searchProvider) }
    }
    @Published var defaultZoom: Double {
        didSet {
            let normalized = Self.clamp(defaultZoom, to: 0.5...2)
            if normalized != defaultZoom {
                defaultZoom = normalized
            } else {
                persist(normalized, for: Keys.defaultZoom)
            }
        }
    }
    @Published var webInspectorEnabled: Bool {
        didSet { persist(webInspectorEnabled, for: Keys.webInspectorEnabled) }
    }
    @Published var browserDataStore: BrowserPanelConfiguration.DataStore {
        didSet { persist(browserDataStore.rawValue, for: Keys.browserDataStore) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restorePreviousSession = Self.bool(defaults, key: Keys.restorePreviousSession, fallback: true)
        keepWorkspaceOpenAfterLastTerminalCloses = Self.bool(
            defaults,
            key: Keys.keepWorkspaceOpenAfterLastTerminalCloses,
            fallback: false
        )
        defaultRightSidebarView = Self.enumValue(defaults, key: Keys.defaultRightSidebarView, fallback: .changes)
        defaultStandaloneWorkspaceDirectory = Self.normalizedDirectoryPath(
            defaults.string(forKey: Keys.defaultStandaloneWorkspaceDirectory) ?? Self.homeDirectoryPath
        )
        newBranchPrefix = Self.normalizedBranchPrefix(defaults.string(forKey: Keys.newBranchPrefix) ?? "")
        interfaceTextSize = Self.clamp(defaults.double(forKey: Keys.interfaceTextSize), to: 10...14, fallback: 11)
        documentTextSize = Self.clamp(defaults.double(forKey: Keys.documentTextSize), to: 10...24, fallback: 12)
        interfaceDensity = Self.enumValue(defaults, key: Keys.interfaceDensity, fallback: .compact)
        audibleBell = Self.bool(defaults, key: Keys.audibleBell, fallback: true)
        agentCompletionSound = Self.bool(defaults, key: Keys.agentCompletionSound, fallback: true)
        showHiddenFiles = Self.bool(defaults, key: Keys.showHiddenFiles, fallback: true)
        wrapSourceLines = Self.bool(defaults, key: Keys.wrapSourceLines, fallback: true)
        openMarkdownInPreview = Self.bool(defaults, key: Keys.openMarkdownInPreview, fallback: false)
        openSVGInPreview = Self.bool(defaults, key: Keys.openSVGInPreview, fallback: false)
        defaultDiffStyle = Self.enumValue(defaults, key: Keys.defaultDiffStyle, fallback: .split)
        defaultDiffOverflow = Self.enumValue(defaults, key: Keys.defaultDiffOverflow, fallback: .scroll)
        homepage = Self.normalizedHomepage(defaults.string(forKey: Keys.homepage) ?? "")
        searchProvider = Self.enumValue(defaults, key: Keys.searchProvider, fallback: .none)
        defaultZoom = Self.clamp(defaults.double(forKey: Keys.defaultZoom), to: 0.5...2, fallback: 1)
        webInspectorEnabled = Self.bool(defaults, key: Keys.webInspectorEnabled, fallback: false)
        browserDataStore = Self.enumValue(defaults, key: Keys.browserDataStore, fallback: .persistent)
        persistCanonicalValues()
    }

    func resetStandaloneWorkspaceDirectoryToHome() {
        defaultStandaloneWorkspaceDirectory = Self.homeDirectoryPath
    }

    private static var homeDirectoryPath: String {
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    }

    private func persist(_ value: Any, for key: String) {
        defaults.set(value, forKey: key)
    }

    private func persistCanonicalValues() {
        persist(restorePreviousSession, for: Keys.restorePreviousSession)
        persist(
            keepWorkspaceOpenAfterLastTerminalCloses,
            for: Keys.keepWorkspaceOpenAfterLastTerminalCloses
        )
        persist(defaultRightSidebarView.rawValue, for: Keys.defaultRightSidebarView)
        persist(defaultStandaloneWorkspaceDirectory, for: Keys.defaultStandaloneWorkspaceDirectory)
        persist(newBranchPrefix, for: Keys.newBranchPrefix)
        persist(interfaceTextSize, for: Keys.interfaceTextSize)
        persist(documentTextSize, for: Keys.documentTextSize)
        persist(interfaceDensity.rawValue, for: Keys.interfaceDensity)
        persist(audibleBell, for: Keys.audibleBell)
        persist(agentCompletionSound, for: Keys.agentCompletionSound)
        persist(showHiddenFiles, for: Keys.showHiddenFiles)
        persist(wrapSourceLines, for: Keys.wrapSourceLines)
        persist(openMarkdownInPreview, for: Keys.openMarkdownInPreview)
        persist(openSVGInPreview, for: Keys.openSVGInPreview)
        persist(defaultDiffStyle.rawValue, for: Keys.defaultDiffStyle)
        persist(defaultDiffOverflow.rawValue, for: Keys.defaultDiffOverflow)
        persist(homepage, for: Keys.homepage)
        persist(searchProvider.rawValue, for: Keys.searchProvider)
        persist(defaultZoom, for: Keys.defaultZoom)
        persist(webInspectorEnabled, for: Keys.webInspectorEnabled)
        persist(browserDataStore.rawValue, for: Keys.browserDataStore)
    }

    private static func bool(_ defaults: UserDefaults, key: String, fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private static func enumValue<T: RawRepresentable>(
        _ defaults: UserDefaults,
        key: String,
        fallback: T
    ) -> T where T.RawValue == String {
        defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double? = nil) -> Double {
        let value = value == 0 && fallback != nil ? fallback! : value
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func normalizedDirectoryPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return homeDirectoryPath }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    private static func normalizedHomepage(_ homepage: String) -> String {
        homepage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedBranchPrefix(_ prefix: String) -> String {
        prefix.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
    }
}

extension AppSettings {
    struct PresentationMetrics {
        let interfaceTextSize: Double
        let interfaceDensity: InterfaceDensity

        func textSize(forBaseSize baseSize: Double) -> Double {
            baseSize + interfaceTextSize - 11
        }

        var treeRowVerticalPadding: CGFloat {
            interfaceDensity == .compact ? 3 : 5
        }

        var workspaceRowVerticalPadding: CGFloat {
            interfaceDensity == .compact ? 5 : 7
        }

        var projectHeaderVerticalPadding: CGFloat {
            interfaceDensity == .compact ? 2 : 4
        }

        var changeSectionHeaderVerticalPadding: CGFloat {
            interfaceDensity == .compact ? 7 : 9
        }
    }

    var presentationMetrics: PresentationMetrics {
        PresentationMetrics(interfaceTextSize: interfaceTextSize, interfaceDensity: interfaceDensity)
    }
}

extension AppSettings.DiffStyle {
    var argusDiffStyle: ArgusDiffStyle {
        switch self {
        case .split: .split
        case .unified: .unified
        }
    }
}

extension AppSettings.DiffOverflow {
    var argusDiffOverflow: ArgusDiffOverflow {
        switch self {
        case .scroll: .scroll
        case .wrap: .wrap
        }
    }
}
