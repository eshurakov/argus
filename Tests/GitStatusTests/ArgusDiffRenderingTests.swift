import AppKit
import Foundation
import SwiftDiffs
import Testing

@testable import Argus

@Suite
struct ArgusDiffRenderingTests {
    @Test
    func mapsOldAndNewFilesToNativePackageInput() {
        let input = sampleInput()

        guard case .files(let oldFile, let newFile) = input.packageInput else {
            Issue.record("expected old/new file input")
            return
        }

        #expect(oldFile?.path == "file.swift")
        #expect(oldFile?.contents == "old\n")
        #expect(oldFile?.language == .swift)
        #expect(newFile?.path == "file.swift")
        #expect(newFile?.contents == "new\n")
        #expect(newFile?.language == .swift)
    }

    @Test
    func mapsSplitDarkPreviewToNativeConfiguration() {
        let configuration = sampleInput().packageConfiguration

        #expect(configuration.layout == .sideBySide)
        #expect(configuration.appearance == .dark)
        #expect(configuration.context == .collapsible())
    }

    @Test
    func mapsUnifiedLightPreviewToNativeConfiguration() {
        let input = ArgusDiffInput(
            oldFile: sampleInput().oldFile,
            newFile: sampleInput().newFile,
            options: ArgusDiffOptions(theme: .light, style: .unified)
        )

        #expect(input.packageConfiguration.layout == .unified)
        #expect(input.packageConfiguration.appearance == .light)
        #expect(input.packageConfiguration.context == .collapsible())
    }

    @Test
    func ignoresUnknownLanguageHintsWithoutRejectingTheDiff() {
        let file = ArgusDiffFile(
            name: "notes.txt",
            contents: "plain\n",
            language: "unknown-language"
        )

        #expect(file.packageFile.language == nil)
    }

    @Test
    func previewHeaderExposesSplitAndUnifiedWithoutOverflowControls() throws {
        try SourceContract("Argus/Views/GitSidebar/GitPreviewPanel.swift").containsAll(
            [
                "Picker(\"Layout\", selection: $diffStyle)",
                "Text(\"Split\").tag(ArgusDiffStyle.split)",
                "Text(\"Unified\").tag(ArgusDiffStyle.unified)",
                "ArgusDiffView("
            ],
            "native Git Preview layout controls"
        )
        try SourceContract("Argus/Views/GitSidebar/GitPreviewPanel.swift").excludes(
            "Overflow",
            "native diffs do not expose wrap or scroll overflow"
        )
        try SourceContract("Argus/Settings/SettingsView.swift").excludes(
            "Default diff overflow",
            "native diffs do not persist an overflow default"
        )
    }

    private func sampleInput() -> ArgusDiffInput {
        ArgusDiffInput(
            oldFile: ArgusDiffFile(name: "file.swift", contents: "old\n", language: "swift"),
            newFile: ArgusDiffFile(name: "file.swift", contents: "new\n", language: "swift"),
            options: ArgusDiffOptions(theme: .dark, style: .split))
    }
}

@Suite
struct FileTabUIContractTests {
    @Test
    func fileTabsShowLineNumbersAndWrapSourceByDefault() throws {
        let lines = FileSourceText.lines(
            in: "first\r\n/* second\ncontinued */\n",
            fileName: "Example.swift")

        #expect(
            lines.map { String($0.characters) } == [
                "first", "/* second", "continued */", ""
            ])
        try SourceContract("Argus/Views/Content/ContentAreaView.swift").containsAll(
            [
                "FilePanelInitialPresentation.resolve(",
                "private var lineWrapButton: some View",
                "Text(\"Wrap\")",
                ".accessibilityLabel(\"Line wrap\")",
                ".accessibilityValue(lineWrapEnabled ? \"On\" : \"Off\")",
                "Text(String(number))",
                ".accessibilityLabel(\"Line \\(number)\")",
                "Color.primary.opacity(0.025)"
            ], "File Tab source gutter and line wrap control")
    }

    @Test
    func filePanelSyntaxHighlighterStylesRecognizedSourceFiles() throws {
        let swiftTokens = FileSyntaxHighlighter.tokens(
            in: "import SwiftUI\nlet title = \"Argus\" // app name\n",
            fileName: "Sources/App.swift")

        #expect(swiftTokens.contains(FileSyntaxHighlightToken(kind: .keyword, text: "import")))
        #expect(swiftTokens.contains(FileSyntaxHighlightToken(kind: .keyword, text: "let")))
        #expect(swiftTokens.contains(FileSyntaxHighlightToken(kind: .typeName, text: "SwiftUI")))
        #expect(swiftTokens.contains(FileSyntaxHighlightToken(kind: .string, text: "\"Argus\"")))
        #expect(swiftTokens.contains(FileSyntaxHighlightToken(kind: .comment, text: "// app name")))

        let jsonTokens = FileSyntaxHighlighter.tokens(
            in: "{\n  \"name\": \"Argus\",\n  \"enabled\": true\n}",
            fileName: "config.json")

        #expect(jsonTokens.contains(FileSyntaxHighlightToken(kind: .property, text: "\"name\"")))
        #expect(jsonTokens.contains(FileSyntaxHighlightToken(kind: .string, text: "\"Argus\"")))
        #expect(jsonTokens.contains(FileSyntaxHighlightToken(kind: .literal, text: "true")))

        #expect(
            FileSyntaxHighlighter.tokens(
                in: "let title = \"plain\"",
                fileName: "notes.txt"
            ).isEmpty)
    }

    @Test
    func markdownFileTabsExposeSourceAndRenderedDisplays() throws {
        try SourceContract("Argus/Views/Content/ContentAreaView.swift").containsAll(
            [
                "enum FileDisplayMode", "case source", "case preview",
                "return \"doc.plaintext\"", "isSVG ? \"photo\" : \"doc.richtext\"",
                "Show Markdown source", "Show rendered Markdown",
                "if isMarkdownFile, displayMode == .preview",
                "MarkdownRenderedView(blocks: preparedContent.markdownBlocks, documentTextSize: documentTextSize)",
                ".cursor(.pointingHand)",
                ".accessibilityValue(isSelected ? \"Selected\" : \"\")"
            ], "Markdown File Tab display controls")
    }

    @Test
    func fileTabDisplayIconsKeepSelectionAndHoverDistinct() throws {
        let view = try SourceContract("Argus/Views/Content/ContentAreaView.swift")
        let displayModeButton = try view.section(
            after: "private func displayModeButton(",
            before: "private func sourceContent")

        for expected in [
            ".frame(width: 20, height: 20)",
            ".fill(isSelected ? ChromeColors.activeTabFill : Color.clear)",
            ".fill(isHovered ? ChromeColors.hoveredTabFill : Color.clear)",
            ".contentShape(Rectangle())",
            ".cursor(.pointingHand)",
            ".help(label)",
            ".accessibilityLabel(label)",
            "HoverStateView { isHovered in"
        ] {
            #expect(displayModeButton.contains(expected))
        }

        view.excludes("hoveredDisplayMode", "display hover state must remain control-local")
        view.excludes("isLineWrapButtonHovered", "line-wrap hover state must remain control-local")
    }

    @Test
    func filePanelCachesDerivedRenderingOutsideBody() throws {
        let filePanel = try SourceContract("Argus/Views/Content/ContentAreaView.swift")
        filePanel.containsAll(
            [
                "struct FilePanelPreparedContent",
                "let sourceLines: [AttributedString]",
                "let markdownBlocks: [MarkdownRenderedBlock]",
                "sourceLines = FileSourceText.lines(in: text, fileName: fileName)",
                "markdownBlocks = MarkdownRenderer.blocks(",
                "sourceContent(preparedContent.sourceLines)",
                "MarkdownRenderedView(blocks: preparedContent.markdownBlocks, documentTextSize: documentTextSize)"
            ], "File Tab derived rendering cache")

        let previews = try SourceContract("Argus/Views/Content/ContentAreaView+Previews.swift")
        let markdownView = try previews.section(
            after: "struct MarkdownRenderedView: View",
            before: "var body: some View")
        #expect(!markdownView.contains("MarkdownRenderer.blocks("))
    }

    @Test
    func filePanelClassifiesRasterImagesAndSVGContent() throws {
        let pngData = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let pngURL = URL(fileURLWithPath: "/tmp/pixel.png")
        #expect(FilePanelContentLoader.content(data: pngData, url: pngURL) == .loaded(.image(pngData)))
        let unknownImageURL = URL(fileURLWithPath: "/tmp/pixel.data")
        #expect(FilePanelContentLoader.content(data: pngData, url: unknownImageURL) == .loaded(.image(pngData)))
        #expect(NSImage(data: pngData) != nil)

        let svgSource = """
            <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">
              <rect width="20" height="20" fill="red"/>
            </svg>
            """
        let svgData = Data(svgSource.utf8)
        let svgURL = URL(fileURLWithPath: "/tmp/icon.svg")
        #expect(
            FilePanelContentLoader.content(data: svgData, url: svgURL)
                == .loaded(.svg(source: svgSource, data: svgData)))
        #expect(NSImage(data: svgData) != nil)
    }

    @Test
    func filePanelClassifiesUTF8ConfigurationFilesAsText() {
        let samples = [
            ("workflow.yml", "name: CI\n"),
            ("config.yaml", "enabled: true\n"),
            ("config.json", "{\"name\":\"Argus\"}\n"),
            (".gitignore", ".build/\n")
        ]

        for (fileName, source) in samples {
            let data = Data(source.utf8)
            let url = URL(fileURLWithPath: "/tmp/\(fileName)")
            #expect(FilePanelContentLoader.content(data: data, url: url) == .loaded(.text(source)))
        }
    }

    @Test
    func imageFileTabsPreviewRasterImagesAndOfferSVGSourceMode() throws {
        try SourceContract("Argus/Views/Content/ContentAreaView.swift").containsAll(
            [
                "case image(Data)",
                "case svg(source: String, data: Data)",
                "type.conforms(to: .image)",
                "CGImageSourceCreateWithData",
                "FileImagePreview(data: data, accessibilityLabel: panel.displayTitle)",
                "Show SVG source", "Show SVG preview",
                "if displayMode == .preview",
                "Image(nsImage: image)",
                ".aspectRatio(contentMode: .fit)",
                "Image preview is unavailable"
            ], "image File Tab previews")
    }

    @Test
    func markdownRendererPreservesCommonBlockStructure() {
        let blocks = MarkdownRenderer.blocks(
            source: """
                # Heading

                Paragraph with **bold** text.

                - First

                > Quote

                ```swift
                let value = 1
                ```

                | Name | Value |
                | --- | --- |
                | Argus | One |
                """,
            baseURL: URL(fileURLWithPath: "/tmp"))

        guard case .heading(let level, let heading) = blocks[0] else {
            Issue.record("expected heading block")
            return
        }
        #expect(level == 1)
        #expect(String(heading.characters) == "Heading")

        #expect(
            blocks.contains { block in
                guard case .listItem(let marker, _, let content) = block else { return false }
                return marker == "•" && String(content.characters) == "First"
            })
        #expect(
            blocks.contains { block in
                guard case .quote(let content) = block else { return false }
                return String(content.characters) == "Quote"
            })
        #expect(
            blocks.contains { block in
                guard case .code(let language, let content) = block else { return false }
                return language == "swift" && String(content.characters).contains("let value = 1")
            })
        #expect(
            blocks.contains { block in
                guard case .table(let rows) = block else { return false }
                return rows.count == 2
                    && rows[0].isHeader
                    && String(rows[1].cells[0].characters) == "Argus"
            })
    }
}
