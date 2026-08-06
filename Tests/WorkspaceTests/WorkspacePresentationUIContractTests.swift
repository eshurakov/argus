import AppKit
import Foundation
import Testing

@testable import Argus

@Suite
struct WorkspacePresentationUIContractTests {
    @Test
    func workspaceRowsUseNativeSemanticSymbolsAtAStablePositiveSize() throws {
        let row = try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift")
        row.containsAll(
            [
                "Image(systemName: \"bell.fill\")",
                "Image(systemName: agentStatus.state.symbolName)",
                "Image(systemName: workspace.workspaceType.icon)",
                ".font(.system(size: 11, weight: .bold))",
                ".frame(width: 14)"
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
                "toolbar.displayMode = .labelOnly",
                "toolbarSelectableItemIdentifiers",
                "private let navigation = SettingsNavigationModel()",
                "navigation.section = section",
                "item.action = #selector(selectToolbarItem(_:))"
            ],
            "AppKit owns navigation while one retained SwiftUI graph renders Settings content"
        )
        controller.excludes("systemSymbolName", "Settings toolbar avoids vector glyphs")
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
            "Argus/Views/GitSidebar/RightSidebarView+WorkspaceFilesRows.swift"
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

    @Test
    func terminalClipboardKeepsPlainTextSeparateFromHTML() {
        let pasteboard = NSPasteboard(name: .init("ArgusTests.TerminalClipboard"))
        let plainText = "selected terminal text"
        let html = "<pre><span>selected terminal text</span></pre>"

        writeTerminalClipboard(
            [
                (mimeType: "text/plain", text: plainText),
                (mimeType: "text/html", text: html)
            ],
            to: pasteboard
        )

        #expect(pasteboard.string(forType: .string) == plainText)
        #expect(pasteboard.string(forType: .html) == html)
    }

    @Test
    func terminalSurfaceTeardownIsNonReentrantAndRetainsCallbackOwners() throws {
        let surface = try SourceContract("Argus/Ghostty/TerminalSurface.swift")
        let teardown = try surface.section(
            after: "func teardownSurface()",
            before: "/// Whether the shell process has exited"
        )

        #expect(teardown.contains("let surfaceToFree = surface"))
        #expect(teardown.contains("self.surface = nil"))
        #expect(teardown.contains("Task { @MainActor [self] in"))
        #expect(teardown.contains("ghostty_surface_free(surfaceToFree)"))
        #expect(teardown.contains("_ = self"))
        #expect(!teardown.contains("ghostty_surface_free(surface)"))
    }

    @Test
    func commandVForImageOnlyClipboardForwardsControlVToTerminalProgram() throws {
        let pasteboard = NSPasteboard(name: .init("ArgusTests.TerminalImageClipboard"))
        pasteboard.clearContents()
        pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)

        let commandV = try #require(keyEvent(characters: "v", modifiers: .command))
        #expect(terminalImagePasteFallback(for: commandV, pasteboard: pasteboard) == "\u{16}")
    }

    @Test
    func terminalImagePasteFallbackPreservesTextAndModifiedPasteBindings() throws {
        let pasteboard = NSPasteboard(name: .init("ArgusTests.TerminalMixedClipboard"))
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .string], owner: nil)
        pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        pasteboard.setString("clipboard text", forType: .string)

        let commandV = try #require(keyEvent(characters: "v", modifiers: .command))
        #expect(terminalImagePasteFallback(for: commandV, pasteboard: pasteboard) == nil)

        pasteboard.clearContents()
        pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        let shiftedCommandV = try #require(
            keyEvent(characters: "V", modifiers: [.command, .shift])
        )
        let controlV = try #require(keyEvent(characters: "\u{16}", modifiers: .control))
        #expect(terminalImagePasteFallback(for: shiftedCommandV, pasteboard: pasteboard) == nil)
        #expect(terminalImagePasteFallback(for: controlV, pasteboard: pasteboard) == nil)
    }

    private func keyEvent(
        characters: String,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters.lowercased(),
            isARepeat: false,
            keyCode: 9
        )
    }

    @Test
    func newWorkspacePresentationCarriesAProjectRequest() throws {
        let window = try SourceContract("Argus/Views/MainWindowView.swift")
        window.containsAll(
            [
                "private struct NewWorkspaceSheetRequest: Identifiable",
                "@State private var newWorkspaceSheetRequest: NewWorkspaceSheetRequest?",
                ".sheet(item: $newWorkspaceSheetRequest) { request in",
                "NewWorkspaceSheet(projectId: request.projectId)"
            ], "new workspace sheet request")
        window.excludes("showNewWorkspaceSheet = true", "presentation must not race optional content")
        window.excludes(
            ".sheet(isPresented: $showNewWorkspaceSheet)",
            "presentation must use an identifiable request"
        )
    }

    @Test
    func standaloneWorkspaceRootPickerUsesManagerOwnedMutation() throws {
        try SourceContract("Argus/Views/Sidebar/SidebarView+Projects.swift").containsAll(
            [
                "if workspace.workspaceType == .external",
                "Button(\"Change Working Directory…\")",
                "panel.canChooseDirectories = true",
                "workspaceManager.setStandaloneWorkspaceRoot(workspace.id, directoryURL: directoryURL)"
            ], "Standalone Workspace context-menu directory picker")
        try SourceContract("Argus/Services/WorkspaceManager+Navigation.swift").containsAll(
            [
                "func setStandaloneWorkspaceRoot(",
                "workspace.workspaceType == .external",
                "directoryURL.standardizedFileURL",
                "workspace.currentDirectory = standardizedURL.path",
                "notifyWorkspaceContextChanged()"
            ], "Workspace Root mutation boundary")
    }

    @Test
    func standaloneWorkspaceRowShowsItsAbbreviatedWorkspaceRoot() throws {
        try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift").containsAll(
            [
                "if workspace.workspaceType == .external",
                "WorkspacePathFormatter.abbreviatedPath(workspace.currentDirectory)",
                ".help(workspaceSubtitleHelp)",
                "parts.append(\"directory \\(workspace.currentDirectory)\")"
            ], "Standalone Workspace Root subtitle")
    }
}
