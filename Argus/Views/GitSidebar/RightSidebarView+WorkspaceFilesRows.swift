// Row rendering and Workspace Item Operations for the Files View share this
// view's private state, so they stay in one file rather than widening access.
// swiftlint:disable file_length
import Foundation
import SwiftUI

struct WorkspaceFilesView: View {
    @ObservedObject var viewModel: WorkspaceFilesViewModel
    let workspaceId: UUID?
    let rootPath: String?
    let showHiddenFiles: Bool
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject private var sessionState: RightSidebarSessionState
    @State private var autoRefreshController = WorkspaceFilesAutoRefreshController()
    @State private var selectedItemId: String?
    @State private var selectedItemPath: String?
    @State private var pendingDeletion: WorkspaceItemDeletionRequest?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(request)
            .task(id: request) {
                selectedItemId = nil
                selectedItemPath = nil
                pendingDeletion = nil
                guard let request else {
                    autoRefreshController.stop()
                    viewModel.reset()
                    return
                }
                autoRefreshController.start(rootPath: request.rootPath) {
                    await viewModel.refresh(request: request)
                }
                await restoreExpandedDirectories(request: request)
            }
            .onDisappear {
                autoRefreshController.stop()
            }
            .overlay {
                if let pendingDeletion {
                    WorkspaceItemDeletionConfirmation(
                        request: pendingDeletion,
                        onCancel: { self.pendingDeletion = nil },
                        onConfirm: { confirmWorkspaceItemDeletion(pendingDeletion) }
                    )
                }
            }
    }
}

extension WorkspaceFilesView {
    func fileTreeRows(_ snapshot: WorkspaceFileTreeSnapshot) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(
                    WorkspaceFileTree.visibleRows(
                        nodes: snapshot.nodes,
                        expandedDirectoryIds: expandedDirectoryIds
                    )
                ) { row in
                    switch row.content {
                    case .directory(let directory):
                        VStack(spacing: 0) {
                            workspaceDirectoryRow(
                                directory,
                                depth: row.depth,
                                rootPath: snapshot.rootPath
                            )
                            if expandedDirectoryIds.contains(directory.id),
                                let error = viewModel.directoryErrors[directory.path]
                            {
                                directoryLoadError(
                                    error,
                                    directory: directory,
                                    depth: row.depth,
                                    rootPath: snapshot.rootPath
                                )
                            }
                        }
                    case .file(let file):
                        workspaceFileRow(file, depth: row.depth, rootPath: snapshot.rootPath)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func workspaceDirectoryRow(
        _ directory: WorkspaceFileTreeNode,
        depth: Int,
        rootPath: String
    ) -> some View {
        let isExpanded = expandedDirectoryIds.contains(directory.id)
        let isLoading = viewModel.loadingDirectoryPaths.contains(directory.path)
        let isSelected = selectedItemId == directory.id

        return HoverStateView { isHovered in
            Button {
                selectDirectory(directory)
                toggleWorkspaceDirectory(directory, rootPath: rootPath)
            } label: {
                workspaceDirectoryLabel(
                    directory,
                    isExpanded: isExpanded,
                    isLoading: isLoading,
                    isSelected: isSelected
                )
            }
            .buttonStyle(.plain)
            .padding(.leading, workspaceTreeRowLeadingPadding(depth: depth))
            .padding(.trailing, 12)
            .padding(.vertical, appSettings.presentationMetrics.treeRowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.16)
                            : (isHovered ? ChromeColors.hoveredTabFill : Color.clear))
            }
            .cursor(.pointingHand)
            .contextMenu {
                workspaceDirectoryContextMenu(directory, rootPath: rootPath)
            }
            .help(directory.path)
            .accessibilityLabel("\(directory.name) folder")
            .accessibilityValue(
                [isSelected ? "Selected" : nil, isExpanded ? "Expanded" : "Collapsed"]
                    .compactMap { $0 }
                    .joined(separator: ", ")
            )
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private func workspaceDirectoryLabel(
        _ directory: WorkspaceFileTreeNode,
        isExpanded: Bool,
        isLoading: Bool,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
                .frame(width: 12)
            ZStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 14)
            Text(directory.name)
                .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 11)))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func workspaceFileRow(
        _ file: WorkspaceFileTreeNode,
        depth: Int,
        rootPath: String
    ) -> some View {
        let isSelected = selectedItemId == file.id

        return HoverStateView { isHovered in
            Button {
                selectFile(file)
            } label: {
                workspaceFileLabel(file, isSelected: isSelected)
            }
            .buttonStyle(.plain)
            .padding(.leading, workspaceTreeRowLeadingPadding(depth: depth) + 19)
            .padding(.trailing, 12)
            .padding(.vertical, appSettings.presentationMetrics.treeRowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.16)
                            : (isHovered ? ChromeColors.hoveredTabFill : Color.clear))
            }
            .cursor(.pointingHand)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    openWorkspaceFile(file, rootPath: rootPath)
                }
            )
            .contextMenu {
                workspaceFileContextMenu(file, rootPath: rootPath)
            }
            .help(file.path)
            .accessibilityLabel(file.path)
            .accessibilityValue(isSelected ? "Selected" : "")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private func workspaceFileLabel(
        _ file: WorkspaceFileTreeNode,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: WorkspaceFileIcon.systemName(for: file.name))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
                .frame(width: 14)
            Text(file.name)
                .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 11)))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func selectWorkspaceItem(_ item: WorkspaceFileTreeNode) {
        selectedItemId = item.id
        selectedItemPath = item.path
    }

    private func selectDirectory(_ directory: WorkspaceFileTreeNode) {
        selectWorkspaceItem(directory)
    }

    private func selectFile(_ file: WorkspaceFileTreeNode) {
        selectWorkspaceItem(file)
    }

    private var expandedDirectoryIds: Set<String> {
        guard let request else { return [] }
        return sessionState.expandedDirectoryIds(
            workspaceId: request.workspaceId,
            rootPath: request.rootPath
        )
    }

    private func toggleWorkspaceDirectory(_ directory: WorkspaceFileTreeNode, rootPath: String) {
        guard let initiatingRequest = request,
            initiatingRequest.rootPath == rootPath
        else {
            return
        }
        if expandedDirectoryIds.contains(directory.id) {
            sessionState.collapseDirectory(
                directory.id,
                workspaceId: initiatingRequest.workspaceId,
                rootPath: initiatingRequest.rootPath
            )
        } else {
            openWorkspaceDirectory(directory, rootPath: rootPath)
        }
    }

    func openWorkspaceDirectory(_ directory: WorkspaceFileTreeNode, rootPath: String) {
        guard let initiatingRequest = request,
            initiatingRequest.rootPath == rootPath
        else {
            return
        }
        selectDirectory(directory)
        sessionState.expandDirectory(
            directory.id,
            workspaceId: initiatingRequest.workspaceId,
            rootPath: initiatingRequest.rootPath
        )
        Task {
            await viewModel.loadChildren(request: initiatingRequest, directoryPath: directory.path)
        }
    }

    private func restoreExpandedDirectories(request: WorkspaceFileTreeRequest) async {
        await viewModel.refresh(request: request)
        for directoryPath in WorkspaceFileTree.directoryPaths(fromExpandedIds: expandedDirectoryIds) {
            await viewModel.loadChildren(request: request, directoryPath: directoryPath)
        }
    }

    func openWorkspaceFile(_ file: WorkspaceFileTreeNode, rootPath: String) {
        guard let initiatingRequest = request,
            initiatingRequest.rootPath == rootPath
        else {
            return
        }
        selectFile(file)
        guard
            let sourceWorkspace = workspaceManager.workspaces.first(where: {
                $0.id == initiatingRequest.workspaceId
            })
        else {
            return
        }
        sourceWorkspace.openFilePanel(
            rootPath: rootPath,
            relativePath: file.path
        )
    }

    func copyWorkspaceItem(_ item: WorkspaceFileTreeNode, rootPath: String) {
        selectWorkspaceItem(item)
        viewModel.copyFile(rootPath: rootPath, path: item.path)
    }

    func copyWorkspaceItemRelativePath(_ item: WorkspaceFileTreeNode) {
        selectWorkspaceItem(item)
        viewModel.copyRelativePath(item.path)
    }

    func requestWorkspaceItemDeletion(
        _ item: WorkspaceFileTreeNode,
        rootPath: String,
        initiatingRequest: WorkspaceFileTreeRequest
    ) {
        guard initiatingRequest.rootPath == rootPath else { return }
        selectWorkspaceItem(item)
        pendingDeletion = WorkspaceItemDeletionRequest(
            item: item,
            rootPath: rootPath,
            initiatingRequest: initiatingRequest
        )
    }

    private func confirmWorkspaceItemDeletion(_ deletion: WorkspaceItemDeletionRequest) {
        guard pendingDeletion == deletion else { return }
        pendingDeletion = nil
        Task {
            await deleteWorkspaceItem(
                deletion.item,
                rootPath: deletion.rootPath,
                initiatingRequest: deletion.initiatingRequest
            )
        }
    }

    func deleteWorkspaceItem(
        _ item: WorkspaceFileTreeNode,
        rootPath: String,
        initiatingRequest: WorkspaceFileTreeRequest
    ) async {
        guard initiatingRequest.rootPath == rootPath else { return }
        let deleted = await viewModel.deleteFile(
            request: initiatingRequest,
            path: item.path
        )
        guard deleted,
            request == initiatingRequest,
            viewModel.isCurrent(initiatingRequest)
        else {
            return
        }
        if selectedItemPath == item.path {
            selectedItemId = nil
            selectedItemPath = nil
        }
    }

    func renameWorkspaceItem(
        _ item: WorkspaceFileTreeNode,
        rootPath: String,
        initiatingRequest: WorkspaceFileTreeRequest
    ) async {
        guard initiatingRequest.rootPath == rootPath else { return }
        selectWorkspaceItem(item)
        guard
            let newPath = await viewModel.renameFileWithPrompt(
                request: initiatingRequest,
                path: item.path
            )
        else {
            return
        }
        if case .file = item.content,
            let sourceWorkspace = workspaceManager.workspaces.first(where: {
                $0.id == initiatingRequest.workspaceId
            })
        {
            sourceWorkspace.updateOpenFilePanel(
                rootPath: rootPath,
                oldPath: item.path,
                newPath: newPath
            )
        }
        guard request == initiatingRequest,
            viewModel.isCurrent(initiatingRequest)
        else {
            return
        }
        selectedItemId = "\(item.idPrefix):\(newPath)"
        selectedItemPath = newPath
        sessionState.setExpandedDirectoryIds(
            [],
            workspaceId: initiatingRequest.workspaceId,
            rootPath: initiatingRequest.rootPath
        )
    }

    func workspaceTreeRowLeadingPadding(depth: Int) -> CGFloat {
        12 + CGFloat(depth * 16)
    }
}
