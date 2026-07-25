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
}

@MainActor
private final class RecordingWorkspaceRelativePathClipboard: WorkspaceRelativePathCopying {
    private(set) var copiedPaths: [String] = []

    func copyRelativePath(_ path: String) {
        copiedPaths.append(path)
    }
}
