import AppKit
import SwiftUI

extension Notification.Name {
    static let showPullRequestStatus = Notification.Name("ArgusShowPullRequestStatus")
}

enum SidebarWorkspaceIcon: Equatable {
    case attention
    case agent(AgentStatusState)
    case pullRequest
    case workspaceType

    init(hasAttention: Bool, agentState: AgentStatusState?, showsPullRequestStatus: Bool) {
        if hasAttention {
            self = .attention
        } else if let agentState, agentState != .idle {
            self = .agent(agentState)
        } else if showsPullRequestStatus {
            self = .pullRequest
        } else if let agentState {
            self = .agent(agentState)
        } else {
            self = .workspaceType
        }
    }
}

enum PullRequestStatusSignal: Equatable {
    case failedChecks
    case changesRequested
    case pendingChecks
    case approved
    case unavailable
    case stale

    var symbolName: String {
        switch self {
        case .failedChecks: "exclamationmark.circle.fill"
        case .changesRequested: "bubble.left.and.exclamationmark.bubble.right"
        case .pendingChecks: "clock"
        case .approved: "checkmark.circle"
        case .unavailable: "questionmark.circle"
        case .stale: "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .failedChecks: .red
        case .approved: .green
        case .changesRequested, .pendingChecks, .unavailable, .stale: .orange
        }
    }
}

extension PullRequestLifecycle {
    var symbolName: String {
        switch self {
        case .open: "arrow.triangle.branch"
        case .draft: "circle.dotted"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .open: .green
        case .draft: .secondary
        case .merged: .purple
        case .closed: .red
        }
    }
}

struct PullRequestStatusPresentation {
    let state: WorkspacePullRequestState
    let date: Date

    var showsIcon: Bool {
        state.status != nil || state.error != nil
    }

    var isStale: Bool { state.isStale(at: date) }

    var signal: PullRequestStatusSignal? {
        guard let status = state.status else { return nil }
        if isStale { return .stale }
        guard status.lifecycle == .open || status.lifecycle == .draft else { return nil }
        if status.checks.state == .failed { return .failedChecks }
        if status.review == .changesRequested { return .changesRequested }
        if status.checks.state == .pending { return .pendingChecks }
        if status.checks.state == .unknown || status.review == .unavailable { return .unavailable }
        return status.review == .approved ? .approved : nil
    }

    var title: String {
        if let status = state.status { return "#\(status.identity.number) · \(status.lifecycle.label)" }
        if state.error != nil { return "Pull Request status unavailable" }
        return state.hasLoaded ? "No Pull Request" : "Pull Request not checked"
    }

    var help: String {
        var parts = [title]
        if let status = state.status {
            parts += [status.title, status.review.label, status.checks.summary]
        }
        if isStale { parts.append("Stale") }
        if let error = state.error { parts.append(error.localizedDescription) }
        if let date = state.lastSuccess {
            parts.append("Last checked \(date.formatted(date: .abbreviated, time: .standard))")
        }
        return parts.joined(separator: ". ")
    }

    var canRefresh: Bool {
        guard !state.isRefreshing else { return false }
        if let deadline = state.error?.pauseDeadline, deadline > date { return false }
        return true
    }
}

struct PullRequestStatusIcon: View {
    let presentation: PullRequestStatusPresentation
    let onInspect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onInspect) {
            icon
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered ? ChromeColors.hoveredTabFill : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { isHovered = $0 }
        .help("Show Pull Request status. " + presentation.help)
        .accessibilityLabel("Show Pull Request status")
        .accessibilityValue(presentation.help)
        .opacity(presentation.showsIcon ? 1 : 0)
        .allowsHitTesting(presentation.showsIcon)
        .accessibilityHidden(!presentation.showsIcon)
    }

    @ViewBuilder
    private var icon: some View {
        if let signal = presentation.signal {
            Image(systemName: signal.symbolName)
                .foregroundStyle(signal.color)
                .accessibilityHidden(true)
        } else if let status = presentation.state.status {
            Image(systemName: status.lifecycle.symbolName)
                .foregroundStyle(status.lifecycle.color)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

struct PullRequestStatusSummary: View {
    let workspaceID: UUID
    let onOpen: () -> Void
    let onClose: () -> Void
    @State private var showsRefreshProgress = false
    @EnvironmentObject private var model: WorkspacePullRequestStatusModel
    @EnvironmentObject private var workspaceManager: WorkspaceManager

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = model.state(for: workspaceID) ?? WorkspacePullRequestState()
            let presentation = PullRequestStatusPresentation(state: state, date: context.date)
            VStack(alignment: .leading, spacing: 10) {
                header(presentation)
                if let status = state.status {
                    loadedContent(status, presentation: presentation)
                } else if state.error == nil {
                    Text(state.hasLoaded ? "No matching Pull Request for this branch." : "Status has not loaded yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if let error = state.error {
                    Text(error.localizedDescription)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                freshness(state)
                actions(presentation)
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
        }
        .onReceive(model.$states) { states in
            if showsRefreshProgress, states[workspaceID]?.isRefreshing != true {
                showsRefreshProgress = false
            }
        }
        .onDisappear { showsRefreshProgress = false }
        .onChange(of: workspaceID) { _, _ in showsRefreshProgress = false }
        .onExitCommand(perform: onClose)
    }

    private func header(_ presentation: PullRequestStatusPresentation) -> some View {
        HStack(spacing: 8) {
            if let status = presentation.state.status {
                Image(systemName: status.lifecycle.symbolName)
                    .foregroundStyle(status.lifecycle.color)
                    .accessibilityHidden(true)
            }
            Text(presentation.title).font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            HoverStateView { isHovered in
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .frame(width: 20, height: 20)
                        .background(isHovered ? ChromeColors.hoveredTabFill : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .help("Close Pull Request status")
                .accessibilityLabel("Close Pull Request status")
            }
        }
    }

    private func loadedContent(
        _ status: PullRequestStatus, presentation: PullRequestStatusPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(3)
                .textSelection(.enabled)
            Text("Review: \(status.review.label)").font(.system(size: 12))
            Text("Checks: \(status.checks.summary)").font(.system(size: 12))
            if presentation.isStale {
                Label("Stale — showing last known status", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func freshness(_ state: WorkspacePullRequestState) -> some View {
        if let date = state.lastSuccess {
            Text("Last checked \(date.formatted(date: .abbreviated, time: .standard))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func actions(_ presentation: PullRequestStatusPresentation) -> some View {
        HStack(spacing: 8) {
            if let status = presentation.state.status {
                Button("Open Pull Request") {
                    onOpen()
                    workspaceManager.openPullRequest(status, in: workspaceID)
                }
                .help("Open Pull Request in the default system browser")
                Button("Copy URL") { PullRequestStatusActions.copyURL(status.url) }
            }
            Spacer(minLength: 0)
            if showsRefreshProgress && presentation.state.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel("Refreshing Pull Request status")
            }
            Button("Refresh") {
                model.refresh(workspaceID: workspaceID)
                showsRefreshProgress = model.state(for: workspaceID)?.isRefreshing == true
            }
            .disabled(!presentation.canRefresh || !model.isActive)
            .help("Refresh Pull Request status")
        }
        .controlSize(.small)
    }
}

struct PullRequestStatusMenuItems: View {
    let workspaceID: UUID
    @EnvironmentObject private var model: WorkspacePullRequestStatusModel
    @EnvironmentObject private var workspaceManager: WorkspaceManager

    var body: some View {
        let state = model.state(for: workspaceID) ?? WorkspacePullRequestState()
        Button("Show Pull Request Status") {
            NotificationCenter.default.post(name: .showPullRequestStatus, object: workspaceID)
        }
        Button("Refresh Pull Request Status") { model.refresh(workspaceID: workspaceID) }
            .disabled(!PullRequestStatusPresentation(state: state, date: .now).canRefresh || !model.isActive)
        if let status = state.status {
            Button("Open Pull Request") { workspaceManager.openPullRequest(status, in: workspaceID) }
                .help("Open Pull Request in the default system browser")
            Button("Copy Pull Request URL") { PullRequestStatusActions.copyURL(status.url) }
        }
    }
}

@MainActor
private enum PullRequestStatusActions {
    static func copyURL(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}
