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
