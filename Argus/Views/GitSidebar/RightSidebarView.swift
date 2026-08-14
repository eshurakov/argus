import AppKit
import Foundation
import SwiftUI

extension AppSettings.RightSidebarView {
    fileprivate var systemImage: String {
        switch self {
        case .files:
            "doc"
        case .changes:
            "arrow.triangle.branch"
        }
    }
}

struct RightSidebarView: View {
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @EnvironmentObject private var gitStatusViewModel: GitStatusViewModel
    @EnvironmentObject private var appSettings: AppSettings
    @StateObject private var filesViewModel = WorkspaceFilesViewModel()
    @State private var selectedPanel: AppSettings.RightSidebarView = .changes
    @State private var hasAppliedDefaultPanel = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ZStack {
                WorkspaceFilesView(
                    viewModel: filesViewModel,
                    workspaceId: workspaceManager.selectedWorkspace?.id,
                    rootPath: workspaceManager.selectedWorkspace?.currentDirectory,
                    showHiddenFiles: appSettings.showHiddenFiles
                )
                .opacity(selectedPanel == .files ? 1 : 0)
                .allowsHitTesting(selectedPanel == .files)
                .accessibilityHidden(selectedPanel != .files)

                GitSidebarView()
                    .opacity(selectedPanel == .changes ? 1 : 0)
                    .allowsHitTesting(selectedPanel == .changes)
                    .accessibilityHidden(selectedPanel != .changes)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ChromeColors.shellBackground)
        .onChange(of: filesRequest, initial: true) { _, request in
            filesViewModel.activate(request: request)
        }
        .onAppear {
            guard !hasAppliedDefaultPanel else { return }
            selectedPanel = appSettings.defaultRightSidebarView
            hasAppliedDefaultPanel = true
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(AppSettings.RightSidebarView.allCases) { panel in
                tabButton(panel)
            }

            Spacer(minLength: 0)

            ZStack {
                if selectedPanel == .files, filesViewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else if selectedPanel == .changes, gitStatusViewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 12, height: 12)

            HoverStateView { isHovered in
                Button {
                    Task { await refreshSelectedPanel() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                        .frame(width: 20, height: 20)
                        .background {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(canRefresh && isHovered ? ChromeColors.hoveredTabFill : Color.clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canRefresh)
                .cursor(canRefresh ? .pointingHand : .arrow)
                .help(selectedPanel == .files ? "Refresh files" : "Refresh changes")
                .accessibilityLabel(selectedPanel == .files ? "Refresh files" : "Refresh changes")
                .accessibilityValue(isRefreshActive ? "Refreshing" : "")
            }
            .padding(.trailing, 12)
        }
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            ChromeColors.separator.frame(height: 1)
        }
    }

    private func tabButton(_ panel: AppSettings.RightSidebarView) -> some View {
        let isSelected = selectedPanel == panel

        return Button {
            selectedPanel = panel
        } label: {
            HStack(spacing: 8) {
                Image(systemName: panel.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .accessibilityHidden(true)
                    .frame(width: 18)
                Text(panel.title)
                    .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 14), weight: .semibold))

                if panel == .changes, let count = changesCount, count > 0 {
                    CountBadge(count: count, prominent: isSelected)
                }
            }
            .foregroundColor(isSelected ? .primary : .secondary)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(isSelected ? ChromeColors.activeTabFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .help(panel.title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var isRefreshActive: Bool {
        switch selectedPanel {
        case .files:
            return filesViewModel.isRefreshing
        case .changes:
            return gitStatusViewModel.isRefreshing
        }
    }

    private var canRefresh: Bool {
        guard !isRefreshActive else { return false }
        switch selectedPanel {
        case .files:
            return filesRequest != nil
        case .changes:
            return workspaceManager.selectedWorkspace != nil
        }
    }

    private var filesRequest: WorkspaceFileTreeRequest? {
        _ = workspaceManager.workspaceContextRevision
        guard let workspace = workspaceManager.selectedWorkspace else { return nil }
        return WorkspaceFileTreeRequest(
            workspaceId: workspace.id,
            rootPath: workspace.currentDirectory,
            showHiddenFiles: appSettings.showHiddenFiles
        )
    }

    private var changesCount: Int? {
        guard case .loaded(let summary) = gitStatusViewModel.state else { return nil }
        return summary.totalFileCount
    }

    private func refreshSelectedPanel() async {
        switch selectedPanel {
        case .files:
            await refreshFiles()
        case .changes:
            await refreshChanges()
        }
    }

    private func refreshFiles() async {
        guard let filesRequest else {
            filesViewModel.reset()
            return
        }
        await filesViewModel.refresh(request: filesRequest)
    }

    private func refreshChanges() async {
        guard let workspace = workspaceManager.selectedWorkspace else { return }
        let context = gitStatusContext(
            workspace: workspace,
            project: workspaceManager.project(for: workspace.id)
        )
        await gitStatusViewModel.refresh(
            workspaceId: workspace.id,
            context: context,
            presentation: GitStatusPresentation(
                combineWorkingChangeSections: appSettings.combineWorkingChangeSections,
                showBaseBranchChanges: appSettings.showBaseBranchChanges,
                configuredBaseBranch: context.configuredBaseBranch
            )
        )
    }
}
