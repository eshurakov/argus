import SwiftUI

struct SidebarCollapsedWorkspaceSummary: View {
    let workspaceIds: [UUID]
    var showsProjectContext = false
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @EnvironmentObject private var turnCompletionAttentionStore: TurnCompletionAttentionStore
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.sidebarWidthMetrics) private var sidebarMetrics
    @Environment(\.sidebarCollectionContentInset) private var collectionContentInset

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
                    if showsProjectContext, let project = workspaceManager.project(for: selectedWorkspace.id) {
                        SidebarCollapsedProjectSelectionLabel(project: project, workspace: selectedWorkspace)
                            .windowFocusChrome()
                    } else {
                        SidebarCollapsedSelectionLabel(workspace: selectedWorkspace)
                            .windowFocusChrome()
                    }
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
            .padding(.leading, (sidebarMetrics.isCompact ? sidebarMetrics.rowPadding : 26) + collectionContentInset)
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

private struct SidebarCollapsedProjectSelectionLabel: View {
    @ObservedObject var project: Project
    @ObservedObject var workspace: Workspace

    var body: some View {
        Text("Selected: \(project.displayName) / \(workspace.displayTitle)")
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .help("Selected Workspace: \(project.displayName) / \(workspace.displayTitle)")
            .accessibilityLabel("Selected Workspace: \(project.displayName) / \(workspace.displayTitle)")
    }
}
