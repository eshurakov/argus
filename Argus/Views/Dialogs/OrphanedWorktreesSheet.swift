// OrphanedWorktreesSheet.swift
// Argus
//
// Non-blocking sheet shown on app launch when orphaned worktrees are detected.
// Lists orphaned worktrees and lets the user adopt, delete, or dismiss each one.

import SwiftUI

private enum OrphanOperation: Equatable {
    case adopt
    case delete

    var statusLabel: String {
        switch self {
        case .adopt: "Adopting…"
        case .delete: "Deleting…"
        }
    }
}

private struct OrphanOperationFailure {
    let operation: OrphanOperation
    let message: String
}

struct OrphanedWorktreesSheet: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @Environment(\.dismiss) private var dismiss

    /// The list of orphaned worktrees to display.
    @State var orphans: [OrphanedWorktreeInfo]

    /// Tracks active operations and retains recoverable row-level failures.
    @State private var operations: [UUID: OrphanOperation] = [:]
    @State private var failures: [UUID: OrphanOperationFailure] = [:]
    @State private var pendingDeletion: OrphanedWorktreeInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title
            Text("Orphaned Worktrees Detected")
                .font(.headline)

            // Description
            Text(
                "The following worktrees on disk have no corresponding workspace. "
                    + "You can adopt them back into their project, delete them, or dismiss this dialog."
            )
            .font(.subheadline)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            // Orphan list
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(orphans) { orphan in
                        OrphanRow(
                            orphan: orphan,
                            operation: operations[orphan.id],
                            failure: failures[orphan.id],
                            onAdopt: { adoptOrphan(orphan) },
                            onDelete: { requestDelete(orphan) },
                            onRetry: { retryOrphan(orphan) }
                        )
                    }
                }
            }
            .frame(maxHeight: 300)
            .disabled(pendingDeletion != nil)

            if let pendingDeletion {
                deletionConfirmation(for: pendingDeletion)
            }

            // Dismiss button
            HStack {
                Spacer()
                Button("Dismiss") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(!operations.isEmpty || pendingDeletion != nil)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    // MARK: - Actions

    private func adoptOrphan(_ orphan: OrphanedWorktreeInfo) {
        guard operations[orphan.id] == nil else { return }
        operations[orphan.id] = .adopt
        failures[orphan.id] = nil
        Task {
            guard workspaceManager.projects.first(where: { $0.id == orphan.projectId }) != nil else {
                operations[orphan.id] = nil
                failures[orphan.id] = OrphanOperationFailure(
                    operation: .adopt,
                    message: "Project is no longer available."
                )
                return
            }

            guard workspaceManager.adoptOrphanedWorktree(orphan) != nil else {
                operations[orphan.id] = nil
                failures[orphan.id] = OrphanOperationFailure(
                    operation: .adopt,
                    message: "Workspace could not be created. The Workspace limit may have been reached."
                )
                return
            }

            orphans.removeAll { $0.id == orphan.id }
            operations[orphan.id] = nil
            failures[orphan.id] = nil

            if orphans.isEmpty { dismiss() }
        }
    }

    private func requestDelete(_ orphan: OrphanedWorktreeInfo) {
        guard operations[orphan.id] == nil, pendingDeletion == nil else { return }
        pendingDeletion = orphan
    }

    private func confirmPendingDeletion(_ orphan: OrphanedWorktreeInfo) {
        guard pendingDeletion?.id == orphan.id, operations[orphan.id] == nil else { return }
        pendingDeletion = nil
        deleteOrphan(orphan)
    }

    @ViewBuilder
    private func deletionConfirmation(for orphan: OrphanedWorktreeInfo) -> some View {
        Divider()

        VStack(alignment: .leading, spacing: 10) {
            Text("Delete Orphaned Worktree?")
                .font(.headline)

            Text(deleteConfirmationMessage(for: orphan))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()

                Button("Cancel") {
                    pendingDeletion = nil
                }
                .keyboardShortcut(.cancelAction)

                // Avoid a destructive role here. On macOS 27 both SwiftUI's
                // destructive alert and NSAlert can ask CoreUI to rasterize a
                // generated vector glyph at zero size and terminate the app.
                Button("Delete Worktree") {
                    confirmPendingDeletion(orphan)
                }
                .foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func deleteOrphan(_ orphan: OrphanedWorktreeInfo) {
        guard operations[orphan.id] == nil else { return }
        operations[orphan.id] = .delete
        failures[orphan.id] = nil
        Task {
            guard let project = workspaceManager.projects.first(where: { $0.id == orphan.projectId }) else {
                operations[orphan.id] = nil
                failures[orphan.id] = OrphanOperationFailure(
                    operation: .delete,
                    message: "Project is no longer available."
                )
                return
            }

            do {
                try await workspaceManager.worktreeService.cleanupOrphanedWorktree(
                    projectId: orphan.projectId,
                    repositoryPath: project.repositoryPath,
                    worktreePath: orphan.path
                )
            } catch {
                operations[orphan.id] = nil
                failures[orphan.id] = OrphanOperationFailure(
                    operation: .delete,
                    message: error.localizedDescription
                )
                return
            }

            orphans.removeAll { $0.id == orphan.id }
            operations[orphan.id] = nil
            failures[orphan.id] = nil

            if orphans.isEmpty { dismiss() }
        }
    }

    private func retryOrphan(_ orphan: OrphanedWorktreeInfo) {
        switch failures[orphan.id]?.operation {
        case .adopt:
            adoptOrphan(orphan)
        case .delete:
            requestDelete(orphan)
        case nil:
            break
        }
    }

    private func deleteConfirmationMessage(for orphan: OrphanedWorktreeInfo) -> String {
        let branch = orphan.branchName ?? "Unknown branch"
        return "Branch: \(branch)\nPath: \(orphan.path)\n\n"
            + "This permanently deletes the worktree from disk. This cannot be undone."
    }
}

// MARK: - OrphanRow

/// A single row displaying an orphaned worktree with adopt/delete actions.
private struct OrphanRow: View {
    let orphan: OrphanedWorktreeInfo
    let operation: OrphanOperation?
    let failure: OrphanOperationFailure?
    let onAdopt: () -> Void
    let onDelete: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                // Path and branch info
                VStack(alignment: .leading, spacing: 2) {
                    Text(truncatedPath(orphan.path))
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.head)

                    if let branch = orphan.branchName {
                        Text(branch)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                ZStack(alignment: .trailing) {
                    HStack(spacing: 8) {
                        Button("Adopt") {
                            onAdopt()
                        }

                        Button("Delete") {
                            onDelete()
                        }
                        .foregroundStyle(.red)
                    }
                    .opacity(operation == nil ? 1 : 0)
                    .disabled(operation != nil)
                    .allowsHitTesting(operation == nil)
                    .accessibilityHidden(operation != nil)

                    if let operation {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(operation.statusLabel)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(operation.statusLabel)
                    }
                }
                .frame(width: 132, alignment: .trailing)
            }

            if let failure {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)

                    Text(failureMessage(failure))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Button("Retry") {
                        onRetry()
                    }
                    .help("Retry")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(orphanAccessibilityLabel)
    }

    private func failureMessage(_ failure: OrphanOperationFailure) -> String {
        let title = failure.operation == .delete ? "Couldn’t delete worktree." : "Couldn’t adopt worktree."
        return "\(title) \(failure.message)"
    }

    private var orphanAccessibilityLabel: String {
        let branch = orphan.branchName ?? "Unknown branch"
        return "Orphaned Worktree, branch \(branch), path \(orphan.path)"
    }

    /// Returns the last 2–3 path components for a compact display.
    private func truncatedPath(_ path: String) -> String {
        let components = (path as NSString).pathComponents
            .filter { $0 != "/" }
        let suffix = components.suffix(3)
        return suffix.joined(separator: "/")
    }
}
