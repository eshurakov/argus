import AppKit
import Foundation

protocol GitStatusPathCopying: AnyObject {
    func copyPath(_ path: String)
}

final class PasteboardGitStatusPathClipboard: GitStatusPathCopying {
    func copyPath(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }
}

protocol GitStatusFileOperationConfirming: AnyObject {
    @MainActor
    func confirm(operation: GitStatusFileOperation, paths: [String]) -> Bool

    @MainActor
    func confirm(operation: GitStatusFileOperation, pathCount: Int) -> Bool
}

extension GitStatusFileOperationConfirming {
    @MainActor
    func confirm(operation: GitStatusFileOperation, pathCount: Int) -> Bool {
        confirm(operation: operation, paths: Array(repeating: "", count: pathCount))
    }
}

final class AlertGitStatusFileOperationConfirmer: GitStatusFileOperationConfirming {
    @MainActor
    func confirm(operation: GitStatusFileOperation, paths: [String]) -> Bool {
        guard operation.requiresConfirmation else { return true }
        return runAlert(
            operation: operation,
            informativeText: operation.confirmationMessage(paths: paths)
        )
    }

    @MainActor
    func confirm(operation: GitStatusFileOperation, pathCount: Int) -> Bool {
        guard operation.requiresConfirmation else { return true }
        return runAlert(
            operation: operation,
            informativeText: operation.confirmationMessage(pathCount: pathCount)
        )
    }

    @MainActor
    private func runAlert(operation: GitStatusFileOperation, informativeText: String) -> Bool {
        confirmDestructiveAction(
            title: operation.confirmationTitle,
            message: informativeText,
            confirmTitle: operation.confirmationButtonTitle
        )
    }
}

struct GitStatusSnapshotOwner: Equatable, Hashable, Sendable {
    let workspaceId: UUID
    let rootPath: String
}

extension GitStatusViewModel {
    func refresh(context: GitStatusRootContext) async {
        await refresh(owner: legacyOwner(context: context), exposesWorkspaceId: false)
    }

    func refresh(workspaceId: UUID?, context: GitStatusRootContext) async {
        guard let workspaceId else {
            await refresh(context: context)
            return
        }
        await refresh(owner: owner(workspaceId: workspaceId, context: context))
    }

    func refresh(owner: GitStatusSnapshotOwner) async {
        await refresh(owner: owner, exposesWorkspaceId: true)
    }

    func initializeRepository(context: GitStatusRootContext) async {
        await initializeRepository(owner: legacyOwner(context: context), exposesWorkspaceId: false)
    }

    func initializeRepository(owner: GitStatusSnapshotOwner) async {
        await initializeRepository(owner: owner, exposesWorkspaceId: true)
    }

    func performFileOperation(
        _ operation: GitStatusFileOperation,
        path: String,
        context: GitStatusRootContext
    ) async {
        await performFileOperation(
            operation,
            path: path,
            owner: legacyOwner(context: context),
            exposesWorkspaceId: false
        )
    }

    func performFileOperation(
        _ operation: GitStatusFileOperation,
        path: String,
        owner: GitStatusSnapshotOwner
    ) async {
        await performFileOperation(operation, path: path, owner: owner, exposesWorkspaceId: true)
    }

    func performBulkFileOperation(
        _ operation: GitStatusFileOperation,
        paths: [String],
        context: GitStatusRootContext
    ) async {
        await performBulkFileOperation(
            operation,
            paths: paths,
            owner: legacyOwner(context: context),
            exposesWorkspaceId: false
        )
    }

    func performBulkFileOperation(
        _ operation: GitStatusFileOperation,
        paths: [String],
        owner: GitStatusSnapshotOwner
    ) async {
        await performBulkFileOperation(operation, paths: paths, owner: owner, exposesWorkspaceId: true)
    }

    func performSectionFileOperation(
        _ operation: GitStatusFileOperation,
        sectionKey: String,
        context: GitStatusRootContext
    ) async {
        await performSectionFileOperation(
            operation,
            sectionKey: sectionKey,
            owner: legacyOwner(context: context),
            exposesWorkspaceId: false
        )
    }

    func performSectionFileOperation(
        _ operation: GitStatusFileOperation,
        sectionKey: String,
        owner: GitStatusSnapshotOwner
    ) async {
        await performSectionFileOperation(
            operation,
            sectionKey: sectionKey,
            owner: owner,
            exposesWorkspaceId: true
        )
    }

    func copyPath(_ path: String) {
        pathClipboard.copyPath(path)
    }

    func confirmAndPerformFileOperation(
        _ operation: GitStatusFileOperation,
        paths: [String],
        context: GitStatusRootContext
    ) async {
        guard shouldPerform(operation, paths: paths) else { return }
        await performBulkFileOperation(operation, paths: paths, context: context)
    }

    func confirmAndPerformFileOperation(
        _ operation: GitStatusFileOperation,
        paths: [String],
        owner: GitStatusSnapshotOwner
    ) async {
        guard canPerformActions(for: owner), shouldPerform(operation, paths: paths) else { return }
        await performBulkFileOperation(operation, paths: paths, owner: owner)
    }

    func confirmAndPerformSectionFileOperation(
        _ operation: GitStatusFileOperation,
        sectionKey: String,
        pathCount: Int,
        context: GitStatusRootContext
    ) async {
        guard shouldPerform(operation, pathCount: pathCount) else { return }
        await performSectionFileOperation(operation, sectionKey: sectionKey, context: context)
    }

    func confirmAndPerformSectionFileOperation(
        _ operation: GitStatusFileOperation,
        sectionKey: String,
        pathCount: Int,
        owner: GitStatusSnapshotOwner
    ) async {
        guard canPerformActions(for: owner), shouldPerform(operation, pathCount: pathCount) else { return }
        await performSectionFileOperation(operation, sectionKey: sectionKey, owner: owner)
    }

    func loadPreview(
        kind: GitPreviewKind,
        file: GitFileChange,
        context: GitStatusRootContext
    ) async -> GitPreviewLoadState {
        await previewService.preview(kind: kind, rootPath: resolver.root(for: context), file: file)
    }

    func loadPreview(
        kind: GitPreviewKind,
        file: GitFileChange,
        owner: GitStatusSnapshotOwner
    ) async -> GitPreviewLoadState {
        guard ownsSnapshot(owner) else {
            return .failed(
                kind: kind,
                path: file.path,
                message: "Git status changed before preview opened."
            )
        }
        return await previewService.preview(kind: kind, rootPath: owner.rootPath, file: file)
    }

    private func shouldPerform(_ operation: GitStatusFileOperation, paths: [String]) -> Bool {
        !operation.requiresConfirmation || fileOperationConfirmer.confirm(operation: operation, paths: paths)
    }

    private func shouldPerform(_ operation: GitStatusFileOperation, pathCount: Int) -> Bool {
        !operation.requiresConfirmation
            || fileOperationConfirmer.confirm(operation: operation, pathCount: pathCount)
    }
}
