import SwiftUI

// MARK: - SidebarWorkspaceRow

/// Individual workspace row showing global index, type icon, display title,
/// branch name, and panel count badge.
struct SidebarWorkspaceRow: View {
    @ObservedObject var workspace: Workspace
    @EnvironmentObject var agentStatusStore: AgentStatusStore
    @EnvironmentObject var turnCompletionAttentionStore: TurnCompletionAttentionStore
    @EnvironmentObject private var appSettings: AppSettings
    let globalIndex: Int
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // 1-based global index (for Cmd+N shortcut reference)
                Text("\(globalIndex)")
                    .font(
                        .system(
                            size: appSettings.presentationMetrics.textSize(forBaseSize: 10),
                            weight: .medium,
                            design: .monospaced
                        )
                    )
                    .foregroundColor(.secondary)
                    .frame(width: 16)

                if hasAttention {
                    SemanticIcon(name: "bell.fill", pointSize: 11, weight: .bold)
                        .foregroundColor(.orange)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                } else if let agentStatus {
                    SemanticIcon(name: agentStatus.state.symbolName, pointSize: 11, weight: .semibold)
                        .frame(width: 14)
                        .foregroundColor(agentStatus.state.color)
                        .accessibilityHidden(true)
                } else {
                    SemanticIcon(name: workspace.workspaceType.icon, pointSize: 11, weight: .semibold)
                        .foregroundColor(isSelected ? .white : .secondary)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                }

                // Title and Workspace context
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.displayTitle)
                        .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 13)))
                        .foregroundColor(isSelected ? .white : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let subtitle = workspaceSubtitle {
                        Text(subtitle)
                            .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 10)))
                            .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(workspaceSubtitleHelp)
                    }
                }

                Spacer()

                // Panel count badge (shown when > 1 tab)
                if workspace.panelCount > 1 {
                    Text("\(workspace.panelCount)")
                        .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 10)))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, appSettings.presentationMetrics.workspaceRowVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(focusColor, lineWidth: isFocused ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .cursor(.pointingHand)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(workspaceAccessibilityLabel)
        .accessibilityValue(workspaceAccessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var agentStatus: AgentStatusEntry? {
        let panels = Array(workspace.panels.values)
        return agentStatusStore.workspaceSummary(
            workspaceId: workspace.id,
            terminalSurfaceIds: panels.filter { $0.panelType == .terminal }.map(\.id),
            includesNonterminalPanels: panels.contains { $0.panelType != .terminal }
        )
    }

    private var hasAttention: Bool {
        turnCompletionAttentionStore.workspaceHasAttention(workspace.id)
    }

    private var workspaceSubtitle: String? {
        if workspace.workspaceType == .external {
            return WorkspacePathFormatter.abbreviatedPath(workspace.currentDirectory)
        }
        return workspace.branchName
    }

    private var workspaceSubtitleHelp: String {
        workspace.workspaceType == .external ? workspace.currentDirectory : workspace.branchName ?? ""
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor
        } else if isHovered || isFocused {
            return Color.secondary.opacity(0.1)
        } else {
            return Color.clear
        }
    }

    private var focusColor: Color {
        isSelected ? Color.white.opacity(0.7) : Color.accentColor
    }

    private var workspaceAccessibilityLabel: String {
        var parts = ["Workspace \(globalIndex)", workspace.displayTitle, workspace.workspaceType.label]
        if let branch = workspace.branchName {
            parts.append("branch \(branch)")
        }
        if workspace.workspaceType == .external {
            parts.append("directory \(workspace.currentDirectory)")
        }
        if workspace.panelCount > 1 {
            parts.append("\(workspace.panelCount) tabs")
        }
        return parts.joined(separator: ", ")
    }

    private var workspaceAccessibilityValue: String {
        var values = [isSelected ? "Selected" : "Not selected"]
        if hasAttention {
            values.append("One or more tabs need attention")
        }
        if let agentStatus {
            values.append("Agent status: \(agentStatus.state.label)")
        }
        return values.joined(separator: ", ")
    }
}
