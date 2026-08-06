import SwiftUI

struct GitChangeDirectoryRow: View {
    let directory: GitFileTreeNode
    let depth: Int
    let isExpanded: Bool
    let canPerformActions: Bool
    let onAddToGitignore: (() -> Void)?
    let toggle: () -> Void
    @EnvironmentObject private var appSettings: AppSettings

    @State private var isHovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                    .frame(width: 12)
                Text(directory.name)
                    .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 11)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, treeRowLeadingPadding)
        .padding(.trailing, 12)
        .padding(.vertical, appSettings.presentationMetrics.treeRowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isHovered ? ChromeColors.hoveredTabFill : Color.clear)
        }
        .onHover { isHovering in
            isHovered = isHovering
        }
        .cursor(.pointingHand)
        .help("\(isExpanded ? "Collapse" : "Expand") directory \(directory.path)")
        .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") directory \(directory.path)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityActions {
            if let onAddToGitignore {
                Button("Add to .gitignore", action: onAddToGitignore)
                    .disabled(!canPerformActions)
            }
        }
        .contextMenu {
            if let onAddToGitignore {
                Button("Add to .gitignore", action: onAddToGitignore)
                    .disabled(!canPerformActions)
            }
        }
    }

    private var treeRowLeadingPadding: CGFloat {
        12 + CGFloat(depth * 16)
    }
}

extension GitSidebarView {
    func fileSection(
        _ section: GitChangeSectionContent,
        isExpanded: Binding<Bool>,
        owner: GitStatusSnapshotOwner
    ) -> some View {
        let actions = sectionActions(title: section.title, count: section.count)

        return VStack(spacing: 0) {
            fileSectionHeader(section, isExpanded: isExpanded, actions: actions, owner: owner)

            if isExpanded.wrappedValue {
                fileSectionRows(section.files, sectionKey: section.sectionKey, owner: owner)
            }
        }
        .contextMenu {
            fileSectionContextMenu(section, actions: actions, owner: owner)
        }
    }

    private func fileSectionHeader(
        _ section: GitChangeSectionContent,
        isExpanded: Binding<Bool>,
        actions: [GitFileSectionAction],
        owner: GitStatusSnapshotOwner
    ) -> some View {
        HStack {
            sectionDisclosureButton(section, isExpanded: isExpanded)
            Spacer()
            sectionActionControls(section, actions: actions, owner: owner)
            Text("\(section.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, appSettings.presentationMetrics.changeSectionHeaderVerticalPadding)
    }

    private func sectionDisclosureButton(
        _ section: GitChangeSectionContent,
        isExpanded: Binding<Bool>
    ) -> some View {
        let action = isExpanded.wrappedValue ? "Collapse" : "Expand"

        return HoverStateView { isHovered in
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(section.title)
                        .font(
                            .system(size: appSettings.presentationMetrics.textSize(forBaseSize: 12), weight: .semibold))
                }
                .frame(minHeight: 20)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isHovered ? ChromeColors.hoveredTabFill : Color.clear)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help("\(action) \(section.title) section")
            .accessibilityLabel("\(action) \(section.title) section")
            .accessibilityValue("\(section.count) \(section.count == 1 ? "change" : "changes")")
        }
    }

    @ViewBuilder
    private func sectionActionControls(
        _ section: GitChangeSectionContent,
        actions: [GitFileSectionAction],
        owner: GitStatusSnapshotOwner
    ) -> some View {
        if let visibleAction = actions.first(where: { !$0.isDestructive }) {
            sectionActionButton(visibleAction, section: section, owner: owner)
        }
        let destructiveActions = actions.filter(\.isDestructive)
        if !destructiveActions.isEmpty {
            sectionDestructiveActionsMenu(destructiveActions, section: section, owner: owner)
        }
    }

    private func sectionActionButton(
        _ action: GitFileSectionAction,
        section: GitChangeSectionContent,
        owner: GitStatusSnapshotOwner
    ) -> some View {
        let canPerformActions = viewModel.canPerformActions(for: owner)

        return HoverStateView { isHovered in
            Button {
                performSectionAction(
                    action.operation,
                    sectionKey: section.sectionKey,
                    pathCount: section.count,
                    owner: owner
                )
            } label: {
                Text(action.title)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(
                                canPerformActions && isHovered
                                    ? ChromeColors.hoveredTabFill
                                    : Color.clear
                            )
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canPerformActions)
            .cursor(canPerformActions ? .pointingHand : .arrow)
            .help(action.title)
        }
    }

    private func sectionDestructiveActionsMenu(
        _ actions: [GitFileSectionAction],
        section: GitChangeSectionContent,
        owner: GitStatusSnapshotOwner
    ) -> some View {
        let canPerformActions = viewModel.canPerformActions(for: owner)

        return HoverStateView { isHovered in
            Menu {
                ForEach(actions) { action in
                    Button(action.title) {
                        performSectionAction(
                            action.operation,
                            sectionKey: section.sectionKey,
                            pathCount: section.count,
                            owner: owner
                        )
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
                    .frame(width: 20, height: 20)
                    .background {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(
                                canPerformActions && isHovered
                                    ? ChromeColors.hoveredTabFill
                                    : Color.clear
                            )
                    }
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!canPerformActions)
            .cursor(canPerformActions ? .pointingHand : .arrow)
            .help("More \(section.title.lowercased()) actions")
            .accessibilityLabel("More \(section.title.lowercased()) actions")
        }
    }

    @ViewBuilder
    private func fileSectionRows(
        _ files: [GitFileChange],
        sectionKey: String,
        owner: GitStatusSnapshotOwner
    ) -> some View {
        ForEach(
            GitFileTree.visibleRows(
                nodes: GitFileTree.makeNodes(files: files),
                collapsedDirectoryIds: collapsedDirectoryIds
            )
        ) { row in
            switch row.content {
            case .directory(let directory):
                directoryRow(
                    directory,
                    depth: row.depth,
                    owner: owner,
                    allowsGitignore: sectionKey == "untracked"
                )
            case .file(let file):
                fileRow(file, name: row.name, depth: row.depth, owner: owner)
            }
        }
    }

    @ViewBuilder
    private func fileSectionContextMenu(
        _ section: GitChangeSectionContent,
        actions: [GitFileSectionAction],
        owner: GitStatusSnapshotOwner
    ) -> some View {
        ForEach(actions) { action in
            if action.isDestructive {
                Button(action.title) {
                    performSectionAction(
                        action.operation,
                        sectionKey: section.sectionKey,
                        pathCount: section.count,
                        owner: owner
                    )
                }
                .disabled(!viewModel.canPerformActions(for: owner))
            } else {
                Button(action.title) {
                    performSectionAction(
                        action.operation,
                        sectionKey: section.sectionKey,
                        pathCount: section.count,
                        owner: owner
                    )
                }
                .disabled(!viewModel.canPerformActions(for: owner))
            }
        }
    }

    private func performSectionAction(
        _ operation: GitStatusFileOperation,
        sectionKey: String,
        pathCount: Int,
        owner: GitStatusSnapshotOwner
    ) {
        Task {
            await confirmAndPerformSectionFileOperation(
                operation,
                sectionKey: sectionKey,
                pathCount: pathCount,
                owner: owner
            )
        }
    }
}
