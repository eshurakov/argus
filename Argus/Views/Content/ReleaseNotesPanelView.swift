import SwiftUI

struct ReleaseNotesPanelView: View {
    @ObservedObject var panel: ReleaseNotesPanel
    let documentTextSize: Double
    let openLink: (URL) -> Void

    private let content: ReleaseNotesContent

    init(
        panel: ReleaseNotesPanel,
        content: ReleaseNotesContent = ReleaseNotesService.load(),
        documentTextSize: Double,
        openLink: @escaping (URL) -> Void
    ) {
        self.panel = panel
        self.content = content
        self.documentTextSize = documentTextSize
        self.openLink = openLink
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ChromeColors.contentBackground)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: panel.displayIcon ?? "doc.text")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(panel.displayTitle)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .overlay(alignment: .bottom) {
            ChromeColors.separator.frame(height: 1)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch content {
        case .markdown(let source, let baseURL):
            MarkdownRenderedView(
                blocks: MarkdownRenderer.blocks(source: source, baseURL: baseURL),
                documentTextSize: documentTextSize
            )
            .environment(
                \.openURL,
                OpenURLAction { url in
                    openLink(url)
                    return .handled
                })
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Release notes unavailable")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
    }
}
