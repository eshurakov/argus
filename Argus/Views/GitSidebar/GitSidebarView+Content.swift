import SwiftUI

extension GitSidebarView {
    var header: some View {
        let canRefresh = !viewModel.isRefreshing && selectedSnapshotOwner != nil

        return HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .frame(width: 18)
            Text("Changes")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            ZStack {
                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 12, height: 12)
            HoverStateView { isHovered in
                Button {
                    guard let owner = selectedSnapshotOwner else { return }
                    Task { await refresh(owner: owner) }
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
                .help("Refresh changes")
                .accessibilityLabel("Refresh changes")
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            ChromeColors.separator.frame(height: 1)
        }
    }

    @ViewBuilder
    var content: some View {
        if let owner = selectedSnapshotOwner, viewModel.ownsSnapshot(owner) {
            ownedContent(owner: owner)
        } else if selectedSnapshotOwner == nil {
            emptyMessage("Select a workspace", systemImage: "folder")
        } else {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading changes")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func ownedContent(owner: GitStatusSnapshotOwner) -> some View {
        switch viewModel.state {
        case .idle:
            emptyMessage("Select a workspace", systemImage: "folder")
        case .loading:
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Refreshing…")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        case .loaded(let summary):
            statusContent(summary, owner: owner)
        case .notRepository(let rootPath):
            notRepositoryContent(rootPath: rootPath)
        case .repositoryInitializationFailed(let rootPath, let message):
            notRepositoryContent(rootPath: rootPath, message: message)
        case .fileOperationFailed(_, let message):
            operationFailureContent(message)
        case .error(_, let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Git status failed")
                    .font(.system(size: 13, weight: .medium))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
    }

    @ViewBuilder
    private func statusContent(_ summary: GitStatusSummary, owner: GitStatusSnapshotOwner) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            branchBar(summary)

            if summary.isClean {
                cleanWorkingTreeContent()
            } else {
                if summary.isFileDisplayCapped {
                    Text(
                        "Showing first \(GitStatusSummary.displayFileLimit) of \(summary.totalFileCount) change entries"
                    )
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                }

                changeSections(summary, owner: owner)
            }
        }
    }

    private func cleanWorkingTreeContent() -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.green.opacity(0.8))
                .accessibilityHidden(true)
            Text("Working tree clean")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text("No staged, unstaged, or untracked changes")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func changeSections(
        _ summary: GitStatusSummary,
        owner: GitStatusSnapshotOwner
    ) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(summary.sections) { section in
                    fileSection(
                        GitChangeSectionContent(section: section),
                        isExpanded: sectionExpansionBinding(for: section.kind),
                        owner: owner
                    )
                }
            }
        }
    }

    private func branchBar(_ summary: GitStatusSummary) -> some View {
        let totals = totalDiffStats(summary)
        let allCollapsed = allSectionsCollapsed(summary)
        let actionName = allCollapsed ? "Expand all file sections" : "Collapse all file sections"

        return HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            Text(summary.branchName ?? "Detached HEAD")
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            Text("\(summary.totalFileCount) \(summary.totalFileCount == 1 ? "file" : "files")")
                .foregroundColor(.secondary)
                .fixedSize()
            Text("+\(totals.additions)")
                .foregroundColor(.green)
                .fixedSize()
            Text("-\(totals.deletions)")
                .foregroundColor(.red)
                .fixedSize()

            if let upstreamName = summary.upstreamName {
                Text(upstreamText(summary, upstreamName: upstreamName))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            branchSectionActionButton(
                allCollapsed: allCollapsed,
                summary: summary,
                actionName: actionName
            )
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
        .overlay(alignment: .bottom) {
            ChromeColors.separator.frame(height: 1)
        }
    }

    private func branchSectionActionButton(
        allCollapsed: Bool,
        summary: GitStatusSummary,
        actionName: String
    ) -> some View {
        HoverStateView { isHovered in
            Button {
                setAllSectionsExpanded(allCollapsed, summary: summary)
            } label: {
                Image(
                    systemName: allCollapsed
                        ? "arrow.up.and.line.horizontal.and.arrow.down"
                        : "arrow.down.and.line.horizontal.and.arrow.up"
                )
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
                .frame(width: 20, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isHovered ? ChromeColors.hoveredTabFill : Color.clear)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help(actionName)
            .accessibilityLabel(actionName)
        }
    }

    private func totalDiffStats(_ summary: GitStatusSummary) -> (additions: Int, deletions: Int) {
        let files = summary.sections.flatMap(\.files)
        return files.reduce(into: (additions: 0, deletions: 0)) { totals, file in
            totals.additions += file.additions ?? 0
            totals.deletions += file.deletions ?? 0
        }
    }

    private func allSectionsCollapsed(_ summary: GitStatusSummary) -> Bool {
        summary.sections
            .filter(\.state.isAvailable)
            .allSatisfy { !isSectionExpanded($0.kind) }
    }

    private func setAllSectionsExpanded(_ isExpanded: Bool, summary: GitStatusSummary) {
        for section in summary.sections {
            guard case .available = section.state else { continue }
            setSectionExpanded(section.kind, isExpanded: isExpanded)
        }
    }

    private func isSectionExpanded(_ kind: GitChangeSectionKind) -> Bool {
        guard let workspaceId = selectedSnapshotOwner?.workspaceId else {
            return RightSidebarSessionState.defaultExpandedSectionKinds.contains(kind)
        }
        return sessionState.expandedSectionKinds(for: workspaceId).contains(kind)
    }

    private func setSectionExpanded(_ kind: GitChangeSectionKind, isExpanded: Bool) {
        guard let workspaceId = selectedSnapshotOwner?.workspaceId else { return }
        sessionState.setSectionExpanded(kind, isExpanded: isExpanded, workspaceId: workspaceId)
    }

    private func sectionExpansionBinding(for kind: GitChangeSectionKind) -> Binding<Bool> {
        Binding(
            get: { isSectionExpanded(kind) },
            set: { setSectionExpanded(kind, isExpanded: $0) }
        )
    }

    private func upstreamText(_ summary: GitStatusSummary, upstreamName: String) -> String {
        var parts = [upstreamName]
        if summary.aheadCount > 0 { parts.append("↑\(summary.aheadCount)") }
        if summary.behindCount > 0 { parts.append("↓\(summary.behindCount)") }
        return parts.joined(separator: " ")
    }
}
