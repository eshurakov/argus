// swiftlint:disable file_length
import SwiftUI

extension GitSidebarView {
    func directoryRow(_ directory: GitFileTreeNode, depth: Int) -> some View {
        let isExpanded = !collapsedDirectoryIds.contains(directory.id)

        return GitChangeDirectoryRow(
            directory: directory,
            depth: depth,
            isExpanded: isExpanded
        ) {
            if collapsedDirectoryIds.contains(directory.id) {
                collapsedDirectoryIds.remove(directory.id)
            } else {
                collapsedDirectoryIds.insert(directory.id)
            }
        }
    }

    func fileRow(
        _ file: GitFileChange,
        name: String,
        depth: Int,
        owner: GitStatusSnapshotOwner
    ) -> some View {
        let canPerformActions = viewModel.canPerformActions(for: owner)

        return GitChangeFileRow(
            file: file,
            name: name,
            depth: depth,
            actions: fileActions(for: file),
            canPerformActions: canPerformActions,
            accessibilityValue: fileAccessibilityValue(file)
        ) { action in
            perform(action, for: file, owner: owner)
        }
    }

    private func fileActions(for file: GitFileChange) -> [GitFileRowAction] {
        switch file.sectionKey {
        case "staged":
            return [.unstage, .diff, .blame, .copyPath]
        case "unstaged":
            return [.stage, .discard, .diff, .blame, .copyPath]
        case "untracked":
            return [.stage, .delete, .diff, .copyPath]
        default:
            return [.copyPath]
        }
    }

    private func perform(
        _ action: GitFileRowAction,
        for file: GitFileChange,
        owner: GitStatusSnapshotOwner
    ) {
        guard selectedSnapshotOwner == owner, viewModel.canPerformActions(for: owner) else { return }
        switch action {
        case .stage, .unstage:
            Task { await performFileOperation(action.operation, path: file.path, owner: owner) }
        case .discard, .delete:
            Task { await confirmAndPerformFileOperation(action.operation, paths: [file.path], owner: owner) }
        case .diff:
            Task { await showPreview(kind: .diff, file: file, owner: owner) }
        case .blame:
            Task { await showPreview(kind: .blame, file: file, owner: owner) }
        case .copyPath:
            viewModel.copyPath(file.path)
        }
    }

    private func fileAccessibilityValue(_ file: GitFileChange) -> String {
        var values = [file.status.displayName]
        if let originalPath = file.originalPath { values.append("from \(originalPath)") }
        if let additions = file.additions { values.append("\(additions) lines added") }
        if let deletions = file.deletions { values.append("\(deletions) lines removed") }
        return values.joined(separator: ", ")
    }

    func sectionActions(title: String, count: Int) -> [GitFileSectionAction] {
        guard count > 0 else { return [] }
        switch title {
        case "Staged":
            return [.unstageAll]
        case "Unstaged":
            return [.stageAll, .discardAll]
        case "Untracked":
            return [.stageAll, .deleteAll]
        default:
            return []
        }
    }

    func notRepositoryContent(rootPath: String, message: String? = nil) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 24))
                .foregroundColor(.secondary.opacity(0.5))
            Text("Not a git repository")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text(rootPath)
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
            Button {
                Task { await initializeRepository() }
            } label: {
                Text("Initialize Git Repository")
            }
            .controlSize(.small)
            .disabled(viewModel.isRefreshing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func operationFailureContent(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text("Git file operation failed")
                .font(.system(size: 13, weight: .medium))
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Button {
                guard let owner = selectedSnapshotOwner else { return }
                Task { await refresh(owner: owner) }
            } label: {
                Text("Refresh Changes")
            }
            .controlSize(.small)
            .disabled(viewModel.isRefreshing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    func refresh(owner: GitStatusSnapshotOwner) async {
        guard selectedSnapshotOwner == owner else { return }
        await viewModel.refresh(owner: owner)
    }

    private func initializeRepository() async {
        guard let owner = selectedSnapshotOwner, viewModel.ownsSnapshot(owner) else { return }
        await viewModel.initializeRepository(owner: owner)
    }

    private func performFileOperation(
        _ operation: GitStatusFileOperation?,
        path: String,
        owner: GitStatusSnapshotOwner
    ) async {
        guard let operation, selectedSnapshotOwner == owner else { return }
        await viewModel.performFileOperation(operation, path: path, owner: owner)
    }

    private func confirmAndPerformFileOperation(
        _ operation: GitStatusFileOperation?,
        paths: [String],
        owner: GitStatusSnapshotOwner
    ) async {
        guard let operation, selectedSnapshotOwner == owner else { return }
        await viewModel.confirmAndPerformFileOperation(operation, paths: paths, owner: owner)
    }

    func confirmAndPerformSectionFileOperation(
        _ operation: GitStatusFileOperation,
        sectionKey: String,
        pathCount: Int,
        owner: GitStatusSnapshotOwner
    ) async {
        guard selectedSnapshotOwner == owner else { return }
        await viewModel.confirmAndPerformSectionFileOperation(
            operation,
            sectionKey: sectionKey,
            pathCount: pathCount,
            owner: owner
        )
    }

    private func showPreview(
        kind: GitPreviewKind,
        file: GitFileChange,
        owner: GitStatusSnapshotOwner
    ) async {
        guard selectedSnapshotOwner == owner else { return }

        let result = await viewModel.loadPreview(kind: kind, file: file, owner: owner)
        guard let sourceWorkspace = workspaceManager.workspaces.first(where: { $0.id == owner.workspaceId }) else {
            return
        }

        switch result {
        case .loaded(let preview):
            sourceWorkspace.openGitPreviewPanel(rootPath: owner.rootPath, preview: preview)
        case .failed(let kind, let path, let message):
            sourceWorkspace.openGitPreviewPanel(
                rootPath: owner.rootPath,
                preview: GitPreview(kind: kind, path: path, content: .ansiText(message))
            )
        }
    }

    func startAutoRefresh(owner: GitStatusSnapshotOwner) {
        autoRefreshController.start(rootPath: owner.rootPath) {
            await refresh(owner: owner)
        }
    }

    var selectedSnapshotOwner: GitStatusSnapshotOwner? {
        _ = workspaceManager.workspaceContextRevision
        guard let workspace = workspaceManager.selectedWorkspace,
            let context = statusContext()
        else { return nil }
        return viewModel.owner(workspaceId: workspace.id, context: context)
    }

    private func statusContext() -> GitStatusRootContext? {
        guard let workspace = workspaceManager.selectedWorkspace else { return nil }
        return gitStatusContext(
            workspace: workspace,
            project: workspaceManager.project(for: workspace.id)
        )
    }
}

private struct GitChangeFileRow: View {
    let file: GitFileChange
    let name: String
    let depth: Int
    let actions: [GitFileRowAction]
    let canPerformActions: Bool
    let accessibilityValue: String
    let perform: (GitFileRowAction) -> Void
    @EnvironmentObject private var appSettings: AppSettings

    @State private var isHovered = false
    @State private var hoveredAction: GitFileRowAction?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            statusIndicator
            Text(name)
                .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 11)))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            trailingContent
        }
        .font(
            .system(
                size: appSettings.presentationMetrics.textSize(forBaseSize: 10),
                weight: .medium,
                design: .monospaced
            )
        )
        .padding(.leading, treeRowLeadingPadding)
        .padding(.trailing, 12)
        .padding(.vertical, appSettings.presentationMetrics.treeRowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isHovered ? ChromeColors.hoveredTabFill : Color.clear)
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .accessibilityLabel(file.path)
        .accessibilityValue(accessibilityValue)
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.title) {
                    perform(action)
                }
                .disabled(!canPerformActions)
            }
        }
        .contextMenu {
            contextMenu
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        Group {
            if let systemImage = file.status.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 14)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .frame(width: 6, height: 6)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }
        }
        .foregroundColor(file.status.tintColor)
    }

    private var revealsActions: Bool {
        isHovered || isFocused
    }

    private var trailingContent: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 5) {
                if let additions = file.additions {
                    Text("+\(additions)")
                        .foregroundColor(.green)
                }
                if let deletions = file.deletions {
                    Text("-\(deletions)")
                        .foregroundColor(.red)
                }
            }
            .opacity(revealsActions ? 0 : 1)

            HStack(spacing: 5) {
                ForEach(actions) { action in
                    Button {
                        perform(action)
                    } label: {
                        Image(systemName: action.systemImage)
                            .frame(width: 20, height: 20)
                            .background {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(
                                        canPerformActions && hoveredAction == action
                                            ? ChromeColors.hoveredTabFill
                                            : Color.clear
                                    )
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canPerformActions)
                    .onHover { isHovering in
                        if canPerformActions && isHovering {
                            hoveredAction = action
                        } else if hoveredAction == action {
                            hoveredAction = nil
                        }
                    }
                    .cursor(canPerformActions ? .pointingHand : .arrow)
                    .help(action.title)
                    .accessibilityLabel(action.title)
                }
            }
            .opacity(revealsActions ? 1 : 0)
            .allowsHitTesting(revealsActions)
            .accessibilityHidden(!revealsActions)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        ForEach(actions) { action in
            if action == .discard || action == .delete {
                Button(action.title, role: .destructive) {
                    perform(action)
                }
                .disabled(!canPerformActions)
            } else {
                Button(action.title) {
                    perform(action)
                }
                .disabled(!canPerformActions)
            }
        }
    }

    private var treeRowLeadingPadding: CGFloat {
        12 + CGFloat(depth * 16)
    }
}
