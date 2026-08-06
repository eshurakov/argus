import AppKit
import SwiftUI
import WebKit

struct BrowserView: View {
    @ObservedObject var panel: BrowserPanel
    let isActive: Bool

    @State private var addressText: String
    @State private var findQuery = ""
    @State private var isFindVisible = false
    @FocusState private var isAddressFocused: Bool
    @FocusState private var isFindFocused: Bool

    init(panel: BrowserPanel, isActive: Bool) {
        self.panel = panel
        self.isActive = isActive
        _addressText = State(initialValue: panel.currentURL?.absoluteString ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            browserHeader
            BrowserWebView(panel: panel, isActive: isActive)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if isFindVisible {
                        findOverlay
                            .padding(8)
                            .transition(.opacity)
                    }
                }
        }
        .background(ChromeColors.contentBackground)
        .onChange(of: panel.currentURL) { _, url in
            guard !isAddressFocused else { return }
            addressText = url?.absoluteString ?? ""
        }
        .onChange(of: panel.findRequestGeneration) { _, _ in
            presentFind()
        }
        .onChange(of: panel.focusRequest) { _, request in
            applyFocusRequest(request)
        }
        .onAppear {
            if panel.focusRequest.generation > 0 {
                applyFocusRequest(panel.focusRequest)
            }
        }
        .onExitCommand {
            guard isFindVisible else { return }
            dismissFind()
        }
    }

    private var browserHeader: some View {
        HStack(spacing: 4) {
            chromeButton(
                systemImage: "chevron.left",
                help: "Go back",
                enabled: panel.canGoBack,
                action: panel.goBack
            )
            chromeButton(
                systemImage: "chevron.right",
                help: "Go forward",
                enabled: panel.canGoForward,
                action: panel.goForward
            )
            chromeButton(
                systemImage: "arrow.clockwise",
                help: "Reload page",
                enabled: panel.currentURL != nil && !panel.isLoading,
                action: panel.reload
            )

            connectionIndicator

            TextField("Enter website address", text: $addressText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isAddressFocused)
                .onSubmit {
                    if panel.navigate(to: addressText) {
                        isAddressFocused = false
                    } else {
                        NSSound.beep()
                    }
                }
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 5))
                .accessibilityLabel("Website address")

            Group {
                if panel.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Loading page")
                } else {
                    Color.clear
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 16, height: 20)
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .overlay(alignment: .bottom) {
            ChromeColors.separator.frame(height: 1)
        }
    }

    private var connectionIndicator: some View {
        let isSecure = panel.currentURL?.scheme?.lowercased() == "https"
        let label = isSecure ? "Secure HTTPS connection" : "Connection is not HTTPS"

        return Image(systemName: isSecure ? "lock.fill" : "lock.open")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(isSecure ? Color.secondary : Color.secondary.opacity(0.7))
            .accessibilityHidden(true)
            .frame(width: 18, height: 20)
            .help(label)
            .accessibilityLabel(label)
    }

    private var findOverlay: some View {
        HStack(spacing: 4) {
            TextField("Find in page", text: $findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFindFocused)
                .frame(width: 170)
                .onSubmit {
                    panel.find(findQuery, direction: .next)
                }
                .onChange(of: findQuery) { _, query in
                    panel.find(query, direction: .next)
                }
                .accessibilityLabel("Find in page")

            Text(matchCountText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(minWidth: 38, alignment: .trailing)
                .accessibilityLabel("Find matches")
                .accessibilityValue(matchCountText)

            chromeButton(
                systemImage: "chevron.up",
                help: "Previous match",
                enabled: panel.findMatchCount > 0,
                action: { panel.find(findQuery, direction: .previous) }
            )
            chromeButton(
                systemImage: "chevron.down",
                help: "Next match",
                enabled: panel.findMatchCount > 0,
                action: { panel.find(findQuery, direction: .next) }
            )
            chromeButton(
                systemImage: "xmark",
                help: "Close find",
                action: dismissFind
            )
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(ChromeColors.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
        .accessibilityElement(children: .contain)
    }

    private var matchCountText: String {
        guard panel.findMatchCount > 0 else { return "0/0" }
        return "\(panel.currentFindMatch)/\(panel.findMatchCount)"
    }

    private func chromeButton(
        systemImage: String,
        help: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        HoverStateView { isHovered in
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.35))
                    .accessibilityHidden(true)
                    .frame(width: 20, height: 20)
                    .background {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                enabled && isHovered
                                    ? ChromeColors.hoveredTabFill
                                    : Color.clear)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .cursor(enabled ? .pointingHand : .arrow)
            .help(help)
            .accessibilityLabel(help)
        }
    }

    private func presentFind() {
        withAnimation(.easeOut(duration: 0.15)) {
            isFindVisible = true
        }
        DispatchQueue.main.async {
            isFindFocused = true
        }
    }

    private func dismissFind() {
        panel.clearFind()
        isFindFocused = false
        withAnimation(.easeOut(duration: 0.15)) {
            isFindVisible = false
        }
        panel.focusWebContent()
    }

    private func applyFocusRequest(_ request: BrowserFocusRequest) {
        guard isActive else { return }
        DispatchQueue.main.async {
            switch request.target {
            case .addressField:
                isAddressFocused = true
            case .webContent:
                panel.focusWebContent()
            }
        }
    }
}

private struct BrowserWebView: NSViewRepresentable {
    let panel: BrowserPanel
    let isActive: Bool

    func makeNSView(context: Context) -> BrowserWKWebView {
        panel.webView
    }

    func updateNSView(_ webView: BrowserWKWebView, context: Context) {
        panel.setWebContentActive(isActive)
    }

    static func dismantleNSView(_ webView: BrowserWKWebView, coordinator: Void) {
        webView.allowsApplicationFocus = false
    }
}
