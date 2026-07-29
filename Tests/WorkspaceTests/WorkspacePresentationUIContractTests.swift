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
                "SemanticIcon(name: \"bell.fill\", pointSize: 11, weight: .bold)",
                "SemanticIcon(name: agentStatus.state.symbolName, pointSize: 11, weight: .semibold)",
                "SemanticIcon(name: workspace.workspaceType.icon, pointSize: 11, weight: .semibold)",
                ".frame(width: 14)"
            ], "native Workspace row status and type icons")
        row.excludes("workspaceTypeMarker", "Workspace rows use semantic type symbols")
    }

    @Test
    func appSourceUsesOnlyTheCentralizedAppKitSymbolRenderer() throws {
        let renderer = try SourceContract("Argus/Views/ChromeColors.swift")
        renderer.containsAll(
            [
                "NSImage(systemSymbolName: name, accessibilityDescription: nil)",
                "NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)",
                "Image(nsImage:",
                ".renderingMode(.template)",
                "static func clampedPointSize",
                "pointSize.isFinite",
                "private let capacity = 256",
                "fallbackImage(pointSize: pointSize)"
            ], "central AppKit-backed semantic symbol renderer")

        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryRoot = testsDirectory.deletingLastPathComponent()
        let sourceRoot = repositoryRoot.appendingPathComponent("Argus")
        let rawSwiftUIPatterns = [
            #"Image\s*\(\s*systemName\s*:"#,
            #"Label\s*\(\s*[^\n]*systemImage\s*:"#
        ]
        let appKitSymbolPattern = #"NSImage\s*\(\s*systemSymbolName\s*:"#
        let sourceURLs =
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            for pattern in rawSwiftUIPatterns {
                let range = NSRange(source.startIndex..., in: source)
                if try NSRegularExpression(pattern: pattern).firstMatch(in: source, range: range) != nil {
                    Issue.record("\(sourceURL.path) invokes raw SwiftUI SF Symbol rendering API")
                }
            }

            let range = NSRange(source.startIndex..., in: source)
            if sourceURL.path != sourceRoot.appendingPathComponent("Views/ChromeColors.swift").path,
                try NSRegularExpression(pattern: appKitSymbolPattern).firstMatch(in: source, range: range) != nil
            {
                Issue.record("\(sourceURL.path) bypasses the centralized AppKit symbol renderer")
            }
        }
    }

    @Test
    @MainActor
    func semanticIconClampsInvalidSizesAndCreatesPositiveFallback() {
        #expect(SemanticIcon.clampedPointSize(.nan) == 1)
        #expect(SemanticIcon.clampedPointSize(-1) == 1)
        #expect(SemanticIcon.clampedPointSize(0) == 1)
        #expect(SemanticIcon.clampedPointSize(11) == 11)

        let fallback = SemanticIcon.resolvedImage(
            name: "argus.unknown.system.symbol",
            pointSize: 0,
            weight: .regular
        )
        #expect(fallback.size.width >= 1)
        #expect(fallback.size.height >= 1)
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
