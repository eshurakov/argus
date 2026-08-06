import Foundation
import Testing

@testable import Argus

@Suite
struct WorkspaceFilesViewModelTests {
    @Test @MainActor
    func copyRelativePathWritesWorkspaceItemPath() {
        let clipboard = RecordingWorkspaceRelativePathClipboard()
        let viewModel = WorkspaceFilesViewModel(relativePathClipboard: clipboard)

        viewModel.copyRelativePath("Sources/App/File.swift")

        #expect(clipboard.copiedPaths == ["Sources/App/File.swift"])
    }

    @Test @MainActor
    func confirmedDeletionInvokesOperatorWithoutPresentingAnotherPrompt() async {
        let workspaceId = UUID()
        let request = WorkspaceFileTreeRequest(workspaceId: workspaceId, rootPath: "/tmp/argus-delete-test")
        let fileOperator = RecordingWorkspaceFileOperator()
        let prompter = RecordingWorkspaceFileOperationPrompter()
        let viewModel = WorkspaceFilesViewModel(fileOperator: fileOperator, filePrompter: prompter)

        viewModel.activate(request: request)
        let deleted = await viewModel.deleteFile(request: request, path: "notes.txt")

        #expect(deleted)
        #expect(fileOperator.deletedItems.count == 1)
        #expect(fileOperator.deletedItems.first?.rootPath == request.rootPath)
        #expect(fileOperator.deletedItems.first?.path == "notes.txt")
        #expect(prompter.renamePromptCount == 0)
        #expect(prompter.failures.isEmpty)
    }
}

@MainActor
private final class RecordingWorkspaceFileOperator: WorkspaceFileOperating {
    struct DeletedItem {
        let rootPath: String
        let path: String
    }

    private(set) var deletedItems: [DeletedItem] = []

    func copyFile(rootPath: String, path: String) throws {}

    func deleteFile(rootPath: String, path: String) async throws {
        deletedItems.append(DeletedItem(rootPath: rootPath, path: path))
    }

    func renameFile(rootPath: String, path: String, newName: String) async throws -> String {
        newName
    }
}

@MainActor
private final class RecordingWorkspaceFileOperationPrompter: WorkspaceFileOperationPrompting {
    private(set) var renamePromptCount = 0
    private(set) var failures: [(String, String)] = []

    func promptRename(currentName: String) -> String? {
        renamePromptCount += 1
        return nil
    }

    func showFailure(title: String, message: String) {
        failures.append((title, message))
    }
}

@MainActor
private final class RecordingWorkspaceRelativePathClipboard: WorkspaceRelativePathCopying {
    private(set) var copiedPaths: [String] = []

    func copyRelativePath(_ path: String) {
        copiedPaths.append(path)
    }
}
