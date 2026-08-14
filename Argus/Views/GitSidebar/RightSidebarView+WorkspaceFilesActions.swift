import SwiftUI

extension WorkspaceFilesView {
    @ViewBuilder
    func workspaceDirectoryContextMenu(
        _ directory: WorkspaceFileTreeNode,
        rootPath: String
    ) -> some View {
        Button("Open Folder") {
            openWorkspaceDirectory(directory, rootPath: rootPath)
        }
        Button("Copy Folder") {
            copyWorkspaceItem(directory, rootPath: rootPath)
        }
        Button("Copy Relative Path") {
            copyWorkspaceItemRelativePath(directory)
        }
        Button("Delete Folder") {
            guard let initiatingRequest = request else { return }
            requestWorkspaceItemDeletion(
                directory,
                rootPath: rootPath,
                initiatingRequest: initiatingRequest
            )
        }
        Button("Rename Folder") {
            guard let initiatingRequest = request else { return }
            Task {
                await renameWorkspaceItem(
                    directory,
                    rootPath: rootPath,
                    initiatingRequest: initiatingRequest
                )
            }
        }
    }

    @ViewBuilder
    func workspaceFileContextMenu(
        _ file: WorkspaceFileTreeNode,
        rootPath: String
    ) -> some View {
        Button("Open File") {
            openWorkspaceFile(file, rootPath: rootPath)
        }
        Button("Copy File") {
            copyWorkspaceItem(file, rootPath: rootPath)
        }
        Button("Copy Relative Path") {
            copyWorkspaceItemRelativePath(file)
        }
        Button("Delete File") {
            guard let initiatingRequest = request else { return }
            requestWorkspaceItemDeletion(
                file,
                rootPath: rootPath,
                initiatingRequest: initiatingRequest
            )
        }
        Button("Rename File") {
            guard let initiatingRequest = request else { return }
            Task {
                await renameWorkspaceItem(
                    file,
                    rootPath: rootPath,
                    initiatingRequest: initiatingRequest
                )
            }
        }
    }

    func fileTreeError(title: String, path: String, message: String?) -> some View {
        SurfaceMessageView(
            systemImage: "folder.badge.questionmark",
            title: title,
            path: path,
            warning: message,
            actionTitle: "Retry Files",
            actionHelp: "Retry loading files",
            actionAccessibilityValue: viewModel.isRefreshing ? "Loading" : "",
            actionDisabled: viewModel.isRefreshing || request == nil
        ) {
            Task { await refresh() }
        }
    }

    func directoryLoadError(
        _ error: WorkspaceFileTreeDirectoryError,
        directory: WorkspaceFileTreeNode,
        depth: Int,
        rootPath: String
    ) -> some View {
        let isLoading = viewModel.loadingDirectoryPaths.contains(directory.path)

        return HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(error.message)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button("Retry Folder") {
                guard let initiatingRequest = request,
                    initiatingRequest.rootPath == rootPath
                else {
                    return
                }
                Task {
                    await viewModel.loadChildren(
                        request: initiatingRequest,
                        directoryPath: directory.path
                    )
                }
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .cursor(isLoading ? .arrow : .pointingHand)
            .help("Retry loading \(directory.name)")
        }
        .font(.system(size: 10))
        .foregroundColor(.secondary)
        .padding(.leading, workspaceTreeRowLeadingPadding(depth: depth + 1) + 19)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(error.path): \(error.message)")
        .accessibilityLabel("Could not load \(directory.name) folder")
        .accessibilityValue(error.message)
    }

    func emptyMessage(_ text: String, systemImage: String) -> some View {
        SurfaceMessageView(systemImage: systemImage, title: text)
    }

    private func refresh() async {
        guard let request else {
            viewModel.reset()
            return
        }
        await viewModel.refresh(request: request)
    }
}

@MainActor
func gitStatusContext(workspace: Workspace, project: Project?) -> GitStatusRootContext {
    let projectRepositoryPath = project?.isCatchAll == false ? project?.repositoryPath : nil
    let configuredBaseBranch = project?.isCatchAll == false ? project?.mainBranch : nil

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
        projectRepositoryPath: projectRepositoryPath,
        configuredBaseBranch: configuredBaseBranch
    )
}
