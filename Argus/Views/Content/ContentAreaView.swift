// ContentAreaView.swift
// Argus

import SwiftUI

struct ContentAreaView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        if let workspace = workspaceManager.selectedWorkspace {
            WorkspaceContentView(workspace: workspace)
                .id(workspace.id)
        } else {
            emptyState
        }
    }
}

extension ContentAreaView {
    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.secondary.opacity(0.5))
                .accessibilityHidden(true)
            Text("No panels open")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Observes a single workspace and renders its tab bar + panel content.
/// This MUST be a separate view with `@ObservedObject` so that changes
/// to `workspace.activePanelId` trigger a re-render.
struct WorkspaceContentView: View {
    @ObservedObject var workspace: Workspace
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        VStack(spacing: 0) {
            TitlebarView()

            TabBarView(workspace: workspace)

            ZStack {
                ForEach(workspace.panelOrder, id: \.self) { tabId in
                    if workspace.panels[tabId]?.panelType == .terminal {
                        let isVisible = tabId == workspace.activeTabId
                        PanelSplitLayoutView(
                            workspace: workspace,
                            tabId: tabId,
                            node: workspace.layout(for: tabId),
                            isVisible: isVisible
                        )
                        .opacity(isVisible ? 1 : 0)
                        .allowsHitTesting(isVisible)
                        .accessibilityHidden(!isVisible)
                    }
                }

                if let tabId = workspace.activeTabId,
                    workspace.panels[tabId]?.panelType != .terminal
                {
                    PanelSplitLayoutView(
                        workspace: workspace,
                        tabId: tabId,
                        node: workspace.layout(for: tabId),
                        isVisible: true
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Recursively renders one top-level tab's pane layout.
struct PanelSplitLayoutView: View {
    @ObservedObject var workspace: Workspace
    let tabId: UUID
    let node: PanelLayoutNode
    let isVisible: Bool
    var path: [PanelLayoutBranch] = []

    var body: some View {
        switch node {
        case .leaf(let panelId):
            if let panel = workspace.panels[panelId] {
                let active = isVisible && panelId == workspace.activePanelId
                PanelContentView(
                    panel: panel,
                    isActive: active,
                    isVisible: isVisible
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if panel.panelType == .terminal {
                        workspace.selectPanel(panelId)
                    }
                }
            }
        case .split(let direction, let ratio, let first, let second):
            GeometryReader { geometry in
                switch direction {
                case .vertical:
                    let availableLength = max(geometry.size.width - 1, 0)
                    HStack(spacing: 0) {
                        child(first, branch: .first)
                            .frame(width: availableLength * ratio)
                        PanelSplitDivider(
                            direction: direction,
                            ratio: ratio,
                            availableLength: availableLength,
                            onChange: setRatio
                        )
                        child(second, branch: .second)
                            .frame(width: availableLength * (1 - ratio))
                    }
                case .horizontal:
                    let availableLength = max(geometry.size.height - 1, 0)
                    VStack(spacing: 0) {
                        child(first, branch: .first)
                            .frame(height: availableLength * ratio)
                        PanelSplitDivider(
                            direction: direction,
                            ratio: ratio,
                            availableLength: availableLength,
                            onChange: setRatio
                        )
                        child(second, branch: .second)
                            .frame(height: availableLength * (1 - ratio))
                    }
                }
            }
        }
    }

    private func child(_ childNode: PanelLayoutNode, branch: PanelLayoutBranch) -> some View {
        PanelSplitLayoutView(
            workspace: workspace,
            tabId: tabId,
            node: childNode,
            isVisible: isVisible,
            path: path + [branch]
        )
    }

    private func setRatio(_ ratio: CGFloat) {
        withTransaction(Transaction(animation: nil)) {
            workspace.setSplitRatio(ratio, for: tabId, at: path)
        }
    }
}

/// One-point split separator with a 12-point invisible direct-manipulation target.
private struct PanelSplitDivider: View {
    let direction: PanelSplitDirection
    let ratio: CGFloat
    let availableLength: CGFloat
    let onChange: (CGFloat) -> Void

    @State private var dragStartRatio: CGFloat?

    var body: some View {
        separator
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(
                        width: direction == .vertical ? 12 : nil,
                        height: direction == .horizontal ? 12 : nil
                    )
                    .contentShape(Rectangle())
                    .cursor(direction == .vertical ? .resizeLeftRight : .resizeUpDown)
                    .gesture(dragGesture)
            }
            .zIndex(1)
    }

    @ViewBuilder
    private var separator: some View {
        if direction == .vertical {
            ChromeColors.separator.frame(width: 1)
        } else {
            ChromeColors.separator.frame(height: 1)
        }
    }

    private var dragGesture: some Gesture {
        // .global: translation must track raw mouse movement, not the divider's own
        // on-screen position — that position moves every time the ratio changes,
        // which would otherwise feed back into the drag and make it oscillate.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard availableLength > 0 else { return }
                if dragStartRatio == nil {
                    dragStartRatio = ratio
                }

                let translation =
                    direction == .vertical
                    ? value.translation.width
                    : value.translation.height
                let minimumPaneLength = min(80, availableLength * 0.5)
                let minimumRatio = minimumPaneLength / availableLength
                let proposedRatio = (dragStartRatio ?? ratio) + translation / availableLength
                let clampedRatio = min(max(proposedRatio, minimumRatio), 1 - minimumRatio)

                withTransaction(Transaction(animation: nil)) {
                    onChange(clampedRatio)
                }
            }
            .onEnded { _ in
                dragStartRatio = nil
            }
    }
}

// MARK: - Panel Content View

struct PanelContentView: View {
    let panel: any Panel
    var isActive: Bool = true
    var isVisible: Bool = true
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        switch panel.panelType {
        case .terminal:
            if let terminalPanel = panel as? TerminalPanel {
                GeometryReader { geometry in
                    TerminalView(
                        surface: terminalPanel.surface,
                        isActive: isActive,
                        isVisible: isVisible,
                        targetSize: geometry.size
                    )
                    // The representable occupies the same structural position
                    // for every tab. Key it by surface so SwiftUI cannot reuse
                    // the previous tab's TerminalNSView for a new surface.
                    .id(terminalPanel.surface.id)
                }
            }
        case .browser:
            if let browserPanel = panel as? BrowserPanel {
                BrowserView(panel: browserPanel, isActive: isActive)
                    .id(browserPanel.id)
            }
        case .file:
            if let filePanel = panel as? FilePanel {
                FilePanelContentView(
                    panel: filePanel,
                    wrapSourceLines: appSettings.wrapSourceLines,
                    openMarkdownInPreview: appSettings.openMarkdownInPreview,
                    openSVGInPreview: appSettings.openSVGInPreview,
                    documentTextSize: appSettings.documentTextSize
                )
                .id(filePanel.id)
            }
        case .gitPreview:
            if let previewPanel = panel as? GitPreviewPanel {
                GitPreviewPanelContentView(
                    panel: previewPanel,
                    initialDiffStyle: appSettings.defaultDiffStyle.argusDiffStyle,
                    initialOverflow: appSettings.defaultDiffOverflow.argusDiffOverflow,
                    documentTextSize: appSettings.documentTextSize
                )
                .id(previewPanel.id)
            }
        }
    }
}
