// swiftlint:disable file_length
// ContentAreaView+FilePanel.swift
// Argus

import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum FilePanelLoadedContent: Equatable, Sendable {
    case text(String)
    case image(Data)
    case svg(source: String, data: Data)
}

enum FilePanelContentState: Equatable, Sendable {
    case loading
    case loaded(FilePanelLoadedContent)
    case binary
    case failed(String)
}

struct FilePanelInitialPresentation: Equatable {
    let displayMode: FileDisplayMode
    let lineWrapEnabled: Bool

    static func resolve(
        fileURL: URL,
        wrapSourceLines: Bool,
        openMarkdownInPreview: Bool,
        openSVGInPreview: Bool
    ) -> Self {
        let fileExtension = fileURL.pathExtension.lowercased()
        let opensInPreview =
            (fileExtension == "svg" && openSVGInPreview)
            || (["md", "markdown"].contains(fileExtension) && openMarkdownInPreview)
        return Self(
            displayMode: opensInPreview ? .preview : .source,
            lineWrapEnabled: wrapSourceLines
        )
    }
}

enum FilePanelContentLoader {
    static func load(url: URL) -> FilePanelContentState {
        do {
            let data = try Data(contentsOf: url)
            return content(data: data, url: url)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func content(data: Data, url: URL) -> FilePanelContentState {
        if url.pathExtension.lowercased() == "svg" {
            guard let source = String(data: data, encoding: .utf8) else {
                return .failed("SVG source is not valid UTF-8")
            }
            return .loaded(.svg(source: source, data: data))
        }

        if let type = UTType(filenameExtension: url.pathExtension),
            type.conforms(to: .image)
        {
            return .loaded(.image(data))
        }

        if !data.contains(0), let text = String(data: data, encoding: .utf8) {
            return .loaded(.text(text))
        }

        if CGImageSourceCreateWithData(data as CFData, nil) != nil {
            return .loaded(.image(data))
        }

        return .binary
    }
}

enum FileSourceText {
    static func lines(in text: String, fileName: String) -> [AttributedString] {
        let highlighted = FileSyntaxHighlighter.highlightedText(
            for: text,
            fileName: fileName
        )
        var lines: [AttributedString] = []
        var lineStart = highlighted.startIndex

        for index in highlighted.characters.indices where highlighted.characters[index].isNewline {
            lines.append(AttributedString(highlighted[lineStart..<index]))
            lineStart = highlighted.characters.index(after: index)
        }
        lines.append(AttributedString(highlighted[lineStart..<highlighted.endIndex]))
        return lines
    }
}

struct FilePanelContentView: View {
    @ObservedObject var panel: FilePanel
    @State private var preparedContent = FilePanelPreparedContent.loading
    @State private var displayMode: FileDisplayMode
    @State private var lineWrapEnabled: Bool
    let documentTextSize: Double

    init(
        panel: FilePanel,
        wrapSourceLines: Bool = true,
        openMarkdownInPreview: Bool = false,
        openSVGInPreview: Bool = false,
        documentTextSize: Double = 12
    ) {
        self.panel = panel
        let initialPresentation = FilePanelInitialPresentation.resolve(
            fileURL: panel.fileURL,
            wrapSourceLines: wrapSourceLines,
            openMarkdownInPreview: openMarkdownInPreview,
            openSVGInPreview: openSVGInPreview
        )
        _displayMode = State(initialValue: initialPresentation.displayMode)
        _lineWrapEnabled = State(initialValue: initialPresentation.lineWrapEnabled)
        self.documentTextSize = documentTextSize
    }

    var body: some View {
        VStack(spacing: 0) {
            fileHeader
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ChromeColors.contentBackground)
        .task(id: panel.fileURL) {
            await loadFile()
        }
    }
}

extension FilePanelContentView {
    private var fileHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: fileIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(panel.relativePath)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)

            if showsSource {
                lineWrapButton
            }

            if supportsSourcePreview {
                ForEach(FileDisplayMode.allCases, id: \.self) { mode in
                    displayModeButton(mode)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .overlay(alignment: .bottom) {
            ChromeColors.separator.frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .loaded(let loadedContent):
            switch loadedContent {
            case .text:
                if isMarkdownFile, displayMode == .preview {
                    MarkdownRenderedView(blocks: preparedContent.markdownBlocks, documentTextSize: documentTextSize)
                } else {
                    sourceContent(preparedContent.sourceLines)
                }
            case .image(let data):
                FileImagePreview(data: data, accessibilityLabel: panel.displayTitle)
            case .svg(_, let data):
                if displayMode == .preview {
                    FileImagePreview(data: data, accessibilityLabel: panel.displayTitle)
                } else {
                    sourceContent(preparedContent.sourceLines)
                }
            }
        case .binary:
            fileMessage("Binary file", systemImage: "doc.fill")
        case .failed(let message):
            fileMessage(message, systemImage: "exclamationmark.triangle")
        }
    }

    private var state: FilePanelContentState {
        preparedContent.state
    }

    private var isMarkdownFile: Bool {
        ["md", "markdown"].contains(panel.fileURL.pathExtension.lowercased())
    }

    private var isSVGFile: Bool {
        panel.fileURL.pathExtension.lowercased() == "svg"
    }

    private var supportsSourcePreview: Bool {
        isMarkdownFile || isSVGFile
    }

    private var showsSource: Bool {
        switch state {
        case .loaded(.text):
            return !supportsSourcePreview || displayMode == .source
        case .loaded(.svg):
            return displayMode == .source
        default:
            return false
        }
    }

    private var fileIcon: String {
        switch state {
        case .loaded(.image), .loaded(.svg):
            return "photo"
        default:
            return "doc.text"
        }
    }

    private var lineWrapButton: some View {
        HoverStateView { isHovered in
            Button {
                lineWrapEnabled.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.left")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(lineWrapEnabled ? Color.primary : Color.secondary)
                        .accessibilityHidden(true)
                    Text("Wrap")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(lineWrapEnabled ? .primary : .secondary)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(lineWrapEnabled ? ChromeColors.activeTabFill : Color.clear)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isHovered ? ChromeColors.hoveredTabFill : Color.clear)
                        }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help(lineWrapEnabled ? "Disable line wrap" : "Enable line wrap")
            .accessibilityLabel("Line wrap")
            .accessibilityValue(lineWrapEnabled ? "On" : "Off")
        }
    }

    private func displayModeButton(_ mode: FileDisplayMode) -> some View {
        let isSelected = displayMode == mode
        let label = mode.accessibilityLabel(isSVG: isSVGFile)

        return HoverStateView { isHovered in
            Button {
                displayMode = mode
            } label: {
                Image(systemName: mode.systemImage(isSVG: isSVGFile))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .accessibilityHidden(true)
                    .frame(width: 20, height: 20)
                    .background {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isSelected ? ChromeColors.activeTabFill : Color.clear)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isHovered ? ChromeColors.hoveredTabFill : Color.clear)
                            }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help(label)
            .accessibilityLabel(label)
            .accessibilityValue(isSelected ? "Selected" : "")
        }
    }

    private func sourceContent(_ lines: [AttributedString]) -> some View {
        let digitCount = String(lines.count).count
        let gutterWidth = max(36, CGFloat(digitCount * 7 + 18))

        return GeometryReader { proxy in
            if lineWrapEnabled {
                ScrollView(.vertical) {
                    sourceLines(
                        lines,
                        gutterWidth: gutterWidth,
                        viewportSize: proxy.size,
                        wrapsLines: true
                    )
                }
            } else {
                ScrollView([.horizontal, .vertical]) {
                    sourceLines(
                        lines,
                        gutterWidth: gutterWidth,
                        viewportSize: proxy.size,
                        wrapsLines: false
                    )
                }
            }
        }
    }

    private func sourceLines(
        _ lines: [AttributedString],
        gutterWidth: CGFloat,
        viewportSize: CGSize,
        wrapsLines: Bool
    ) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                sourceLine(
                    lines[index],
                    number: index + 1,
                    gutterWidth: gutterWidth,
                    wrapsLines: wrapsLines
                )
            }
        }
        .padding(.vertical, 12)
        .frame(
            width: wrapsLines ? viewportSize.width : nil,
            alignment: .topLeading
        )
        .frame(
            minWidth: viewportSize.width,
            minHeight: viewportSize.height,
            alignment: .topLeading
        )
        .background(alignment: .leading) {
            HStack(spacing: 0) {
                Color.primary.opacity(0.025)
                    .frame(width: gutterWidth)
                ChromeColors.separator
                    .frame(width: 1)
            }
        }
    }

    private func sourceLine(
        _ line: AttributedString,
        number: Int,
        gutterWidth: CGFloat,
        wrapsLines: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(String(number))
                .foregroundColor(.secondary.opacity(0.7))
                .frame(width: gutterWidth - 8, alignment: .trailing)
                .padding(.trailing, 8)
                .accessibilityLabel("Line \(number)")

            Group {
                if wrapsLines {
                    sourceLineText(line)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    sourceLineText(line)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
        }
        .font(.system(size: documentTextSize, design: .monospaced))
        .padding(.vertical, 1)
    }

    private func sourceLineText(_ line: AttributedString) -> some View {
        Text(line.characters.isEmpty ? AttributedString(" ") : line)
            .textSelection(.enabled)
    }

    private func fileMessage(_ message: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary.opacity(0.5))
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadFile() async {
        let url = panel.fileURL
        let fileName = panel.relativePath
        preparedContent = .loading
        let loadedState = await Task.detached(priority: .userInitiated) {
            FilePanelContentLoader.load(url: url)
        }.value
        guard !Task.isCancelled,
            panel.fileURL == url,
            panel.relativePath == fileName
        else {
            return
        }
        preparedContent = FilePanelPreparedContent(
            state: loadedState,
            fileURL: url,
            fileName: fileName
        )
    }
}
