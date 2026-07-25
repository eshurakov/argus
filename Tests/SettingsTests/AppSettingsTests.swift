import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct AppSettingsTests {  // swiftlint:disable:this type_body_length
    @Test
    func defaultsMatchSettingsFoundation() async {
        await MainActor.run {
            let defaults = makeDefaults()
            defer { clear(defaults) }

            let settings = AppSettings(defaults: defaults)

            #expect(settings.restorePreviousSession)
            #expect(settings.defaultRightSidebarView == .changes)
            #expect(
                settings.defaultStandaloneWorkspaceDirectory == FileManager.default.homeDirectoryForCurrentUser.path
            )
            #expect(settings.newBranchPrefix.isEmpty)
            #expect(settings.interfaceTextSize == 11)
            #expect(settings.documentTextSize == 12)
            #expect(settings.interfaceDensity == .compact)
            #expect(settings.audibleBell)
            #expect(settings.agentCompletionSound)
            #expect(settings.showHiddenFiles)
            #expect(settings.wrapSourceLines)
            #expect(!settings.openMarkdownInPreview)
            #expect(!settings.openSVGInPreview)
            #expect(settings.defaultDiffStyle == .split)
            #expect(settings.defaultDiffOverflow == .scroll)
            #expect(settings.homepage.isEmpty)
            #expect(settings.searchProvider == .none)
            #expect(settings.defaultZoom == 1)
            #expect(!settings.webInspectorEnabled)
            #expect(settings.browserDataStore == .persistent)
        }
    }

    @Test
    func persistsValuesIncludingFalseBooleans() async {
        await MainActor.run {
            let defaults = makeDefaults()
            defer { clear(defaults) }

            let settings = AppSettings(defaults: defaults)
            settings.restorePreviousSession = false
            settings.audibleBell = false
            settings.agentCompletionSound = false
            settings.showHiddenFiles = false
            settings.wrapSourceLines = false
            settings.openMarkdownInPreview = true
            settings.defaultRightSidebarView = .files
            settings.searchProvider = .duckDuckGo
            settings.browserDataStore = .private
            settings.homepage = " https://argus.local "
            settings.newBranchPrefix = " eshurakov/ "

            let restored = AppSettings(defaults: defaults)
            #expect(!restored.restorePreviousSession)
            #expect(!restored.audibleBell)
            #expect(!restored.agentCompletionSound)
            #expect(!restored.showHiddenFiles)
            #expect(!restored.wrapSourceLines)
            #expect(restored.openMarkdownInPreview)
            #expect(restored.defaultRightSidebarView == .files)
            #expect(restored.searchProvider == .duckDuckGo)
            #expect(restored.browserDataStore == .private)
            #expect(restored.homepage == "https://argus.local")
            #expect(restored.newBranchPrefix == "eshurakov")
        }
    }

    @Test
    func normalizesInvalidEnumsDirectoriesAndBoundedValues() async {
        await MainActor.run {
            let defaults = makeDefaults()
            defer { clear(defaults) }

            defaults.set("unknown", forKey: "Argus.settings.general.defaultRightSidebarView")
            defaults.set("invalid", forKey: "Argus.settings.filesAndChanges.defaultDiffStyle")
            defaults.set("nope", forKey: "Argus.settings.browser.searchProvider")
            defaults.set(3, forKey: "Argus.settings.appearance.interfaceTextSize")
            defaults.set(30, forKey: "Argus.settings.appearance.documentTextSize")
            defaults.set(0.1, forKey: "Argus.settings.browser.defaultZoom")
            defaults.set(
                " ~/Projects/../Workspace ",
                forKey: "Argus.settings.general.defaultStandaloneWorkspaceDirectory"
            )

            let settings = AppSettings(defaults: defaults)
            #expect(settings.defaultRightSidebarView == .changes)
            #expect(settings.defaultDiffStyle == .split)
            #expect(settings.searchProvider == .none)
            #expect(settings.interfaceTextSize == 10)
            #expect(settings.documentTextSize == 24)
            #expect(settings.defaultZoom == 0.5)
            #expect(settings.defaultStandaloneWorkspaceDirectory.hasSuffix("/Workspace"))
            #expect(defaults.string(forKey: "Argus.settings.general.defaultRightSidebarView") == "changes")
            #expect(defaults.string(forKey: "Argus.settings.filesAndChanges.defaultDiffStyle") == "split")
            #expect(defaults.string(forKey: "Argus.settings.browser.searchProvider") == "none")
            #expect(defaults.double(forKey: "Argus.settings.appearance.interfaceTextSize") == 10)
            #expect(defaults.double(forKey: "Argus.settings.appearance.documentTextSize") == 24)
            #expect(defaults.double(forKey: "Argus.settings.browser.defaultZoom") == 0.5)
            #expect(
                defaults.string(forKey: "Argus.settings.general.defaultStandaloneWorkspaceDirectory")?
                    .hasSuffix("/Workspace") == true
            )

            settings.interfaceTextSize = 99
            settings.documentTextSize = 1
            settings.defaultZoom = 9
            #expect(settings.interfaceTextSize == 14)
            #expect(settings.documentTextSize == 10)
            #expect(settings.defaultZoom == 2)
            #expect(defaults.double(forKey: "Argus.settings.appearance.interfaceTextSize") == 14)
            #expect(defaults.double(forKey: "Argus.settings.appearance.documentTextSize") == 10)
            #expect(defaults.double(forKey: "Argus.settings.browser.defaultZoom") == 2)
        }
    }

    @Test
    func presentationMetricsPreserveCompactDefaultsAndMapDiffDefaults() {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let settings = AppSettings(defaults: defaults)

        #expect(settings.presentationMetrics.textSize(forBaseSize: 11) == 11)
        #expect(settings.presentationMetrics.treeRowVerticalPadding == 3)
        #expect(settings.presentationMetrics.workspaceRowVerticalPadding == 5)
        #expect(settings.presentationMetrics.projectHeaderVerticalPadding == 2)
        #expect(settings.presentationMetrics.changeSectionHeaderVerticalPadding == 7)
        #expect(settings.defaultDiffStyle.argusDiffStyle == .split)
        #expect(settings.defaultDiffOverflow.argusDiffOverflow == .scroll)

        settings.interfaceTextSize = 14
        settings.interfaceDensity = .comfortable
        settings.defaultDiffStyle = .unified
        settings.defaultDiffOverflow = .wrap

        #expect(settings.presentationMetrics.textSize(forBaseSize: 11) == 14)
        #expect(settings.presentationMetrics.treeRowVerticalPadding == 5)
        #expect(settings.presentationMetrics.workspaceRowVerticalPadding == 7)
        #expect(settings.presentationMetrics.projectHeaderVerticalPadding == 4)
        #expect(settings.presentationMetrics.changeSectionHeaderVerticalPadding == 9)
        #expect(settings.defaultDiffStyle.argusDiffStyle == .unified)
        #expect(settings.defaultDiffOverflow.argusDiffOverflow == .wrap)
    }

    @Test
    func filePresentationDefaultsApplyOnlyAtContentViewCreation() {
        let source = FilePanelInitialPresentation.resolve(
            fileURL: URL(fileURLWithPath: "/workspace/README.md"),
            wrapSourceLines: false,
            openMarkdownInPreview: false,
            openSVGInPreview: true
        )
        let markdownPreview = FilePanelInitialPresentation.resolve(
            fileURL: URL(fileURLWithPath: "/workspace/README.md"),
            wrapSourceLines: true,
            openMarkdownInPreview: true,
            openSVGInPreview: false
        )
        let svgPreview = FilePanelInitialPresentation.resolve(
            fileURL: URL(fileURLWithPath: "/workspace/logo.svg"),
            wrapSourceLines: true,
            openMarkdownInPreview: false,
            openSVGInPreview: true
        )

        #expect(source.displayMode == .source)
        #expect(!source.lineWrapEnabled)
        #expect(markdownPreview.displayMode == .preview)
        #expect(svgPreview.displayMode == .preview)
    }

    @Test
    func restorePreferenceAndEnvironmentOverridesSkipSessionRestore() async throws {
        try await MainActor.run {
            let defaults = makeDefaults()
            defer { clear(defaults) }
            let snapshotURL = temporarySnapshotURL()
            defer { try? FileManager.default.removeItem(at: snapshotURL) }
            try makeRestorableSnapshot(directory: "/restored").write(to: snapshotURL)

            let enabled = AppSettings(defaults: defaults)
            let restoredManager = WorkspaceManager(
                settings: enabled,
                sessionSnapshotURL: snapshotURL,
                environment: [:]
            )
            #expect(restoredManager.selectedWorkspace?.currentDirectory == "/restored")

            enabled.restorePreviousSession = false
            let disabledManager = WorkspaceManager(
                settings: enabled,
                sessionSnapshotURL: snapshotURL,
                environment: [:]
            )
            #expect(disabledManager.selectedWorkspace?.currentDirectory != "/restored")

            enabled.restorePreviousSession = true
            let overriddenManager = WorkspaceManager(
                settings: enabled,
                sessionSnapshotURL: snapshotURL,
                environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
            )
            #expect(overriddenManager.selectedWorkspace?.currentDirectory != "/restored")
        }
    }

    @Test
    func standaloneWorkspaceDefaultDirectoryOnlyAppliesWithoutExplicitPath() async throws {
        await MainActor.run {
            let defaults = makeDefaults()
            defer { clear(defaults) }
            let settings = AppSettings(defaults: defaults)
            settings.defaultStandaloneWorkspaceDirectory = "/preferred"
            let snapshotURL = temporarySnapshotURL()
            defer { try? FileManager.default.removeItem(at: snapshotURL) }
            let manager = WorkspaceManager(
                settings: settings,
                sessionSnapshotURL: snapshotURL,
                environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
            )

            #expect(manager.selectedWorkspace?.currentDirectory == "/preferred")
            #expect(manager.addWorkspace()?.currentDirectory == "/preferred")
            #expect(manager.addWorkspace(workingDirectory: "/explicit")?.currentDirectory == "/explicit")

            let lastWorkspace = manager.workspaces.last!
            manager.removeWorkspace(lastWorkspace.id)
            manager.removeWorkspace(manager.workspaces[0].id)
            manager.removeWorkspace(manager.workspaces[0].id)
            #expect(manager.selectedWorkspace?.currentDirectory == "/preferred")
        }
    }

    @Test
    func audibleBellPolicyUsesIsolatedDefaults() {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let policy = AudibleBellPolicy(defaults: defaults)

        #expect(policy.shouldPlay())
        defaults.set(false, forKey: AudibleBellPolicy.defaultsKey)
        #expect(!policy.shouldPlay())
        defaults.set(true, forKey: AudibleBellPolicy.defaultsKey)
        #expect(policy.shouldPlay())
    }

    @Test
    func browserConfigurationAppliesOnlyWhenPanelIsCreated() async {
        await MainActor.run {
            let configuration = BrowserPanelConfiguration(
                homepage: "https://argus.local/home",
                searchProvider: .google,
                pageZoom: 1.25,
                developerToolsEnabled: true,
                dataStore: .private
            )
            let homepagePanel = BrowserPanel(configuration: configuration)
            defer { homepagePanel.close() }
            #expect(homepagePanel.currentURL?.absoluteString == "https://argus.local/home")
            #expect(homepagePanel.webView.pageZoom == 1.25)
            #expect(homepagePanel.webView.isInspectable)
            #expect(!homepagePanel.webView.configuration.websiteDataStore.isPersistent)
            #expect(homepagePanel.navigate(to: "swift concurrency"))
            #expect(
                homepagePanel.currentURL?.absoluteString
                    == "https://www.google.com/search?q=swift%20concurrency"
            )

            let explicitURL = URL(string: "https://example.com/explicit")!
            let explicitPanel = BrowserPanel(currentURL: explicitURL, configuration: configuration)
            defer { explicitPanel.close() }
            #expect(explicitPanel.currentURL == explicitURL)

            let blankPanel = BrowserPanel(
                configuration: .init(
                    homepage: "",
                    searchProvider: .bing,
                    pageZoom: 1,
                    developerToolsEnabled: false,
                    dataStore: .persistent
                )
            )
            defer { blankPanel.close() }
            #expect(blankPanel.currentURL == nil)
            #expect(blankPanel.webView.configuration.websiteDataStore.isPersistent)
        }
    }

    @Test
    func browserSearchResolutionPreservesURLsAndEncodesQueries() {
        #expect(
            BrowserPanel.resolvedURL(from: "swift async await", searchProvider: .duckDuckGo)?.absoluteString
                == "https://duckduckgo.com/?q=swift%20async%20await"
        )
        #expect(
            BrowserPanel.resolvedURL(from: "https://example.com/a b", searchProvider: .google)?.scheme == "https"
        )
        #expect(
            BrowserPanel.resolvedURL(from: "example.com/path", searchProvider: .bing)?.absoluteString
                == "https://example.com/path"
        )
        #expect(
            BrowserPanel.resolvedURL(from: "search words", searchProvider: .none)
                == BrowserNavigationPolicy.directURL(from: "search words")
        )
    }

    @MainActor
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "com.argus.tests.settings.\(UUID().uuidString)")!
    }

    private func clear(_ defaults: UserDefaults) {
        defaults.dictionaryRepresentation().keys.forEach { defaults.removeObject(forKey: $0) }
    }

    private func temporarySnapshotURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-settings-\(UUID().uuidString).json")
    }

    private func makeRestorableSnapshot(directory: String) throws -> Data {
        let workspaceId = UUID()
        let catchAll = Project.catchAll()
        let snapshot = ArgusSessionSnapshot(
            selectedWorkspaceId: workspaceId,
            projects: [
                ProjectSnapshot(
                    id: catchAll.id,
                    repositoryPath: "",
                    isCatchAll: true,
                    displayName: "Workspaces",
                    mainBranch: "",
                    workspaceIds: [workspaceId],
                    isExpanded: true,
                    color: nil
                )
            ],
            workspaces: [
                WorkspaceSnapshot(
                    id: workspaceId,
                    projectId: catchAll.id,
                    branchName: nil,
                    workspaceType: .external,
                    worktreePath: nil,
                    title: "Restored",
                    customTitle: nil,
                    currentDirectory: directory,
                    panelCount: 1
                )
            ]
        )
        return try JSONEncoder().encode(snapshot)
    }
}
