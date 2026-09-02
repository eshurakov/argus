import Foundation
import Testing

@testable import Argus

@Suite
struct MacOS27UIContractTests {
    @Test
    func workspaceRowsUseNativeSemanticSymbolsAtAStablePositiveSize() throws {
        let row = try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift")
        row.containsAll(
            [
                "Image(systemName: \"bell.fill\")",
                "Image(systemName: state.symbolName)",
                "Image(systemName: workspace.workspaceType.icon)",
                ".font(.system(size: 11, weight: .semibold))",
                ".frame(width: 20, height: 20)"
            ], "native Workspace row status and type icons")
        row.excludes("workspaceTypeMarker", "Workspace rows use semantic type symbols")
    }

    @Test
    func settingsWindowAvoidsSwiftUITabAndSettingsSceneTransitions() throws {
        let settings = try SourceContract("Argus/Settings/SettingsView.swift")
        settings.containsAll(
            [
                "enum SettingsSection: CaseIterable",
                "final class SettingsNavigationModel: ObservableObject",
                "switch navigation.section",
                "case .browser: browser"
            ],
            "Settings renders the section selected by AppKit navigation"
        )
        settings.excludes("TabView", "Settings avoids the crashing SwiftUI tab transition")
        settings.excludes("tabItem", "Settings navigation belongs to the AppKit toolbar")

        let app = try SourceContract("Argus/App/ArgusApp.swift")
        app.containsAll(
            [
                "CommandGroup(replacing: .appSettings)",
                "appDelegate.showSettings()"
            ],
            "Settings menu opens the AppKit-hosted Settings window"
        )
        app.excludes("Settings {", "macOS 27 Settings avoids the crashing SwiftUI Settings scene")

        let delegate = try SourceContract("Argus/App/AppDelegate.swift")
        delegate.containsAll(
            [
                "private var settingsWindowController: SettingsWindowController?",
                "func showSettings()",
                "let controller = SettingsWindowController("
            ],
            "AppDelegate owns and reuses the Settings window controller"
        )

        let controller = try SourceContract("Argus/Settings/SettingsWindowController.swift")
        controller.containsAll(
            [
                "final class SettingsWindowController: NSWindowController, NSToolbarDelegate",
                "toolbar.displayMode = .iconAndLabel",
                "toolbarSelectableItemIdentifiers",
                "private let navigation = SettingsNavigationModel()",
                "navigation.section = section",
                "systemSymbolName: section.systemImageName",
                "accessibilityDescription: section.title",
                "item.action = #selector(selectToolbarItem(_:))"
            ],
            "AppKit owns navigation while one retained SwiftUI graph renders Settings content"
        )
    }

    @Test
    func settingsToolbarUsesSemanticSymbols() throws {
        let settings = try SourceContract("Argus/Settings/SettingsView.swift")
        settings.containsAll(
            [
                "var systemImageName: String",
                "case .general: \"gear\"",
                "case .appearance: \"textformat\"",
                "case .terminal: \"terminal\"",
                "case .filesAndChanges: \"doc.text\"",
                "case .browser: \"globe\"",
                "case .agent: \"bell\""
            ],
            "Settings sections provide semantic toolbar symbols"
        )
    }

    @Test
    func ghosttyStartupRestoresTheCNumericLocaleBeforeRenderingSymbols() throws {
        let ghostty = try SourceContract("Argus/Ghostty/GhosttyApp.swift")
        let startup = try ghostty.section(
            after: "let result = ghostty_init(UInt(argc), argv)",
            before: "guard result == GHOSTTY_SUCCESS"
        )
        #expect(startup.contains("setlocale(LC_NUMERIC, \"C\")"))
        #expect(startup.contains("fatalError("))

        let files = try SourceContract(
            "Argus/Views/GitSidebar/RightSidebarView+WorkspaceFileLabels.swift"
        )
        files.containsAll(
            [
                "Image(systemName: isExpanded ? \"folder.fill\" : \"folder\")",
                "Image(systemName: WorkspaceFileIcon.systemName(for: file.name))"
            ], "Files View uses native SF Symbol rendering")

        let chrome = try SourceContract("Argus/Views/ChromeColors.swift")
        chrome.excludes(
            "SemanticIcon",
            "symbol rendering no longer uses a workaround abstraction"
        )

        let delegate = try SourceContract("Argus/App/AppDelegate.swift")
        delegate.excludes(
            "prepareWorkspaceFileSymbolsForGhosttyInitialization",
            "application startup no longer prewarms SF Symbols"
        )
    }

    @Test
    func destructiveActionsAvoidSwiftUISymbolRendering() throws {
        let filesActions = try SourceContract(
            "Argus/Views/GitSidebar/RightSidebarView+WorkspaceFilesActions.swift"
        )
        filesActions.excludes(
            "role: .destructive",
            "Workspace Item context-menu actions use an in-view confirmation"
        )
        let orphanSheet = try SourceContract("Argus/Views/Dialogs/OrphanedWorktreesSheet.swift")
        orphanSheet.containsAll(
            [
                "@State private var pendingDeletion: OrphanedWorktreeInfo?",
                "if let pendingDeletion {",
                "deletionConfirmation(for: pendingDeletion)",
                "Button(\"Delete Worktree\")",
                ".foregroundStyle(.red)"
            ], "in-sheet Orphaned Worktree deletion confirmation")
        for fragment in ["role: .destructive", "NSAlert" + "()", "runModal()", "hasDestructiveAction"] {
            orphanSheet.excludes(
                fragment,
                "Orphaned Worktree actions avoid vector-glyph-generating destructive confirmation APIs"
            )
        }

        let sharedConfirmation = try SourceContract("Argus/Views/DestructiveConfirmation.swift")
        sharedConfirmation.containsAll(
            [
                "func confirmDestructiveAction(",
                "confirmButton.contentTintColor = .systemRed",
                "return alert.runModal() == .alertFirstButtonReturn"
            ], "shared destructive confirmation avoids destructive roles")

        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = testsDirectory.deletingLastPathComponent().appendingPathComponent("Argus")
        let sourceURLs =
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            #expect(!source.contains("role: .destructive"), "\(sourceURL.path) uses a SwiftUI destructive role")
            #expect(
                !source.contains("has" + "DestructiveAction"),
                "\(sourceURL.path) uses AppKit destructive-role rendering"
            )
        }
    }
}
