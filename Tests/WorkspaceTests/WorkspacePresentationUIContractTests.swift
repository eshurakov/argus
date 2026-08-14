import AppKit
import Foundation
import Testing

@testable import Argus

@Suite
struct WorkspacePresentationUIContractTests {
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
        let events = try #require(
            terminalImagePasteKeyEvents(for: commandV, pasteboard: pasteboard)
        )

        // Ghostty's paste path replaces 0x16 with a space, so the fallback must
        // synthesise Ctrl+V key events instead of injecting raw text.
        #expect(events.count == 2)
        let press = try #require(events.first)
        #expect(press.action == GHOSTTY_ACTION_PRESS)
        #expect(press.mods == GHOSTTY_MODS_CTRL)
        #expect(press.consumed_mods == GHOSTTY_MODS_NONE)
        #expect(press.keycode == 9)
        #expect(press.unshifted_codepoint == 0x76)
        #expect(press.text == nil)
        #expect(press.composing == false)
        #expect(events.last?.action == GHOSTTY_ACTION_RELEASE)
    }

    @Test
    func terminalImagePasteFallbackPreservesTextAndModifiedPasteBindings() throws {
        let pasteboard = NSPasteboard(name: .init("ArgusTests.TerminalMixedClipboard"))
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .string], owner: nil)
        pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        pasteboard.setString("clipboard text", forType: .string)

        let commandV = try #require(keyEvent(characters: "v", modifiers: .command))
        #expect(terminalImagePasteKeyEvents(for: commandV, pasteboard: pasteboard) == nil)

        pasteboard.clearContents()
        pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        let shiftedCommandV = try #require(
            keyEvent(characters: "V", modifiers: [.command, .shift])
        )
        let controlV = try #require(keyEvent(characters: "\u{16}", modifiers: .control))
        #expect(terminalImagePasteKeyEvents(for: shiftedCommandV, pasteboard: pasteboard) == nil)
        #expect(terminalImagePasteKeyEvents(for: controlV, pasteboard: pasteboard) == nil)
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
    func selectedWorkspaceRowUsesALeadingAccentIndicatorRatherThanAFilledAccentRow() throws {
        let row = try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift")
        row.containsAll(
            [
                ".overlay(alignment: .leading) {",
                ".fill(Color.accentColor)",
                ".frame(width: 3)",
                ".opacity(isSelected ? 1 : 0)",
                "return Color.accentColor.opacity(0.16)",
                "return ChromeColors.hoveredTabFill"
            ], "selected Workspace row indicator and restrained selection fill")
        row.excludes(
            "return Color.accentColor\n",
            "selection must not fill the complete Workspace row with the accent color"
        )
        row.excludes(
            "isSelected ? Color.white",
            "Workspace row content must keep sidebar foreground colors when selected"
        )
        row.excludes(
            "isSelected ? .white",
            "Workspace row text must keep sidebar foreground colors when selected"
        )
    }

    @Test
    func standaloneWorkspaceRowShowsItsAbbreviatedWorkspaceRoot() throws {
        try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift").containsAll(
            [
                "if workspace.workspaceType == .external",
                "WorkspacePathFormatter.abbreviatedPath(workspace.currentDirectory)",
                ".foregroundColor(.secondary.opacity(workspace.workspaceType == .external ? 0.55 : 1))",
                ".help(workspaceSubtitleHelp)",
                "parts.append(\"directory \\(workspace.currentDirectory)\")"
            ], "Standalone Workspace Root subtitle")
    }

    @Test
    func workspaceRowBadgeShowsRunningProcessCountInsteadOfTabCount() throws {
        let row = try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift")
        row.containsAll(
            [
                "TimelineView(.periodic(from: .now, by: 1))",
                "workspace.runningProcessCount",
                "if runningProcessCount > 0",
                "CountBadge(count: runningProcessCount)",
                "1 running process",
                "\\(runningProcessCount) running processes"
            ],
            "Workspace row badge counts Terminal Surfaces with a running process"
        )
        row.excludes("workspace.panelCount > 1", "Workspace row badge must not show Top-level Tab count")
        row.excludes("\\(workspace.panelCount) tabs", "Workspace accessibility must not announce tab count")
    }

    @Test
    func workspaceRowsHidePermanentShortcutNumbersUntilCommandIsHeld() throws {
        let row = try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift")
        row.containsAll(
            [
                "@Environment(\\.isCommandKeyHeld) private var isCommandKeyHeld",
                "let shortcutDigit: Int?",
                "workspaceIcon",
                "private var workspaceIcon: some View",
                "if let shortcutDigit, showsShortcutOverlay",
                "Text(\"\\(shortcutDigit)\")",
                "isCommandKeyHeld && shortcutDigit != nil"
            ],
            "Command-held Workspace shortcut overlay"
        )
        row.excludes(
            "Text(\"\\(globalIndex)\")",
            "Workspace rows must not keep a permanent Workspace Number column"
        )
        row.excludes(
            ".frame(width: 16)",
            "Workspace rows must reclaim the reserved shortcut-number column"
        )

        try SourceContract("Argus/Views/Sidebar/SidebarView+Projects.swift").contains(
            "shortcutDigit: workspaceManager.workspaceShortcutDigit(for: workspace.id)",
            "Workspace rows receive reachable shortcut digits from global sidebar order"
        )
        try SourceContract("Argus/Views/Sidebar/SidebarView+Header.swift").containsAll(
            [
                ".environment(\\.isCommandKeyHeld, commandKeyMonitor.isCommandHeld)",
                "commandKeyMonitor.start()",
                "commandKeyMonitor.stop()"
            ],
            "sidebar Command-key environment"
        )
        try SourceContract("Argus/Views/Sidebar/SidebarView.swift").containsAll(
            [
                "enum WorkspaceShortcutNumber",
                "final class CommandKeyMonitor: ObservableObject",
                "NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)",
                "NSApplication.didResignActiveNotification",
                "NSWindow.didResignKeyNotification",
                "clearHeldState()",
                "@StateObject var commandKeyMonitor = CommandKeyMonitor()"
            ],
            "window-local Command-key monitor"
        )
    }
}
