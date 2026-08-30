// ContentAreaView+Previews.swift
// Argus

import SwiftUI

struct FilePanelPreparedContent: Sendable {
    static let loading = FilePanelPreparedContent(
        state: .loading,
        sourceLines: [],
        markdownBlocks: []
    )

    let state: FilePanelContentState
    let sourceLines: [AttributedString]
    let markdownBlocks: [MarkdownRenderedBlock]

    init(state: FilePanelContentState, fileURL: URL, fileName: String) {
        self.state = state

        switch state {
        case .loaded(.text(let text)):
            sourceLines = FileSourceText.lines(in: text, fileName: fileName)
            if ["md", "markdown"].contains(fileURL.pathExtension.lowercased()) {
                markdownBlocks = MarkdownRenderer.blocks(
                    source: text,
                    baseURL: fileURL.deletingLastPathComponent()
                )
            } else {
                markdownBlocks = []
            }
        case .loaded(.svg(let source, _)):
            sourceLines = FileSourceText.lines(in: source, fileName: fileName)
            markdownBlocks = []
        case .loading, .loaded(.image), .binary, .oversized, .failed:
            sourceLines = []
            markdownBlocks = []
        }
    }

    private init(
        state: FilePanelContentState,
        sourceLines: [AttributedString],
        markdownBlocks: [MarkdownRenderedBlock]
    ) {
        self.state = state
        self.sourceLines = sourceLines
        self.markdownBlocks = markdownBlocks
    }
}

enum FileDisplayMode: CaseIterable, Equatable {
    case source
    case preview

    func systemImage(isSVG: Bool) -> String {
        switch self {
        case .source:
            return "doc.plaintext"
        case .preview:
            return isSVG ? "photo" : "doc.richtext"
        }
    }

    func accessibilityLabel(isSVG: Bool) -> String {
        switch self {
        case .source:
            return isSVG ? "Show SVG source" : "Show Markdown source"
        case .preview:
            return isSVG ? "Show SVG preview" : "Show rendered Markdown"
        }
    }
}

struct FileImagePreview: View {
    let data: Data
    let accessibilityLabel: String

    var body: some View {
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(accessibilityLabel)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .accessibilityHidden(true)
                Text("Image preview is unavailable")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct MarkdownRenderedView: View {
    let blocks: [MarkdownRenderedBlock]
    let documentTextSize: Double

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(maxWidth: 760, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownRenderedBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            Text(content)
                .font(headingFont(level: level))
                .padding(.top, level == 1 ? 4 : 10)
                .padding(.bottom, level <= 2 ? 10 : 6)
        case .paragraph(let content):
            Text(content)
                .font(.system(size: documentTextSize + 2))
                .lineSpacing(3)
                .padding(.bottom, 12)
        case .listItem(let marker, let depth, let content):
            listItemView(marker: marker, depth: depth, content: content)
        case .quote(let content):
            quoteView(content)
        case .code(let language, let content):
            codeView(language: language, content: content)
        case .thematicBreak:
            ChromeColors.separator
                .frame(height: 1)
                .padding(.vertical, 14)
        case .table(let rows):
            tableView(rows)
        }
    }

    private func listItemView(
        marker: String,
        depth: Int,
        content: AttributedString
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(.system(size: documentTextSize + 2, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 24, alignment: .trailing)
            Text(content)
                .font(.system(size: documentTextSize + 2))
                .lineSpacing(3)
        }
        .padding(.leading, CGFloat(depth) * 20)
        .padding(.bottom, 6)
    }

    private func quoteView(_ content: AttributedString) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "quote.opening")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .padding(.top, 3)
            Text(content)
                .font(.system(size: documentTextSize + 2))
                .foregroundColor(.secondary)
                .lineSpacing(3)
        }
        .padding(.bottom, 12)
    }

    private func codeView(language: String?, content: AttributedString) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.system(size: documentTextSize - 2, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            ScrollView(.horizontal) {
                Text(content)
                    .font(.system(size: documentTextSize, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
        .padding(.bottom, 14)
    }

    private func tableView(_ rows: [MarkdownRenderedTableRow]) -> some View {
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(
                                    .system(
                                        size: documentTextSize + 1,
                                        weight: row.isHeader ? .semibold : .regular
                                    )
                                )
                                .padding(8)
                                .frame(minWidth: 100, maxWidth: 260, alignment: .leading)
                                .background(row.isHeader ? Color.primary.opacity(0.055) : Color.clear)
                                .overlay {
                                    Rectangle().stroke(ChromeColors.separator, lineWidth: 1)
                                }
                        }
                    }
                }
            }
        }
        .padding(.bottom, 14)
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1:
            return .system(size: documentTextSize + 14, weight: .bold)
        case 2:
            return .system(size: documentTextSize + 10, weight: .bold)
        case 3:
            return .system(size: documentTextSize + 6, weight: .semibold)
        case 4:
            return .system(size: documentTextSize + 4, weight: .semibold)
        default:
            return .system(size: documentTextSize + 2, weight: .semibold)
        }
    }
}
