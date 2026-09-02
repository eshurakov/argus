import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct AppSettingsTests {
    @Test
    func defaultsMatchSettingsFoundation() async {
        await MainActor.run {
            let defaults = makeDefaults()
            defer { clear(defaults) }

            let settings = AppSettings(defaults: defaults)

            #expect(settings.restorePreviousSession)
            #expect(!settings.keepWorkspaceOpenAfterLastTerminalCloses)
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
            #expect(!settings.combineWorkingChangeSections)
            #expect(!settings.showBaseBranchChanges)
            #expect(settings.showPullRequestStatus)
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
            settings.keepWorkspaceOpenAfterLastTerminalCloses = true
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
            #expect(restored.keepWorkspaceOpenAfterLastTerminalCloses)
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

            restored.keepWorkspaceOpenAfterLastTerminalCloses = false
            let restoredAgain = AppSettings(defaults: defaults)
            #expect(!restoredAgain.keepWorkspaceOpenAfterLastTerminalCloses)
            #expect(
                defaults.bool(
                    forKey: "Argus.settings.general.keepWorkspaceOpenAfterLastTerminalCloses"
                ) == false
            )
        }
    }

    @Test
    func generalSettingsKeepRelatedCopyInSingleRows() throws {
        let settings = try SourceContract("Argus/Settings/SettingsView.swift")
        settings.containsAll(
            [
                "Section(\"Workspace\")",
                "Toggle(\"Restore previous session\", isOn: $settings.restorePreviousSession)",
                "Toggle(\n                    \"Keep Empty Workspaces open\"",
                "$settings.keepWorkspaceOpenAfterLastTerminalCloses",
                ".help(\"Closing the last Terminal Tab leaves the Workspace available with no tabs.\")",
                "LabeledContent {\n                    TextField(\"\", text: $settings.newBranchPrefix",
                "Text(\"Used for generated branch names.\")",
                ".foregroundStyle(.secondary)\n                            .lineLimit(1)"
            ],
            "general settings keep related copy in single rows"
        )
        settings.excludes("Section(\"Workspace Lifecycle\")", "workspace lifecycle is not a separate section")
        settings.excludes(
            "Leaves the Workspace open with no tabs. New Workspaces still start with a Terminal Tab.",
            "workspace lifecycle copy is not a detached row"
        )
    }

    @Test
    func combineWorkingChangeSectionsRoundTripsIndependently() async {
        await MainActor.run {
            let defaults = makeDefaults()
            defer { clear(defaults) }

            let settings = AppSettings(defaults: defaults)
            #expect(!settings.combineWorkingChangeSections)
            #expect(!settings.showBaseBranchChanges)

            settings.combineWorkingChangeSections = true
            let restored = AppSettings(defaults: defaults)
            #expect(restored.combineWorkingChangeSections)
            #expect(!restored.showBaseBranchChanges)
            #expect(
                defaults.bool(forKey: "Argus.settings.filesAndChanges.combineWorkingChangeSections")
            )

            restored.combineWorkingChangeSections = false
            let roundTripped = AppSettings(defaults: defaults)
            #expect(!roundTripped.combineWorkingChangeSections)
            #expect(!roundTripped.showBaseBranchChanges)
        }
    }

    @Test
    func showBaseBranchChangesRoundTripsIndependently() async {
        await MainActor.run {
            let defaults = makeDefaults()
            defer { clear(defaults) }

            let settings = AppSettings(defaults: defaults)
            #expect(!settings.combineWorkingChangeSections)
            #expect(!settings.showBaseBranchChanges)

            settings.showBaseBranchChanges = true
            let restored = AppSettings(defaults: defaults)
            #expect(!restored.combineWorkingChangeSections)
            #expect(restored.showBaseBranchChanges)
            #expect(defaults.bool(forKey: "Argus.settings.filesAndChanges.showBaseBranchChanges"))

            restored.showBaseBranchChanges = false
            let roundTripped = AppSettings(defaults: defaults)
            #expect(!roundTripped.combineWorkingChangeSections)
            #expect(!roundTripped.showBaseBranchChanges)
        }
    }

    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func pullRequestStatusRoundTripsIndependentlyOfLocalChanges(combineWorkingChanges: Bool, showAgainstBase: Bool) {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let settings = AppSettings(defaults: defaults)
        settings.combineWorkingChangeSections = combineWorkingChanges
        settings.showBaseBranchChanges = showAgainstBase
        #expect(settings.showPullRequestStatus)

        settings.showPullRequestStatus = false
        let disabled = AppSettings(defaults: defaults)
        #expect(!disabled.showPullRequestStatus)
        #expect(disabled.combineWorkingChangeSections == combineWorkingChanges)
        #expect(disabled.showBaseBranchChanges == showAgainstBase)
        #expect(!defaults.bool(forKey: "Argus.settings.filesAndChanges.showPullRequestStatus"))

        disabled.combineWorkingChangeSections.toggle()
        disabled.showBaseBranchChanges.toggle()
        #expect(!AppSettings(defaults: defaults).showPullRequestStatus)
        disabled.showPullRequestStatus = true
        let enabled = AppSettings(defaults: defaults)
        #expect(enabled.showPullRequestStatus)
        #expect(enabled.combineWorkingChangeSections == !combineWorkingChanges)
        #expect(enabled.showBaseBranchChanges == !showAgainstBase)
        #expect(defaults.bool(forKey: "Argus.settings.filesAndChanges.showPullRequestStatus"))
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

        settings.interfaceTextSize = 14
        settings.interfaceDensity = .comfortable
        settings.defaultDiffStyle = .unified

        #expect(settings.presentationMetrics.textSize(forBaseSize: 11) == 14)
        #expect(settings.presentationMetrics.treeRowVerticalPadding == 5)
        #expect(settings.presentationMetrics.workspaceRowVerticalPadding == 7)
        #expect(settings.presentationMetrics.projectHeaderVerticalPadding == 4)
        #expect(settings.presentationMetrics.changeSectionHeaderVerticalPadding == 9)
        #expect(settings.defaultDiffStyle.argusDiffStyle == .unified)
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

}
