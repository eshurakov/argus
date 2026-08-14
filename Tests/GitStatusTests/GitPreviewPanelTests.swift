import AppKit
import Foundation
import Testing

@testable import Argus

@Suite
struct GitPreviewPanelTests {
    @Test
    @MainActor
    func modelsPreviewTabTitleAndIcon() {
        let panel = GitPreviewPanel(
            rootPath: "/tmp/repo",
            preview: GitPreview(
                kind: .diff,
                path: "Sources/App.swift",
                content: .ansiText("diff")))

        assertEqual(panel.panelType, .gitPreview, "preview uses generic workspace tab model")
        assertEqual(panel.displayTitle, "Diff: App.swift", "diff tab uses compact file title")
        assertEqual(panel.displayIcon, "doc.text.magnifyingglass", "diff tab uses preview icon")

        panel.update(
            preview: GitPreview(
                kind: .blame,
                path: "Sources/App.swift",
                content: .ansiText("blame")))
        assertEqual(panel.displayTitle, "Blame: App.swift", "updated blame preview refreshes tab title")
    }

    @Test
    @MainActor
    func rendersANSIColorsWithoutEscapeCodes() {
        let rendered = GitPreviewANSITextRenderer.attributedString(
            for: "\u{001B}[31m-red\u{001B}[0m plain")

        assertEqual(
            rendered.string, "-red plain", "ANSI escape codes are stripped from rendered preview text")
        assertColor(rendered, at: 0, equals: .systemRed, "SGR red maps to visible foreground color")
    }

    @Test
    @MainActor
    func resetsANSIColorAfterSGRReset() {
        let paletteForeground = NSColor(
            srgbRed: 0.72,
            green: 0.81,
            blue: 0.9,
            alpha: 1)
        let rendered = GitPreviewANSITextRenderer.attributedString(
            for: "\u{001B}[32m+green\u{001B}[0m plain",
            foregroundColor: paletteForeground)

        assertEqual(rendered.string, "+green plain", "reset keeps only visible preview text")
        assertColor(rendered, at: 0, equals: .systemGreen, "SGR green maps to visible foreground color")
        assertColor(
            rendered,
            at: 7,
            equals: paletteForeground,
            "SGR reset restores Ghostty-derived foreground color")
    }

    @Test
    @MainActor
    func selectsRendererForPreviewContent() {
        let diff = GitPreviewContent.diff(
            GitDiffPreview(
                fileName: "file.txt", oldContent: "old", newContent: "new"))
        assertEqual(
            GitPreviewPanelContentKind(content: diff), .diff,
            "structured diff content selects Pierre renderer")
        assertEqual(
            GitPreviewPanelContentKind(content: .ansiText("blame")), .ansiText,
            "blame and failure text select ANSI renderer")
    }

    @Test
    @MainActor
    func usesGhosttyPaletteForPreviewRendering() throws {
        let darkPalette = ChromePalette(
            background: NSColor(srgbRed: 0.05, green: 0.06, blue: 0.07, alpha: 1),
            foreground: NSColor(srgbRed: 0.9, green: 0.91, blue: 0.92, alpha: 1),
            revision: 4)
        let lightPalette = ChromePalette(
            background: NSColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1),
            foreground: NSColor(srgbRed: 0.1, green: 0.11, blue: 0.12, alpha: 1),
            revision: 5)

        #expect(darkPalette.isDark)
        #expect(!lightPalette.isDark)
        #expect(darkPalette.revision == 4)

        try SourceContract("Argus/Views/GitSidebar/GitPreviewPanel.swift").containsAll(
            [
                "@ObservedObject private var ghosttyApp = GhosttyApp.shared",
                "foregroundColor: ghosttyApp.chromePalette.foreground",
                "theme: ghosttyApp.chromePalette.isDark ? .dark : .light",
                ".id(ghosttyApp.chromePalette.revision)",
                "foregroundColor: NSColor = ChromeColors.foregroundNSColor"
            ], "Git Preview palette and renderer refresh")
        try SourceContract("Argus/DiffRendering/ArgusDiffHTMLTemplate.swift").containsAll(
            [
                "--argus-background: \\(ChromeColors.backgroundCSS)",
                "--argus-foreground: \\(ChromeColors.foregroundCSS)",
                "color: var(--argus-foreground)",
                "background: var(--argus-background)"
            ], "diff renderer inherits Ghostty-derived chrome colors")
        try SourceContract("Argus/Ghostty/GhosttyApp.swift").containsAll(
            [
                "extractChromePalette(from: cfg)",
                "configColor(named: \"background\", from: config)",
                "configColor(named: \"foreground\", from: config)",
                "revision: chromePalette.revision &+ 1",
                "extractChromePalette(from: newConfig)"
            ], "Ghostty configuration owns preview palette updates")
    }

    @Test
    @MainActor
    func preservesElevenPointANSITextAtDefaultDocumentSize() throws {
        let rendered = GitPreviewANSITextRenderer.attributedString(for: "blame", fontSize: 11)
        let font = try #require(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        assertEqual(font.pointSize, 11, "ANSI previews preserve their original default font size")
        try SourceContract("Argus/Views/GitSidebar/GitPreviewPanel.swift").containsAll(
            ["fontSize: ansiTextSize", "max(documentTextSize - 1, 10)"],
            "ANSI preview size derives from document size while preserving default 11 pt"
        )
    }

    @Test
    @MainActor
    func argusTerminalThemeUsesBlackBackground() throws {
        let themeURL = try #require(
            Bundle.main.url(forResource: "ArgusTerminalTheme", withExtension: "ghostty"))
        let theme = try String(contentsOf: themeURL, encoding: .utf8)
        let assignments = theme.components(separatedBy: .newlines).filter {
            !$0.isEmpty && !$0.hasPrefix("#")
        }
        #expect(assignments == ["background = 000000", "background-opacity = 1"])

        let background = try #require(GhosttyApp.shared.defaultBackgroundColor.usingColorSpace(.sRGB))
        #expect(background.redComponent == 0)
        #expect(background.greenComponent == 0)
        #expect(background.blueComponent == 0)
        #expect(GhosttyApp.shared.defaultBackgroundOpacity == 1)

        try SourceContract("Argus/Ghostty/GhosttyApp.swift").containsAll(
            [
                "ghostty_config_load_default_files(config)",
                "ghostty_config_load_recursive_files(config)",
                "loadTerminalTheme(into: config)",
                "ghostty_config_finalize(config)",
                "guard let newConfig = makeConfiguration() else { return }"
            ], "Argus terminal theme override applies on launch and reload")
    }

    private func assertColor(
        _ text: NSAttributedString, at index: Int, equals expected: NSColor, _ message: String
    ) {
        let actual = text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
        #expect(actual?.isEqual(expected) == true, Comment(rawValue: message))
    }

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }
}

@Suite
struct GitStatusPreviewUIContractTests {
    @Test
    func destructiveConfirmationNamesExactPaths() {
        #expect(
            GitStatusFileOperation.discard.confirmationMessage(paths: ["Sources/App.swift", "README.md"])
                == "This will permanently discard unstaged changes in:\n\n\"Sources/App.swift\"\n\"README.md\"")
        #expect(
            GitStatusFileOperation.delete.confirmationMessage(paths: ["scratch notes.txt"])
                == "This will permanently delete from disk:\n\n\"scratch notes.txt\"")
    }

    @Test
    func diffAndBlameActionsUseThePreviewPipeline() throws {
        let view = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
        view.containsAll(
            [
                "case diff", "case blame",
                "await showPreview(kind: .diff, file: file, owner: owner)",
                "await showPreview(kind: .blame, file: file, owner: owner)",
                "viewModel.loadPreview(kind: kind, file: file, owner: owner)",
                "$0.id == owner.workspaceId",
                "rootPath: owner.rootPath"
            ], "diff and blame actions")
        let untracked = try view.section(
            after: "case .untracked:\n            return [.stage",
            before: "case .uncommitted:"
        )
        #expect(untracked.contains(".diff"))
        #expect(!untracked.contains(".blame"))

        try SourceContract("Argus/Models/Panel.swift").containsAll(
            [
                "case gitPreview",
                "final class GitPreviewPanel",
                "let panelType: PanelType = .gitPreview"
            ], "preview tab model")
        try SourceContract("Argus/Models/Workspace.swift").containsAll(
            [
                "func openGitPreviewPanel(rootPath: String, preview: GitPreview)",
                "$0.preview.kind == preview.kind",
                "$0.preview.path == preview.path",
                "existing.update(preview: preview)",
                "selectPanel(existing.id)"
            ], "preview tab insertion and reuse")
        try SourceContract("Argus/Views/Content/ContentAreaView.swift").containsAll(
            [
                "case .gitPreview:",
                "GitPreviewPanelContentView("
            ], "preview tab content")
        try SourceContract("Argus/Services/GitPreviewService.swift").containsAll(
            [
                "case diff(GitDiffPreview)",
                "cat-file", "workingTreeFile(rootPath:"
            ], "structured diff content extraction")
    }

    @Test
    func nonRepositoryStateOffersInitializationAndRecovery() throws {
        try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift").containsAll(
            [
                "case .notRepository(let rootPath):",
                "notRepositoryContent(rootPath: rootPath",
                "actionTitle: \"Initialize Git Repository\"",
                "guard let owner = selectedSnapshotOwner, viewModel.ownsSnapshot(owner)",
                "await viewModel.initializeRepository(owner: owner)",
                "case .repositoryInitializationFailed(let rootPath, let message):",
                "notRepositoryContent(rootPath: rootPath, message: message",
                "actionTitle: \"Refresh Changes\""
            ], "repository initialization UI")
    }

    @Test
    func titlebarAndSidebarShareWorkspaceScopedStatus() throws {
        try SourceContract("Argus/Views/MainWindowView.swift").containsAll(
            [
                "@StateObject private var gitStatusViewModel = GitStatusViewModel()",
                ".environmentObject(gitStatusViewModel)"
            ], "shared git status ownership")
        try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift").containsAll(
            [
                "@EnvironmentObject var viewModel: GitStatusViewModel",
                "GitStatusSnapshotOwner",
                "return viewModel.owner(",
                "workspaceId: workspace.id",
                "presentation: GitStatusPresentation(",
                "viewModel.activate(owner)",
                "viewModel.ownsSnapshot(owner)",
                "viewModel.refresh(owner: owner)"
            ], "workspace-scoped sidebar status")
        try SourceContract("Argus/Views/Titlebar/TitlebarView.swift").containsAll(
            [
                "@EnvironmentObject private var gitStatusViewModel: GitStatusViewModel",
                ".task(id: statusRefreshOwner)",
                "private var statusRefreshOwner: GitStatusSnapshotOwner?",
                "await gitStatusViewModel.refresh(owner: owner)",
                "workspaceId: workspace.id",
                "presentation: GitStatusPresentation(",
                "workspaceManager.activeWorkspaceTitle",
                "NSApp.mainWindow?.title"
            ], "workspace-scoped titlebar status")
    }

}
