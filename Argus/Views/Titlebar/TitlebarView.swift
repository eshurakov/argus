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
        .windowFocusChrome()
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
        .task(id: statusRefreshOwner) {
            await refreshSharedStatusForActiveWorkspace()
        }
        .onChange(of: workspaceManager.selectedWorkspaceId) { _, _ in syncWindowTitle() }
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
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isVisible ? Color.primary : Color.secondary)
                    .accessibilityHidden(true)
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
        guard let owner = statusRefreshOwner else { return }
        await gitStatusViewModel.refresh(owner: owner)
    }

    private var statusRefreshOwner: GitStatusSnapshotOwner? {
        _ = workspaceManager.workspaceContextRevision
        guard let workspace = workspaceManager.selectedWorkspace else { return nil }
        let context = gitStatusContext(
            workspace: workspace,
            project: workspaceManager.project(for: workspace.id)
        )

        return gitStatusViewModel.owner(
            workspaceId: workspace.id,
            context: context,
            presentation: GitStatusPresentation(
                combineWorkingChangeSections: appSettings.combineWorkingChangeSections,
                showBaseBranchChanges: appSettings.showBaseBranchChanges,
                configuredBaseBranch: context.configuredBaseBranch
            )
        )
    }

    private var currentWindowTitle: String {
        workspaceManager.activeWorkspaceTitle
    }

    private func titleContext(for workspace: Workspace, project: Project?) -> String {
        if let project, !project.isCatchAll {
            return project.displayName
        }

        return workspaceManager.activeWorkspaceContextName(for: workspace)
    }
}
