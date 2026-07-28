import AppKit
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
