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
    @Environment(\.sidebarWidthMetrics) private var sidebarMetrics
    @Environment(WindowFocusState.self) private var windowFocus
    let globalIndex: Int
    let shortcutDigit: Int?
    let isSelected: Bool
    let onSelect: () -> Void
    var stackRelationship: WorkspaceStackRow? = nil
    var showsStackGutter = false
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
            HStack(spacing: sidebarMetrics.rowSpacing) {
                if let stackRelationship, showsStackGutter {
                    SidebarStackGutter(branch: stackRelationship.branch, lane: stackRelationship.lane)
                }
                if sidebarMetrics.isCompact {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: sidebarMetrics.rowSpacing) {
                            workspaceIcon
                            workspaceLabels
                        }
                        runningProcessBadge
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                } else {
                    workspaceIcon
                    workspaceLabels
                    Spacer(minLength: 0)
                    runningProcessBadge
                }
            }
            .padding(.horizontal, sidebarMetrics.rowPadding)
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
                    .opacity(isSelected ? (windowFocus.isKeyWindow ? 1 : 0.5) : 0)
                    .accessibilityHidden(true)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(focusColor, lineWidth: isFocused && windowFocus.isKeyWindow ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .cursor(.pointingHand)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(workspaceHelp)
        .accessibilityLabel(workspaceAccessibilityLabel)
        .accessibilityValue(workspaceAccessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var workspaceLabels: some View {
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
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var runningProcessBadge: some View {
        if runningProcessCount > 0 || sidebarMetrics.isCompact {
            CountBadge(count: runningProcessCount)
                .fixedSize()
                .opacity(runningProcessCount > 0 ? 1 : 0)
                .allowsHitTesting(runningProcessCount > 0)
                .accessibilityHidden(runningProcessCount == 0)
                .help(runningProcessCountAccessibilityText)
        }
    }

    @ViewBuilder
    private var workspaceIcon: some View {
        ZStack {
            if hasAttention {
                Image(systemName: "bell.fill")
                    .font(.system(size: 11, weight: .semibold))
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
                    .windowFocusChrome()
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
                    .windowFocusChrome()
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
        return stackRelationship?.branch ?? workspace.branchName
    }

    private var workspaceSubtitleHelp: String {
        if workspace.workspaceType == .external {
            return workspace.currentDirectory
        }
        return stackRelationship?.branch ?? workspace.branchName ?? ""
    }

    private var workspaceHelp: String {
        let action = "Select \(workspace.displayTitle)"
        guard let stackRelationship else { return action }
        return "\(action). \(stackRelationship.sidebarRelationshipDescription)"
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(windowFocus.isKeyWindow ? 0.16 : 0.10)
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
        if let branch = stackRelationship?.branch ?? workspace.branchName {
            parts.append("branch \(branch)")
        }
        if let stackRelationship {
            parts.append(stackRelationship.sidebarRelationshipDescription)
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

struct SidebarCollapsedWorkspaceSummary: View {
    let workspaceIds: [UUID]
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @EnvironmentObject private var turnCompletionAttentionStore: TurnCompletionAttentionStore
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.sidebarWidthMetrics) private var sidebarMetrics

    private var selectedWorkspace: Workspace? {
        guard let workspace = workspaceManager.selectedWorkspace,
            workspaceIds.contains(workspace.id)
        else { return nil }
        return workspace
    }

    private var hasAttention: Bool {
        workspaceIds.contains { turnCompletionAttentionStore.workspaceHasAttention($0) }
    }

    var body: some View {
        if selectedWorkspace != nil || hasAttention {
            VStack(alignment: .leading, spacing: 2) {
                if let selectedWorkspace {
                    SidebarCollapsedSelectionLabel(workspace: selectedWorkspace)
                        .windowFocusChrome()
                }
                if hasAttention {
                    Label("Unviewed completion", systemImage: "bell.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help("One or more hidden Workspaces have Turn Completion Attention")
                        .accessibilityLabel("Turn Completion Attention in hidden Workspaces")
                }
            }
            .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 10)))
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(.leading, sidebarMetrics.isCompact ? sidebarMetrics.rowPadding : 26)
            .padding(.trailing, sidebarMetrics.rowPadding)
            .padding(.bottom, 4)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct SidebarCollapsedSelectionLabel: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        Text("Selected: \(workspace.displayTitle)")
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .help("Selected Workspace: \(workspace.displayTitle)")
            .accessibilityLabel("Selected Workspace: \(workspace.displayTitle)")
    }
}
