import SwiftUI

extension SidebarView {
    var body: some View {
        GeometryReader { geometry in
            sidebarContent
                .environment(\.sidebarWidthMetrics, SidebarWidthMetrics(width: geometry.size.width))
        }
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            // Header with title and global add buttons
            SidebarHeader()
                .windowFocusChrome()

            // Project sections
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(workspaceManager.namedProjects, id: \.id) { project in
                            ProjectSection(project: project)
                        }

                        if let catchAll = workspaceManager.catchAllProject {
                            WorkspacesSectionHeader()
                                .windowFocusChrome()
                            ProjectSection(project: catchAll, showsHeader: false)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .onChange(of: workspaceManager.workspaceRevealRevision) { _, revision in
                    let workspaceId = workspaceManager.selectedWorkspaceId
                    Task { @MainActor in
                        await Task.yield()
                        guard let workspaceId,
                            workspaceManager.workspaceRevealRevision == revision,
                            workspaceManager.selectedWorkspaceId == workspaceId
                        else { return }
                        proxy.scrollTo(workspaceId)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(ChromeColors.shellBackground)
        .environment(\.isCommandKeyHeld, commandKeyMonitor.isCommandHeld)
        .onAppear { commandKeyMonitor.start() }
        .onDisappear { commandKeyMonitor.stop() }
    }
}

// MARK: - Sidebar Header

/// Top header with "Projects" label and a New Project action.
private struct SidebarHeader: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.sidebarWidthMetrics) private var sidebarMetrics

    var body: some View {
        HStack(spacing: sidebarMetrics.isCompact ? 2 : nil) {
            Text("Projects")
                .font(
                    .system(
                        size: appSettings.presentationMetrics.textSize(forBaseSize: 11),
                        weight: .semibold
                    )
                )
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            SidebarSectionAddButton(
                help: "New Project",
                accessibilityLabel: "New Project"
            ) {
                NotificationCenter.default.post(name: .showNewProjectSheet, object: nil)
            }
        }
        .padding(.horizontal, sidebarMetrics.isCompact ? 6 : 12)
        .padding(.vertical, 8)
        .padding(.top, 28)  // Space for titlebar traffic lights
    }
}

// MARK: - Workspaces Section Header

/// Top-level section header for the Catch-all Project, matching Projects.
private struct WorkspacesSectionHeader: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.sidebarWidthMetrics) private var sidebarMetrics

    var body: some View {
        HStack(spacing: sidebarMetrics.isCompact ? 2 : nil) {
            Text("Workspaces")
                .font(
                    .system(
                        size: appSettings.presentationMetrics.textSize(forBaseSize: 11),
                        weight: .semibold
                    )
                )
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            SidebarSectionAddButton(
                help: "New Workspace",
                accessibilityLabel: "New Workspace"
            ) {
                workspaceManager.addWorkspace()
            }
        }
        .padding(.horizontal, sidebarMetrics.isCompact ? 2 : 4)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - Section Add Button

/// Compact plus control used by the Projects and Workspaces section headers.
private struct SidebarSectionAddButton: View {
    let help: String
    let accessibilityLabel: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .frame(width: 20, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isHovered ? ChromeColors.hoveredTabFill : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .cursor(.pointingHand)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .onHover { isHovered = $0 }
    }
}

struct SidebarStackDiscoveryStatus: View {
    let projectId: UUID
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            if workspaceManager.refreshingWorkspaceStackProjectIds.contains(projectId) {
                ProgressView()
                    .controlSize(.mini)
                    .help("Refreshing local Stacks")
                    .accessibilityLabel("Refreshing Stacks")
            } else if let error = workspaceManager.workspaceStackErrors[projectId] {
                Button {
                    workspaceManager.refreshWorkspaceStacks(in: projectId)
                } label: {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isHovered || isFocused ? ChromeColors.hoveredTabFill : Color.clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($isFocused)
                .onHover { isHovered = $0 }
                .cursor(.pointingHand)
                .help("Stack discovery issue: \(error)\nRetry Stack discovery")
                .accessibilityLabel("Retry Stack discovery")
                .accessibilityValue(error)
            } else {
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 20, height: 20)
    }
}
