import Foundation
import Testing

@testable import Argus

@Suite
struct ReleaseNotesTests {
    @Test
    @MainActor
    func releaseNotesTabIsReusedWithinItsWorkspace() {
        let workspace = Workspace(workingDirectory: "/tmp")

        let first = workspace.openReleaseNotesPanel()
        let second = workspace.openReleaseNotesPanel()

        #expect(first.id == second.id)
        #expect(workspace.panels.values.compactMap { $0 as? ReleaseNotesPanel }.count == 1)
        #expect(workspace.activeTabId == first.id)
    }

    @Test
    @MainActor
    func releaseNotesTabsAreScopedToTheirWorkspace() {
        let firstWorkspace = Workspace(workingDirectory: "/tmp/first")
        let secondWorkspace = Workspace(workingDirectory: "/tmp/second")

        #expect(firstWorkspace.openReleaseNotesPanel().id != secondWorkspace.openReleaseNotesPanel().id)
    }

    @Test
    func serviceLoadsMarkdownFromAResourceURL() throws {
        let resourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-release-notes-\(UUID().uuidString).md")
        try "# Changelog\n\n- A change.\n".write(to: resourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: resourceURL) }

        switch ReleaseNotesService.load(resourceURL: resourceURL) {
        case .markdown(let source, let baseURL):
            #expect(source.contains("A change."))
            #expect(baseURL == resourceURL.deletingLastPathComponent())
        case .failed(let message):
            Issue.record("Expected bundled Markdown, got: \(message)")
        }
    }

    @Test
    func serviceReportsAMissingResource() {
        switch ReleaseNotesService.load(resourceURL: nil) {
        case .markdown:
            Issue.record("Expected a missing-resource error")
        case .failed(let message):
            #expect(message.contains("could not be found"))
        }
    }

    @Test
    func releaseNotesUIUsesTheWorkspaceTabAndBrowserLifecycle() throws {
        try SourceContract("Argus/App/ArgusApp.swift").containsAll(
            [
                "CommandGroup(after: .help)",
                "Button(\"Release Notes\")",
                "workspaceManager.openReleaseNotes()"
            ],
            "Help menu opens release notes"
        )
        try SourceContract("Argus/Models/Workspace+Panels.swift").containsAll(
            [
                "func openReleaseNotesPanel() -> ReleaseNotesPanel",
                "compactMap({ $0 as? ReleaseNotesPanel }).first",
                "insertAfterActiveTab(panel.id)",
                "selectPanel(existing.id)"
            ],
            "Release Notes Tab is inserted and reused in one Workspace"
        )
        try SourceContract("Argus/Views/Content/ReleaseNotesPanelView.swift").containsAll(
            [
                "MarkdownRenderedView(",
                ".environment(\\.openURL, OpenURLAction",
                "openLink(url)"
            ],
            "release notes render Markdown and handle links"
        )
        try SourceContract("Argus/Services/WorkspaceManager+Navigation.swift").containsAll(
            [
                "func openReleaseNotesLink(_ url: URL, from panelId: UUID)",
                "workspace(containingPanel: panelId)",
                "workspace.addBrowserPanel(url: url"
            ],
            "release-note links open in the initiating Workspace"
        )
    }
}
