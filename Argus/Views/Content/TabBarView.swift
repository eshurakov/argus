// TabBarView.swift
// Argus
//
// Per-workspace tab bar displayed at the top of the content area.
// Shows one tab per panel in tab order, with a close button
// and a "+" button to add a new terminal tab.

import SwiftUI
import UniformTypeIdentifiers

struct TabBarView: View {
    @ObservedObject var workspace: Workspace
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @EnvironmentObject var agentStatusStore: AgentStatusStore
    @EnvironmentObject var turnCompletionAttentionStore: TurnCompletionAttentionStore
    @EnvironmentObject private var appSettings: AppSettings

    @State private var renamePanelId: UUID?
    @State private var renameText = ""
    @State private var showRenameAlert = false

    var body: some View {
        HStack(spacing: 0) {
            // Scrollable tab strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(workspace.panelOrder, id: \.self) { panelId in
                        if let panel = workspace.panels[panelId] {
                            TabItemView(
                                panel: panel,
                                title: workspace.tabDisplayTitle(for: panelId),
                                agentStatus: agentStatus(for: panelId),
                                hasAttention: turnCompletionAttentionStore.hasAttention(
                                    workspaceId: workspace.id,
                                    tabId: panelId
                                ),
                                isActive: panelId == workspace.activeTabId,
                                onSelect: { workspaceManager.focusPanel(panelId) },
                                onRename: panel.panelType == .terminal
                                    ? {
                                        renamePanelId = panelId
                                        renameText = workspace.tabDisplayTitle(for: panelId)
                                        showRenameAlert = true
                                    } : nil,
                                canMoveLeft: workspace.panelOrder.first != panelId,
                                canMoveRight: workspace.panelOrder.last != panelId,
                                onMoveLeft: {
                                    guard let index = workspace.panelOrder.firstIndex(of: panelId),
                                        index > 0
                                    else { return }
                                    workspace.reorderPanel(from: index, to: index - 1)
                                },
                                onMoveRight: {
                                    guard let index = workspace.panelOrder.firstIndex(of: panelId),
                                        index < workspace.panelOrder.count - 1
                                    else { return }
                                    workspace.reorderPanel(from: index, to: index + 1)
                                },
                                onClose: {
                                    workspaceManager.requestCloseTab(panelId, in: workspace.id)
                                }
                            )
                            .environmentObject(appSettings)
                            .onDrag {
                                PanelTabDragState.draggedPanelId = panelId
                                return NSItemProvider(object: panelId.uuidString as NSString)
                            }
                            .onDrop(
                                of: [UTType.text],
                                delegate: PanelTabDropDelegate(
                                    workspace: workspace,
                                    targetPanelId: panelId
                                )
                            )
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer()

            // New top-level tab menu
            HoverStateView { isHovered in
                Menu {
                    Button("New Terminal Tab") {
                        workspace.addTerminalPanel()
                    }
                    Button("New Browser Tab") {
                        workspaceManager.addBrowserTab()
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .background {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isHovered ? ChromeColors.hoveredTabFill : Color.clear)
                        }
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .cursor(.pointingHand)
                .help("Add tab")
                .accessibilityLabel("Add tab")
            }
            .padding(.trailing, 8)
        }
        .frame(height: 30)
        .background(ChromeColors.shellBackground)
        .overlay(alignment: .bottom) {
            ChromeColors.separator.frame(height: 1)
        }
        .alert("Rename Terminal", isPresented: $showRenameAlert) {
            TextField("Terminal title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let renamePanelId {
                    workspace.renameTerminalPanel(renamePanelId, title: renameText)
                }
            }
        }
    }

    private func agentStatus(for tabId: UUID) -> AgentStatusEntry? {
        let terminalSurfaceIds = workspace.layout(for: tabId).leaves.filter {
            workspace.panels[$0]?.panelType == .terminal
        }
        if !terminalSurfaceIds.isEmpty {
            return agentStatusStore.workspaceSummary(
                workspaceId: workspace.id,
                terminalSurfaceIds: terminalSurfaceIds,
                includesNonterminalPanels: false
            )
        }
        return agentStatusStore.effectiveStatus(workspaceId: workspace.id)
    }
}

// MARK: - Tab Drag and Drop

@MainActor
private enum PanelTabDragState {
    static var draggedPanelId: UUID?
}

private struct PanelTabDropDelegate: DropDelegate {
    let workspace: Workspace
    let targetPanelId: UUID

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedPanelId = PanelTabDragState.draggedPanelId else { return false }
        defer { PanelTabDragState.draggedPanelId = nil }
        guard draggedPanelId != targetPanelId,
            let source = workspace.panelOrder.firstIndex(of: draggedPanelId),
            let destination = workspace.panelOrder.firstIndex(of: targetPanelId)
        else { return false }

        workspace.reorderPanel(from: source, to: destination)
        return true
    }
}

// MARK: - Tab Item

struct TabItemView: View {
    let panel: any Panel
    let title: String
    let agentStatus: AgentStatusEntry?
    let hasAttention: Bool
    let isActive: Bool
    let onSelect: () -> Void
    let onRename: (() -> Void)?
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void
    let onClose: () -> Void
    @EnvironmentObject private var appSettings: AppSettings

    @State private var isHovered = false
    @State private var isCloseHovered = false

    private var tabFill: Color {
        if isActive { return ChromeColors.activeTabFill }
        if isHovered { return ChromeColors.hoveredTabFill }
        return Color.clear
    }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onSelect) {
                HStack(spacing: 4) {
                    // Fixed icon slot keeps tab geometry stable while the
                    // loading, attention, and Agent Status states change.
                    Group {
                        if panel.isLoading {
                            ProgressView()
                                .controlSize(.mini)
                                .accessibilityLabel("Loading \(title)")
                        } else if hasAttention {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                                .accessibilityHidden(true)
                        } else if let agentStatus {
                            Image(systemName: agentStatus.state.symbolName)
                                .font(.system(size: 10))
                                .foregroundColor(agentStatus.state.color)
                                .accessibilityHidden(true)
                        } else if let icon = panel.displayIcon {
                            Image(systemName: icon)
                                .font(.system(size: 10))
                                .foregroundColor(isActive ? .primary : .secondary)
                        }
                    }
                    .frame(width: 14, height: 14)

                    Text(title)
                        .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 12)))
                        .foregroundColor(isActive ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 140)
                }
                .padding(.leading, 8)
                .frame(minHeight: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help("Select \(title)")
            .accessibilityLabel(title)
            .accessibilityValue(tabAccessibilityValue)
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityActions {
                if canMoveLeft {
                    Button("Move Left", action: onMoveLeft)
                }
                if canMoveRight {
                    Button("Move Right", action: onMoveRight)
                }
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 20)
                    .background {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isCloseHovered ? ChromeColors.hoveredTabFill : Color.clear)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help("Close \(title)")
            .accessibilityLabel("Close \(title)")
            .onHover { isCloseHovered = $0 }
        }
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(tabFill)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Close", role: .destructive, action: onClose)
            if let onRename {
                Button("Rename", action: onRename)
            }
        }
    }

    private var tabAccessibilityValue: String {
        var values = [isActive ? "Selected" : "Not selected"]
        if hasAttention {
            values.append("Agent turn completed")
        }
        if let agentStatus {
            values.append("Agent status: \(agentStatus.state.label)")
        }
        return values.joined(separator: ", ")
    }
}
