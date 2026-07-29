// MainWindowView.swift
// Argus
//
// Root view for the main window. Three-column layout with draggable dividers:
// left sidebar | content area | right side panel.

import SwiftUI

private struct NewWorkspaceSheetRequest: Identifiable {
    let id = UUID()
    let projectId: UUID
}

private func closeWorkspaceMessage(
    title: String,
    worktreePath: String,
    requestedByLastTerminalTab: Bool,
    canDeleteWorktree: Bool
) -> String {
    guard requestedByLastTerminalTab else {
        return "Do you also want to delete the git worktree for \(title) at \(worktreePath)?"
    }
    var message =
        "Closing the last terminal tab will close \(title). Do you want to close the workspace?"
    if canDeleteWorktree {
        message += " You can also delete its git worktree at \(worktreePath)."
    }
    return message
}

extension WorkspaceDeletionStage {
    fileprivate var title: String {
        switch self {
        case .removingWorktree:
            "Removing Git worktree"
        case .closingWorkspace:
            "Closing workspace"
        }
    }

    fileprivate var detail: String {
        switch self {
        case .removingWorktree:
            "Git is unregistering the worktree and deleting its files. Large worktrees can take longer."
        case .closingWorkspace:
            "Closing terminal panels and updating workspace state."
        }
    }
}

private struct WorkspaceDeletionProgressView: View {
    let stage: WorkspaceDeletionStage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(stage.title)
                    .font(.headline)
            }

            Text(stage.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                ForEach(WorkspaceDeletionStage.allCases, id: \.self) { item in
                    HStack(spacing: 8) {
                        SemanticIcon(name: stageIcon(for: item), pointSize: 12, weight: .medium)
                            .frame(width: 16)
                            .foregroundStyle(
                                item.rawValue <= stage.rawValue ? Color.accentColor : Color.secondary
                            )
                        Text(item.title)
                            .font(.system(size: 12))
                            .foregroundStyle(
                                item.rawValue <= stage.rawValue ? Color.primary : Color.secondary
                            )
                    }
                }
            }
        }
        .frame(width: 360, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(ChromeColors.shellBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Deleting worktree. \(stage.title). \(stage.detail)")
        .accessibilityAddTraits(.isModal)
    }

    private func stageIcon(for item: WorkspaceDeletionStage) -> String {
        if item.rawValue < stage.rawValue {
            return "checkmark.circle.fill"
        }
        if item == stage {
            return "circle.inset.filled"
        }
        return "circle"
    }
}

struct MainWindowView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @ObservedObject private var ghosttyApp = GhosttyApp.shared
    @StateObject private var sidebarState = SidebarState()
    @StateObject private var gitSidebarState = GitSidebarState()
    @StateObject private var gitStatusViewModel = GitStatusViewModel()

    // MARK: - Sheet State

    @State private var showNewProjectSheet = false
    @State private var newWorkspaceSheetRequest: NewWorkspaceSheetRequest?
    @State private var showOrphanedWorktreesSheet = false
    @State private var orphanedWorktrees: [OrphanedWorktreeInfo] = []
    @State private var showRenameProjectAlert = false
    @State private var renameProjectId: UUID?
    @State private var renameProjectText = ""
    @State private var showRenameWorkspaceAlert = false
    @State private var renameWorkspaceId: UUID?
    @State private var renameWorkspaceText = ""
    @State private var showCloseWorkspaceConfirmation = false
    @State private var closeWorkspaceId: UUID?
    @State private var closeWorkspaceTitle = ""
    @State private var closeWorkspaceWorktreePath = ""
    @State private var closeWorkspaceRequestedByLastTerminalTab = false
    @State private var closeWorkspaceCanDeleteWorktree = false
    @State private var closeWorkspaceConfirmationMessage = ""
    @State private var workspaceDeletionStage: WorkspaceDeletionStage?
    @State private var showWorkspaceDeletionError = false
    @State private var workspaceDeletionErrorMessage = ""
    @State private var windowWidth: CGFloat = 600

    var body: some View {
        GeometryReader { geometry in
            let leftMaxWidth = SidebarLayout.liveLeftMaxWidth(
                windowWidth: geometry.size.width,
                rightWidth: gitSidebarState.width,
                rightVisible: gitSidebarState.isVisible
            )
            let rightMaxWidth = SidebarLayout.liveRightMaxWidth(
                windowWidth: geometry.size.width,
                leftWidth: sidebarState.width,
                leftVisible: sidebarState.isVisible
            )

            HStack(spacing: 0) {
                // Left sidebar
                if sidebarState.isVisible {
                    SidebarView()
                        .frame(width: sidebarState.width)
                    SidebarDivider(
                        position: $sidebarState.width,
                        minValue: min(SidebarLayout.leftMinWidth, leftMaxWidth),
                        maxValue: leftMaxWidth
                    )
                }

                // Content area fills remaining space and draws into the
                // transparent titlebar, matching the compact cmux-style chrome.
                ContentAreaView()
                    .frame(
                        minWidth: SidebarLayout.centerMinWidth,
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                    .background(ChromeColors.shellBackground)

                // Right side panel
                if gitSidebarState.isVisible {
                    GitSidebarDivider(
                        position: $gitSidebarState.width,
                        minValue: min(SidebarLayout.rightMinWidth, rightMaxWidth),
                        maxValue: rightMaxWidth
                    )
                    RightSidebarView()
                        .frame(width: gitSidebarState.width)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .onAppear {
                windowWidth = geometry.size.width
                clampSidebarWidths(windowWidth: geometry.size.width)
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                windowWidth = newWidth
                clampSidebarWidths(windowWidth: newWidth)
            }
        }
        .frame(minWidth: 600, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .background(ChromeColors.shellBackground)
        .overlay {
            if let workspaceDeletionStage {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()

                    WorkspaceDeletionProgressView(stage: workspaceDeletionStage)
                }
            }
        }
        .environmentObject(sidebarState)
        .environmentObject(gitSidebarState)
        .environmentObject(gitStatusViewModel)
        .environment(\.colorScheme, ghosttyApp.chromePalette.isDark ? .dark : .light)
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            sidebarState.toggle()
            clampSidebarWidths(windowWidth: windowWidth)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleGitSidebar)) { _ in
            gitSidebarState.toggle()
            clampSidebarWidths(windowWidth: windowWidth)
        }
        // Sheet: New Project
        .sheet(isPresented: $showNewProjectSheet) {
            NewProjectSheet()
                .environmentObject(workspaceManager)
        }
        // Sheet: New Workspace
        .sheet(item: $newWorkspaceSheetRequest) { request in
            NewWorkspaceSheet(projectId: request.projectId)
                .environmentObject(workspaceManager)
        }
        // Sheet: Orphaned Worktrees
        .sheet(isPresented: $showOrphanedWorktreesSheet) {
            OrphanedWorktreesSheet(orphans: orphanedWorktrees)
                .environmentObject(workspaceManager)
        }
        // Alert: Rename Project
        .alert("Rename Project", isPresented: $showRenameProjectAlert) {
            TextField("Project name", text: $renameProjectText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let id = renameProjectId {
                    workspaceManager.renameProject(id, name: renameProjectText)
                }
            }
        }
        // Alert: Rename Workspace
        .alert("Rename Workspace", isPresented: $showRenameWorkspaceAlert) {
            TextField("Workspace name", text: $renameWorkspaceText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let id = renameWorkspaceId {
                    workspaceManager.renameWorkspace(id, title: renameWorkspaceText)
                }
            }
        }
        // Alert: Close Workspace with optional worktree deletion
        .alert("Close Workspace?", isPresented: $showCloseWorkspaceConfirmation) {
            Button(closeWorkspaceRequestedByLastTerminalTab ? "Keep Terminal" : "Cancel", role: .cancel) {}
            Button(closeWorkspaceCanDeleteWorktree ? "Close Only" : "Close Workspace", role: .destructive) {
                if let id = closeWorkspaceId {
                    workspaceManager.removeWorkspace(id)
                }
            }
            if closeWorkspaceCanDeleteWorktree {
                Button("Delete Worktree and Close", role: .destructive) {
                    if let id = closeWorkspaceId {
                        workspaceDeletionStage = .removingWorktree
                        Task {
                            let removed = await workspaceManager.removeWorkspace(
                                id,
                                deletingWorktree: true,
                                onProgress: { stage in
                                    workspaceDeletionStage = stage
                                }
                            )
                            workspaceDeletionStage = nil
                            if !removed {
                                workspaceDeletionErrorMessage =
                                    workspaceManager.lastWorkspaceDeletionError?.localizedDescription
                                    ?? "The worktree could not be deleted. The workspace was not closed."
                                showWorkspaceDeletionError = true
                            }
                        }
                    }
                }
            }
        } message: {
            Text(closeWorkspaceConfirmationMessage)
        }
        .alert("Could Not Delete Worktree", isPresented: $showWorkspaceDeletionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspaceDeletionErrorMessage)
        }
        // Notification receivers for sheet/alert triggers
        .onReceive(NotificationCenter.default.publisher(for: .showNewProjectSheet)) { _ in
            showNewProjectSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showNewWorkspaceSheet)) { notification in
            if let projectId = notification.userInfo?["projectId"] as? UUID {
                newWorkspaceSheetRequest = NewWorkspaceSheetRequest(projectId: projectId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showRenameProjectSheet)) { notification in
            if let projectId = notification.userInfo?["projectId"] as? UUID,
                let project = workspaceManager.projects.first(where: { $0.id == projectId })
            {
                renameProjectId = projectId
                renameProjectText = project.displayName
                showRenameProjectAlert = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showRenameWorkspaceSheet)) { notification in
            if let workspaceId = notification.userInfo?["workspaceId"] as? UUID,
                let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId })
            {
                renameWorkspaceId = workspaceId
                renameWorkspaceText = workspace.displayTitle
                showRenameWorkspaceAlert = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCloseWorkspaceConfirmation)) { notification in
            if let workspaceId = notification.userInfo?["workspaceId"] as? UUID,
                let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId })
            {
                closeWorkspaceId = workspaceId
                closeWorkspaceTitle = workspace.displayTitle
                closeWorkspaceWorktreePath = workspace.worktreePath ?? ""
                closeWorkspaceRequestedByLastTerminalTab =
                    notification.userInfo?["requestedByLastTerminalTab"] as? Bool ?? false
                closeWorkspaceCanDeleteWorktree =
                    workspaceManager.shouldConfirmWorktreeDeletionBeforeClosing(workspaceId)
                closeWorkspaceConfirmationMessage = closeWorkspaceMessage(
                    title: closeWorkspaceTitle,
                    worktreePath: closeWorkspaceWorktreePath,
                    requestedByLastTerminalTab: closeWorkspaceRequestedByLastTerminalTab,
                    canDeleteWorktree: closeWorkspaceCanDeleteWorktree
                )
                showCloseWorkspaceConfirmation = true
            }
        }
        .task {
            await detectOrphanedWorktrees()
        }
    }

    /// Scans for orphaned worktrees on launch and shows the dialog if any are found.
    private func detectOrphanedWorktrees() async {
        var allOrphans: [OrphanedWorktreeInfo] = []

        for project in workspaceManager.namedProjects {
            let knownPaths = Set(
                workspaceManager.workspaces
                    .filter { $0.projectId == project.id }
                    .compactMap(\.worktreePath)
            )
            let orphans = workspaceManager.worktreeService.detectOrphanedWorktrees(
                projectId: project.id,
                knownWorkspacePaths: knownPaths
            )
            allOrphans.append(contentsOf: orphans)
        }

        if !allOrphans.isEmpty {
            orphanedWorktrees = allOrphans
            showOrphanedWorktreesSheet = true
        }
    }

    private func clampSidebarWidths(windowWidth: CGFloat) {
        let widths = SidebarLayout.clampWidths(
            leftWidth: sidebarState.width,
            rightWidth: gitSidebarState.width,
            windowWidth: windowWidth,
            leftVisible: sidebarState.isVisible,
            rightVisible: gitSidebarState.isVisible
        )
        if sidebarState.width != widths.left {
            sidebarState.width = widths.left
        }
        if gitSidebarState.width != widths.right {
            gitSidebarState.width = widths.right
        }
    }
}
