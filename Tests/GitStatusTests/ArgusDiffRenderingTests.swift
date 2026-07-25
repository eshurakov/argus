import AppKit
import Foundation
import Testing
import WebKit

@testable import Argus

@Suite
struct ArgusDiffRenderingTests {
    @Test
    func inputEncodesExpectedJSONShape() throws {
        let input = sampleInput()
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        let oldFile = try #require(object["oldFile"] as? [String: Any])
        let options = try #require(object["options"] as? [String: Any])

        #expect(oldFile["name"] as? String == "file.swift")
        #expect(oldFile["contents"] as? String == "old\n")
        #expect(oldFile["language"] as? String == "swift")
        #expect(options["theme"] as? String == "dark")
        #expect(options["style"] as? String == "split")
        #expect(options["overflow"] as? String == "scroll")
        #expect(options["fontSize"] as? Double == 12)
    }

    @Test
    func htmlLoadsLocalBundleAndNamesBridge() {
        #expect(ArgusDiffHTMLTemplate.html.contains("pierre-diffs-bundle.js"))
        #expect(ArgusDiffHTMLTemplate.html.contains("argusDiffBridge"))
        #expect(ArgusDiffHTMLTemplate.html.contains("prefers-color-scheme"))
    }

    @MainActor
    @Test
    func coordinatorQueuesRenderUntilBridgeIsReady() {
        var scripts: [String] = []
        let coordinator = ArgusDiffWebViewCoordinator(evaluateJavaScript: { scripts.append($0) })

        coordinator.update(input: sampleInput())
        #expect(scripts.isEmpty)

        coordinator.bridgeDidBecomeReady()
        #expect(scripts.count == 2)
        #expect(scripts.contains(where: { $0.contains("window.argusDiff.render") }))
        #expect(scripts.contains(where: { $0.contains("--argus-font-size") }))
    }

    @MainActor
    @Test
    func coordinatorUpdatesOptionsWithoutRecreatingRender() {
        var scripts: [String] = []
        let coordinator = ArgusDiffWebViewCoordinator(evaluateJavaScript: { scripts.append($0) })
        coordinator.update(input: sampleInput())
        coordinator.bridgeDidBecomeReady()
        scripts.removeAll()

        let updated = ArgusDiffInput(
            oldFile: sampleInput().oldFile,
            newFile: sampleInput().newFile,
            options: ArgusDiffOptions(theme: .light, style: .unified, overflow: .wrap, fontSize: 14))
        coordinator.update(input: updated)

        #expect(scripts.count == 4)
        #expect(scripts.contains(where: { $0.contains("setTheme") }))
        #expect(scripts.contains(where: { $0.contains("setStyle") }))
        #expect(scripts.contains(where: { $0.contains("setOverflow") }))
        #expect(scripts.contains(where: { $0.contains("--argus-font-size") }))
        #expect(!scripts.contains(where: { $0.contains("argusDiff.render") }))
    }

    @MainActor
    @Test
    func dismantleStopsLoadingAndResetsCoordinator() {
        let coordinator = ArgusDiffWebViewCoordinator(evaluateJavaScript: { _ in })
        let contentController = WKUserContentController()
        contentController.add(coordinator, name: ArgusDiffHTMLTemplate.bridgeHandlerName)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        let webView = WKWebView(frame: .zero, configuration: configuration)
        defer { coordinator.dismantle(webView: webView) }
        coordinator.bridgeDidBecomeReady()

        coordinator.dismantle(webView: webView)

        #expect(!coordinator.isReady)
    }

    @Test
    func generatedBundleIsCopiedIntoHostApp() throws {
        let url = try #require(
            Bundle.main.url(
                forResource: ArgusDiffHTMLTemplate.bundleResourceName,
                withExtension: "js"))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    @Test
    func bundledBridgeRendersDiffInWebView() async throws {
        var rendererError: String?
        let coordinator = ArgusDiffWebViewCoordinator()
        coordinator.onError = { rendererError = $0 }
        let contentController = WKUserContentController()
        contentController.add(coordinator, name: ArgusDiffHTMLTemplate.bridgeHandlerName)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        defer { coordinator.dismantle(webView: webView) }
        coordinator.attach(to: webView)
        coordinator.update(input: sampleInput())
        webView.loadHTMLString(ArgusDiffHTMLTemplate.html, baseURL: Bundle.main.resourceURL)

        for _ in 0..<100 where !coordinator.isReady {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(coordinator.isReady)

        var childCount = 0
        for _ in 0..<100 where childCount == 0 && rendererError == nil {
            try await Task.sleep(for: .milliseconds(20))
            childCount = try #require(
                try await webView.evaluateJavaScript(
                    "document.getElementById('diff').childElementCount") as? Int)
        }

        #expect(rendererError == nil)
        #expect(childCount > 0)
    }

    private func sampleInput() -> ArgusDiffInput {
        ArgusDiffInput(
            oldFile: ArgusDiffFile(name: "file.swift", contents: "old\n", language: "swift"),
            newFile: ArgusDiffFile(name: "file.swift", contents: "new\n", language: "swift"),
            options: ArgusDiffOptions(theme: .dark, style: .split, overflow: .scroll))
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
