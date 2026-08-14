import AppKit
import SwiftUI

enum GitPreviewPanelContentKind: Equatable {
    case diff
    case ansiText

    init(content: GitPreviewContent) {
        switch content {
        case .diff:
            self = .diff
        case .ansiText:
            self = .ansiText
        }
    }
}

struct GitPreviewPanelContentView: View {
    @ObservedObject var panel: GitPreviewPanel
    @ObservedObject private var ghosttyApp = GhosttyApp.shared

    @State private var diffStyle: ArgusDiffStyle
    let documentTextSize: Double

    init(
        panel: GitPreviewPanel,
        initialDiffStyle: ArgusDiffStyle = .split,
        documentTextSize: Double = 12
    ) {
        self.panel = panel
        _diffStyle = State(initialValue: initialDiffStyle)
        self.documentTextSize = documentTextSize
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(panel.preview.path)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if case .diff = panel.preview.content {
                    Picker("Layout", selection: $diffStyle) {
                        Text("Split").tag(ArgusDiffStyle.split)
                        Text("Unified").tag(ArgusDiffStyle.unified)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }
            }
            .padding(10)

            Divider()

            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ChromeColors.contentBackground)
    }

    @ViewBuilder
    private var previewContent: some View {
        switch panel.preview.content {
        case .diff(let preview):
            ArgusDiffView(
                input: ArgusDiffInput(
                    oldFile: ArgusDiffFile(name: preview.fileName, contents: preview.oldContent),
                    newFile: ArgusDiffFile(name: preview.fileName, contents: preview.newContent),
                    options: ArgusDiffOptions(
                        theme: ghosttyApp.chromePalette.isDark ? .dark : .light,
                        style: diffStyle
                    )
                )
            )
            .id(ghosttyApp.chromePalette.revision)
        case .ansiText(let output):
            GitPreviewANSITextView(
                output: output,
                foregroundColor: ghosttyApp.chromePalette.foreground,
                fontSize: ansiTextSize
            )
        }
    }

    private var ansiTextSize: Double {
        max(documentTextSize - 1, 10)
    }
}

struct GitPreviewANSITextRenderer {
    static func attributedString(
        for output: String,
        foregroundColor: NSColor = ChromeColors.foregroundNSColor,
        fontSize: CGFloat = 12
    ) -> NSAttributedString {
        let text = output.isEmpty ? "No output" : output
        let result = NSMutableAttributedString()
        var index = text.startIndex
        var attributes = defaultAttributes(foregroundColor: foregroundColor, fontSize: fontSize)

        while index < text.endIndex {
            if let sequence = sgrSequence(in: text, at: index) {
                apply(sequence.codes, to: &attributes, foregroundColor: foregroundColor, fontSize: fontSize)
                index = sequence.endIndex
                continue
            }

            result.append(
                NSAttributedString(
                    string: String(text[index]),
                    attributes: attributes
                ))
            index = text.index(after: index)
        }

        return result
    }

    private static func sgrSequence(
        in text: String,
        at index: String.Index
    ) -> (codes: [Int], endIndex: String.Index)? {
        guard text[index] == "\u{001B}" else { return nil }
        let bracketIndex = text.index(after: index)
        guard bracketIndex < text.endIndex, text[bracketIndex] == "[" else { return nil }

        var cursor = text.index(after: bracketIndex)
        var parameterText = ""
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "m" {
                let endIndex = text.index(after: cursor)
                let codes =
                    parameterText.isEmpty
                    ? [0]
                    : parameterText.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
                return (codes, endIndex)
            }
            guard character.isNumber || character == ";" else { return nil }
            parameterText.append(character)
            cursor = text.index(after: cursor)
        }

        return nil
    }

    private static func apply(
        _ codes: [Int],
        to attributes: inout [NSAttributedString.Key: Any],
        foregroundColor: NSColor,
        fontSize: CGFloat
    ) {
        for code in codes {
            switch code {
            case 0:
                attributes = defaultAttributes(foregroundColor: foregroundColor, fontSize: fontSize)
            case 1:
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
            case 22:
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            case 30...37, 90...97:
                attributes[.foregroundColor] = color(for: code, foregroundColor: foregroundColor)
            case 39:
                attributes[.foregroundColor] = foregroundColor
            default:
                continue
            }
        }
    }

    private static func defaultAttributes(
        foregroundColor: NSColor,
        fontSize: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: foregroundColor
        ]
    }

    private static func color(for code: Int, foregroundColor: NSColor) -> NSColor {
        switch code {
        case 30: return .black
        case 31, 91: return .systemRed
        case 32, 92: return .systemGreen
        case 33, 93: return .systemYellow
        case 34, 94: return .systemBlue
        case 35, 95: return .systemPurple
        case 36, 96: return .systemCyan
        case 37, 97: return foregroundColor
        case 90: return foregroundColor.withAlphaComponent(0.65)
        default: return foregroundColor
        }
    }
}

private struct GitPreviewANSITextView: NSViewRepresentable {
    let output: String
    var foregroundColor: NSColor = ChromeColors.foregroundNSColor
    var fontSize: CGFloat = 12

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.textStorage?.setAttributedString(
            GitPreviewANSITextRenderer.attributedString(
                for: output,
                foregroundColor: foregroundColor,
                fontSize: fontSize
            ))
    }
}
