import SwiftUI

// MARK: - SidebarWorkspaceRow

/// Individual workspace row showing type icon, display title, branch name,
/// and running-process count badge. A Command-held overlay may replace the
/// icon with the reachable Workspace shortcut digit without changing layout.
struct SidebarWorkspaceRow: View {
    @ObservedObject var workspace: Workspace
    @EnvironmentObject var agentStatusStore: AgentStatusStore
    @EnvironmentObject var turnCompletionAttentionStore: TurnCompletionAttentionStore
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.isCommandKeyHeld) private var isCommandKeyHeld
    let globalIndex: Int
    let shortcutDigit: Int?
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        // Ghostty only exposes process liveness as a query, so re-evaluate the
        // badge on a short interval instead of inventing a second process model.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            workspaceRowButton
        }
    }

    private var workspaceRowButton: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                workspaceIcon

                // Title and Workspace context
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.displayTitle)
                        .font(
                            .system(
                                size: appSettings.presentationMetrics.textSize(forBaseSize: 13),
                                weight: isSelected ? .semibold : .regular
                            )
                        )
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let subtitle = workspaceSubtitle {
                        Text(subtitle)
                            .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 10)))
                            .foregroundColor(.secondary.opacity(workspace.workspaceType == .external ? 0.55 : 1))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(workspaceSubtitleHelp)
                    }
                }

                Spacer()

                // Running-process count badge (shown when any Terminal Surface is busy)
                if runningProcessCount > 0 {
                    Text("\(runningProcessCount)")
                        .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 10)))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                        .help(runningProcessCountAccessibilityText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, appSettings.presentationMetrics.workspaceRowVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
            )
            // Selection reads as a leading accent indicator so the row keeps
            // sidebar contrast instead of inverting to a filled accent block.
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 2)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
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

    @ViewBuilder
    private var workspaceIcon: some View {
        ZStack {
            if hasAttention {
                Image(systemName: "bell.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.orange)
                    .opacity(showsShortcutOverlay ? 0 : 1)
                    .accessibilityHidden(true)
            } else if let agentStatus {
                Image(systemName: agentStatus.state.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(agentStatus.state.color)
                    .opacity(showsShortcutOverlay ? 0 : 1)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: workspace.workspaceType.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .opacity(showsShortcutOverlay ? 0 : 1)
                    .accessibilityHidden(true)
            }

            if let shortcutDigit, showsShortcutOverlay {
                Text("\(shortcutDigit)")
                    .font(
                        .system(
                            size: appSettings.presentationMetrics.textSize(forBaseSize: 10),
                            weight: .semibold,
                            design: .monospaced
                        )
                    )
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 14)
    }

    private var showsShortcutOverlay: Bool {
        isCommandKeyHeld && shortcutDigit != nil
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

    private var runningProcessCount: Int {
        workspace.runningProcessCount
    }

    private var runningProcessCountAccessibilityText: String {
        runningProcessCount == 1
            ? "1 running process"
            : "\(runningProcessCount) running processes"
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
            return Color.accentColor.opacity(0.16)
        } else if isHovered || isFocused {
            return ChromeColors.hoveredTabFill
        } else {
            return Color.clear
        }
    }

    private var focusColor: Color {
        Color.accentColor
    }

    private var workspaceAccessibilityLabel: String {
        var parts = ["Workspace \(globalIndex)", workspace.displayTitle, workspace.workspaceType.label]
        if let branch = workspace.branchName {
            parts.append("branch \(branch)")
        }
        if workspace.workspaceType == .external {
            parts.append("directory \(workspace.currentDirectory)")
        }
        if runningProcessCount > 0 {
            parts.append(runningProcessCountAccessibilityText)
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
