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
        Button("Delete Folder", role: .destructive) {
            guard let initiatingRequest = request else { return }
            Task {
                await deleteWorkspaceItem(
                    directory,
                    rootPath: rootPath,
                    initiatingRequest: initiatingRequest
                )
            }
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
        Button("Delete File", role: .destructive) {
            guard let initiatingRequest = request else { return }
            Task {
                await deleteWorkspaceItem(
                    file,
                    rootPath: rootPath,
                    initiatingRequest: initiatingRequest
                )
            }
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
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 24))
                .foregroundColor(.secondary.opacity(0.5))
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text(path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            Button("Retry Files") {
                Task { await refresh() }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRefreshing || request == nil)
            .cursor(viewModel.isRefreshing || request == nil ? .arrow : .pointingHand)
            .help("Retry loading files")
            .accessibilityValue(viewModel.isRefreshing ? "Loading" : "")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .foregroundColor(.orange)
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
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundColor(.secondary.opacity(0.5))
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
