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
    @EnvironmentObject private var pullRequestStatusModel: WorkspacePullRequestStatusModel
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @Environment(\.isCommandKeyHeld) private var isCommandKeyHeld
    @Environment(\.sidebarWidthMetrics) private var sidebarMetrics
    @Environment(\.sidebarCollectionContentInset) private var collectionContentInset
    @Environment(WindowFocusState.self) private var windowFocus
    let globalIndex: Int
    let shortcutDigit: Int?
    let isSelected: Bool
    let onSelect: () -> Void
    var stackRelationship: WorkspaceStackRow?
    var showsStackGutter = false
    @State private var isHovered = false
    @State private var showsPullRequestSummary = false
    @State private var summaryReturnFocus = SummaryReturnFocus.icon
    @FocusState private var isFocused: Bool
    @FocusState private var isPullRequestIconFocused: Bool

    private enum SummaryReturnFocus {
        case icon
        case row
        case none
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ZStack(alignment: workspaceIconAlignment) {
                workspaceRowButton
                if showsPullRequestIcon {
                    PullRequestStatusIcon(
                        presentation: PullRequestStatusPresentation(state: pullRequestState, date: context.date)
                    ) {
                        summaryReturnFocus = .icon
                        showsPullRequestSummary = true
                    }
                    .focused($isPullRequestIconFocused)
                }
            }
        }
        .popover(isPresented: $showsPullRequestSummary, arrowEdge: .trailing) {
            PullRequestStatusSummary(
                workspaceID: workspace.id,
                onOpen: {
                    summaryReturnFocus = .none
                    showsPullRequestSummary = false
                },
                onClose: { showsPullRequestSummary = false }
            )
        }
        .onChange(of: showsPullRequestSummary) { _, isShown in
            guard !isShown else { return }
            switch summaryReturnFocus {
            case .icon:
                if showsPullRequestIcon {
                    isPullRequestIconFocused = true
                } else {
                    isFocused = true
                }
            case .row: isFocused = true
            case .none: break
            }
        }
        .onChange(of: showsPullRequestIcon) { _, isShown in
            if !isShown, isPullRequestIconFocused, !showsPullRequestSummary { isFocused = true }
        }
        .onChange(of: showsPullRequestStatus) { _, isShown in
            if !isShown { showsPullRequestSummary = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPullRequestStatus)) { notification in
            guard notification.object as? UUID == workspace.id, showsPullRequestStatus else { return }
            summaryReturnFocus = .row
            showsPullRequestSummary = true
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
                }
            }
            .padding(.leading, collectionContentInset)
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
            HStack(spacing: 4) {
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
                if !sidebarMetrics.isCompact {
                    Spacer(minLength: 0)
                    runningProcessBadge
                }
            }
            if let subtitle = workspaceSubtitle ?? (showsPullRequestStatus ? "" : nil) {
                Text(subtitle)
                    .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 10)))
                    .foregroundColor(.secondary.opacity(workspace.workspaceType == .external ? 0.55 : 1))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(workspaceSubtitleHelp)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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

}

extension SidebarWorkspaceRow {
    private var showsPullRequestStatus: Bool {
        appSettings.showPullRequestStatus && workspace.workspaceType == .worktree
            && workspace.worktreePath?.isEmpty == false
            && workspaceManager.project(for: workspace.id)?.isCatchAll == false
    }

    private var pullRequestState: WorkspacePullRequestState {
        pullRequestStatusModel.state(for: workspace.id) ?? WorkspacePullRequestState()
    }

    private var workspaceIconKind: SidebarWorkspaceIcon {
        SidebarWorkspaceIcon(
            hasAttention: hasAttention,
            agentState: agentStatus?.state,
            showsPullRequestStatus: showsPullRequestStatus
                && PullRequestStatusPresentation(state: pullRequestState, date: .now).showsIcon
        )
    }

    private var showsPullRequestIcon: Bool {
        workspaceIconKind == .pullRequest && !showsShortcutOverlay
    }

    private var workspaceIconAlignment: Alignment {
        Alignment(
            horizontal: HorizontalAlignment(SidebarWorkspaceIconHorizontalAlignment.self),
            vertical: VerticalAlignment(SidebarWorkspaceIconVerticalAlignment.self)
        )
    }

    private var workspaceIcon: some View {
        ZStack {
            Group {
                switch workspaceIconKind {
                case .attention:
                    Image(systemName: "bell.fill")
                        .foregroundStyle(.orange)
                case .agent(let state):
                    Image(systemName: state.symbolName)
                        .foregroundStyle(state.color)
                case .pullRequest:
                    Color.clear
                case .workspaceType:
                    Image(systemName: workspace.workspaceType.icon)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .windowFocusChrome()
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .opacity(showsShortcutOverlay ? 0 : 1)

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
            }
        }
        .frame(width: 20, height: 20)
        .alignmentGuide(workspaceIconAlignment.horizontal) { $0[HorizontalAlignment.center] }
        .alignmentGuide(workspaceIconAlignment.vertical) { $0[VerticalAlignment.center] }
        .accessibilityHidden(true)
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
        if showsPullRequestStatus {
            if let branch = pullRequestState.branchName { return branch }
            if pullRequestState.hasLoaded, pullRequestState.error != nil { return "Branch unavailable" }
        }
        return stackRelationship?.branch ?? workspace.branchName
    }

    private var workspaceSubtitleHelp: String {
        workspace.workspaceType == .external ? workspace.currentDirectory : workspaceSubtitle ?? ""
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
        if workspace.workspaceType != .external, let branch = workspaceSubtitle {
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
        if showsPullRequestStatus, !showsPullRequestIcon {
            values.append(PullRequestStatusPresentation(state: pullRequestState, date: .now).help)
        }
        return values.joined(separator: ", ")
    }
}

private enum SidebarWorkspaceIconHorizontalAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
        context[HorizontalAlignment.center]
    }
}

private enum SidebarWorkspaceIconVerticalAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
        context[VerticalAlignment.center]
    }
}
