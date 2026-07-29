import Foundation
import SwiftUI

extension WorkspaceFilesView {
    @ViewBuilder
    var content: some View {
        switch viewModel.state {
        case .idle:
            emptyMessage("Select a workspace", systemImage: "folder")
        case .loading:
            loadingMessage
        case .loaded(let snapshot):
            if snapshot.request == request {
                fileTreeContent(snapshot)
            } else {
                loadingMessage
            }
        case .missingDirectory(let path):
            fileTreeError(title: "Directory not found", path: path, message: nil)
        case .error(let path, let message):
            fileTreeError(title: "Files unavailable", path: path, message: message)
        }
    }

    var request: WorkspaceFileTreeRequest? {
        guard let workspaceId, let rootPath else { return nil }
        return WorkspaceFileTreeRequest(
            workspaceId: workspaceId,
            rootPath: rootPath,
            showHiddenFiles: showHiddenFiles
        )
    }

    private var loadingMessage: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading files...")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private func fileTreeContent(_ snapshot: WorkspaceFileTreeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            fileTreeRootBar(snapshot)

            if snapshot.isCapped {
                fileTreeCapMessage(snapshot)
            }

            if snapshot.nodes.isEmpty {
                emptyMessage("Directory empty", systemImage: "folder")
            } else {
                fileTreeRows(snapshot)
            }
        }
    }

    private func fileTreeCapMessage(_ snapshot: WorkspaceFileTreeSnapshot) -> some View {
        Text(
            "Showing \(snapshot.displayedEntryCount) of \(snapshot.totalEntryCount) loaded entries "
                + "(\(snapshot.omittedEntryCount) omitted)"
        )
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private func fileTreeRootBar(_ snapshot: WorkspaceFileTreeSnapshot) -> some View {
        HStack(spacing: 7) {
            SemanticIcon(name: "folder", pointSize: 12, weight: .regular)
            Text((snapshot.rootPath as NSString).lastPathComponent)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text("\(snapshot.totalEntryCount) \(snapshot.totalEntryCount == 1 ? "item" : "items")")
                .foregroundColor(.secondary)
                .fixedSize()
        }
        .font(
            .system(
                size: appSettings.presentationMetrics.textSize(forBaseSize: 12),
                weight: .semibold,
                design: .monospaced
            )
        )
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
        .help(snapshot.rootPath)
        .overlay(alignment: .bottom) {
            ChromeColors.separator.frame(height: 1)
        }
    }
}
