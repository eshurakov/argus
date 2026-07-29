// TitlebarView.swift
// Argus
//
// Compact Center Content Area titlebar showing the active workspace context.
// It is placed inside the Center Content Area so the system traffic-light row
// collapses into the app chrome instead of reserving a full-width strip.

import AppKit
import SwiftUI

struct TitlebarView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @EnvironmentObject private var gitStatusViewModel: GitStatusViewModel
    @EnvironmentObject private var sidebarState: SidebarState
    @EnvironmentObject private var gitSidebarState: GitSidebarState
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            sidebarToggle(
                systemImage: "sidebar.left",
                sidebarName: "left sidebar",
                isVisible: sidebarState.isVisible
            ) {
                NotificationCenter.default.post(name: .toggleSidebar, object: nil)
            }
            // Traffic lights occupy the leading titlebar only when the Left Sidebar is hidden.
            .padding(.leading, sidebarState.isVisible ? 8 : 72)

            Group {
                if let workspace = workspaceManager.selectedWorkspace {
                    let project = workspaceManager.project(for: workspace.id)
                    let gitContext = gitStatusViewModel.titlebarGitContext(for: workspace.id)

                    Text(titleContext(for: workspace, project: project))
                        .font(
                            .system(size: appSettings.presentationMetrics.textSize(forBaseSize: 14), weight: .semibold)
                        )
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text("/")
                        .font(
                            .system(size: appSettings.presentationMetrics.textSize(forBaseSize: 14), weight: .semibold)
                        )
                        .foregroundColor(.secondary)

                    Text(workspace.displayTitle)
                        .font(
                            .system(size: appSettings.presentationMetrics.textSize(forBaseSize: 14), weight: .semibold)
                        )
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let gitContext {
                        Text(gitContext.visibleText)
                            .font(
                                .system(
                                    size: appSettings.presentationMetrics.textSize(forBaseSize: 13),
                                    weight: .medium,
                                    design: .monospaced
                                )
                            )
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    Text(WorkspaceTitleFormatter.fallbackTitle)
                        .font(
                            .system(size: appSettings.presentationMetrics.textSize(forBaseSize: 14), weight: .semibold)
                        )
                        .foregroundColor(.primary)
                }
            }
            .allowsHitTesting(false)

            Spacer(minLength: 0)

            sidebarToggle(
                systemImage: "sidebar.right",
                sidebarName: "right sidebar",
                isVisible: gitSidebarState.isVisible
            ) {
                NotificationCenter.default.post(name: .toggleGitSidebar, object: nil)
            }
            .padding(.trailing, 8)
        }
        .frame(height: 44)
        .background {
            ChromeColors.shellBackground
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            ChromeColors.separator
                .frame(height: 1)
                .allowsHitTesting(false)
        }
        .onAppear(perform: syncWindowTitle)
        .task(id: workspaceManager.selectedWorkspaceId) {
            await refreshSharedStatusForActiveWorkspace()
        }
        .onChange(of: workspaceManager.selectedWorkspaceId) { _, _ in syncWindowTitle() }
        .onChange(of: gitStatusViewModel.state) { _, _ in syncWindowTitle() }
        .onChange(of: gitStatusViewModel.stateWorkspaceId) { _, _ in syncWindowTitle() }
    }

    private func sidebarToggle(
        systemImage: String,
        sidebarName: String,
        isVisible: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let actionName = isVisible ? "Hide \(sidebarName)" : "Show \(sidebarName)"

        return HoverStateView { isHovered in
            Button(action: action) {
                SemanticIcon(name: systemImage, pointSize: 13, weight: .medium)
                    .foregroundColor(isVisible ? .primary : .secondary)
                    .frame(width: 24, height: 24)
                    .background {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isHovered ? ChromeColors.hoveredTabFill : Color.clear)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help(actionName)
            .accessibilityLabel(actionName)
            .accessibilityValue(isVisible ? "Visible" : "Hidden")
        }
    }

    private func syncWindowTitle() {
        NSApp.mainWindow?.title = currentWindowTitle
    }

    private func refreshSharedStatusForActiveWorkspace() async {
        guard let workspace = workspaceManager.selectedWorkspace,
            gitStatusViewModel.stateWorkspaceId != workspace.id,
            let context = statusContext(for: workspace)
        else { return }

        await gitStatusViewModel.refresh(workspaceId: workspace.id, context: context)
    }

    private func statusContext(for workspace: Workspace) -> GitStatusRootContext? {
        let project = workspaceManager.project(for: workspace.id)
        let projectRepositoryPath = project?.isCatchAll == false ? project?.repositoryPath : nil

        let kind: GitStatusRootContext.WorkspaceKind
        switch workspace.workspaceType {
        case .worktree:
            kind = .worktree
        case .mainCheckout:
            kind = .mainCheckout
        case .external:
            kind = .standalone
        }

        return GitStatusRootContext(
            kind: kind,
            currentDirectory: workspace.currentDirectory,
            worktreePath: workspace.worktreePath,
            projectRepositoryPath: projectRepositoryPath
        )
    }

    private var currentWindowTitle: String {
        guard let workspace = workspaceManager.selectedWorkspace else {
            return WorkspaceTitleFormatter.fallbackTitle
        }

        let gitContext = gitStatusViewModel.titlebarGitContext(for: workspace.id)
        guard gitContext != nil else { return workspaceManager.activeWorkspaceTitle }

        return WorkspaceTitleFormatter.title(
            workspaceTitle: workspace.displayTitle,
            contextName: workspaceManager.activeWorkspaceContextName(for: workspace),
            gitContext: gitContext?.windowTitleText
        )
    }

    private func titleContext(for workspace: Workspace, project: Project?) -> String {
        if let project, !project.isCatchAll {
            return project.displayName
        }

        return workspaceManager.activeWorkspaceContextName(for: workspace)
    }
}
