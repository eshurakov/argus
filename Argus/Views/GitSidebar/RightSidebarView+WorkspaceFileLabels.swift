import Foundation
import SwiftUI

// Presentation-only row labels and metrics for the Files View. These depend
// on nothing but their arguments and shared appearance settings, so they stay
// separate from the row behavior that owns the view's private state.
extension WorkspaceFilesView {
    func workspaceDirectoryLabel(
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

    func workspaceFileLabel(
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

    func workspaceTreeRowLeadingPadding(depth: Int) -> CGFloat {
        12 + CGFloat(depth * 16)
    }
}
