// swiftlint:disable file_length
// MainWindowView.swift
// Argus
// Root three-column Workspace window.

import AppKit
import SwiftUI

private struct NewWorkspaceSheetRequest: Identifiable {
    let id = UUID()
    let projectId: UUID
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
                        Image(systemName: stageIcon(for: item))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(item.rawValue <= stage.rawValue ? Color.accentColor : Color.secondary)
                            .accessibilityHidden(true)
                            .frame(width: 16)
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

struct MainWindowView: View {  // swiftlint:disable:this type_body_length
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @ObservedObject private var ghosttyApp = GhosttyApp.shared
    @StateObject private var sidebarState = SidebarState()
    @StateObject private var gitSidebarState = GitSidebarState()
    @StateObject private var gitStatusViewModel = GitStatusViewModel()
    @StateObject private var rightSidebarSessionState = RightSidebarSessionState()

    // MARK: - Sheet State

    @State private var showNewProjectSheet = false
    @State private var newWorkspaceSheetRequest: NewWorkspaceSheetRequest?
    @State private var changeWorkspaceRootSheetRequest: ChangeWorkspaceRootSheetRequest?
    @State private var showOrphanedWorktreesSheet = false
    @State private var orphanedWorktrees: [OrphanedWorktreeInfo] = []
    @State private var showRenameProjectAlert = false
    @State private var renameProjectId: UUID?
    @State private var renameProjectText = ""
    @State private var showRenameWorkspaceAlert = false
    @State private var renameWorkspaceId: UUID?
    @State private var renameWorkspaceText = ""
    @State private var closeWorkspaceRequest: CloseWorkspaceRequest?
    @State private var runningProcessRequest: RunningProcessCloseRequest?
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
            if let closeWorkspaceRequest {
                CloseWorkspaceConfirmationView(
                    request: closeWorkspaceRequest,
                    onCancel: { self.closeWorkspaceRequest = nil },
                    onCloseOnly: { closeWorkspace(closeWorkspaceRequest) },
                    onDeleteWorktree: { deleteWorktreeAndCloseWorkspace(closeWorkspaceRequest.id) }
                )
            } else if let runningProcessRequest {
                RunningProcessConfirmationView(
                    request: runningProcessRequest,
                    onCancel: { cancelRunningProcessClose(runningProcessRequest) },
                    onConfirm: { confirmRunningProcessClose(runningProcessRequest) }
                )
            } else if let workspaceDeletionStage {
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
        .environmentObject(rightSidebarSessionState)
        .onChange(of: workspaceIDs, initial: true) { _, ids in
            rightSidebarSessionState.retainWorkspaces(ids)
        }
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
        .changeWorkspaceRootSheet(
            request: $changeWorkspaceRootSheetRequest,
            workspaceManager: workspaceManager
        )
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
                let requestedByLastTerminalTab =
                    notification.userInfo?["requestedByLastTerminalTab"] as? Bool ?? false
                closeWorkspaceRequest = CloseWorkspaceRequest(
                    id: workspaceId,
                    title: workspace.displayTitle,
                    worktreePath: workspace.worktreePath ?? "",
                    requestedByLastTerminalTab: requestedByLastTerminalTab,
                    canDeleteWorktree:
                        workspaceManager.shouldConfirmWorktreeDeletionBeforeClosing(workspaceId),
                    runningProcessCount: workspace.runningProcessCount
                )
                runningProcessRequest = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showRunningProcessConfirmation)) { notification in
            guard let request = notification.object as? RunningProcessCloseRequest else { return }
            runningProcessRequest = request
            if case .application = request.scope {
                closeWorkspaceRequest = nil
            }
        }
        .task {
            await detectOrphanedWorktrees()
        }
    }

    private func closeWorkspace(_ request: CloseWorkspaceRequest) {
        guard closeWorkspaceRequest == request else { return }
        closeWorkspaceRequest = nil
        workspaceManager.removeWorkspace(request.id)
    }

    private func cancelRunningProcessClose(_ request: RunningProcessCloseRequest) {
        guard runningProcessRequest == request else { return }
        runningProcessRequest = nil
        if case .application = request.scope {
            NotificationCenter.default.post(name: .cancelApplicationQuit, object: nil)
        }
    }

    private func confirmRunningProcessClose(_ request: RunningProcessCloseRequest) {
        guard runningProcessRequest == request else { return }
        runningProcessRequest = nil
        switch request.scope {
        case .pane(let workspaceId, let panelId):
            workspaceManager.requestClosePane(
                panelId,
                in: workspaceId,
                confirmingRunningProcess: true
            )
        case .tab(let workspaceId, let tabId):
            workspaceManager.requestCloseTab(
                tabId,
                in: workspaceId,
                confirmingRunningProcess: true
            )
        case .surface(_, let surfaceId):
            workspaceManager.completeSurfaceClose(surfaceId)
        case .application:
            NotificationCenter.default.post(name: .confirmApplicationQuit, object: nil)
        }
    }

    private func deleteWorktreeAndCloseWorkspace(_ workspaceId: UUID) {
        guard closeWorkspaceRequest?.id == workspaceId else { return }
        closeWorkspaceRequest = nil
        workspaceDeletionStage = .removingWorktree
        Task {
            let removed = await workspaceManager.removeWorkspace(
                workspaceId,
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

    private var workspaceIDs: Set<UUID> {
        Set(workspaceManager.workspaces.map(\.id))
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
