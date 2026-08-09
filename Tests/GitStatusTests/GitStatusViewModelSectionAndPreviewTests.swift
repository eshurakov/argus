import AppKit
import Foundation
import Testing

@testable import Argus

@Suite
struct GitStatusViewModelSectionAndPreviewTests {
    @Test
    @MainActor
    func sectionBulkOperationUsesSectionScopeForCappedResults() async {
        let refreshed = GitStatusLoadState.loaded(
            GitStatusSummary(
                rootPath: "/tmp/repo",
                branchName: "main",
                upstreamName: nil,
                aheadCount: 0,
                behindCount: 0
            ))
        let service = FakeStatusService(result: .idle, operationResult: refreshed)
        let viewModel = GitStatusViewModel(service: service)
        let context = GitStatusRootContext(
            kind: .standalone,
            currentDirectory: "/tmp/repo",
            worktreePath: nil,
            projectRepositoryPath: nil
        )

        await viewModel.confirmAndPerformSectionFileOperation(
            .stage, sectionKey: "untracked", pathCount: 501, context: context)

        assertViewModelSectionEqual(
            service.bulkOperationRequests.isEmpty, true,
            "capped section bulk actions do not operate only on displayed file paths")
        assertViewModelSectionEqual(
            service.sectionOperationRequests.map(\.description),
            ["stage-/tmp/repo-untracked"], "bulk action operates on the whole git section")
        assertViewModelSectionEqual(viewModel.state, refreshed, "section bulk operation publishes refreshed status")
    }

    @Test
    @MainActor
    func sectionBulkOperationKeepsLoadedContentVisibleWhileRefreshing() async {
        let current = GitStatusLoadState.loaded(
            GitStatusSummary(
                rootPath: "/tmp/repo",
                branchName: "main",
                upstreamName: nil,
                aheadCount: 0,
                behindCount: 0,
                unstagedCount: 1
            ))
        let service = SuspendingSectionStatusService(result: current)
        let viewModel = GitStatusViewModel(service: service)
        let context = GitStatusRootContext(
            kind: .standalone,
            currentDirectory: "/tmp/repo",
            worktreePath: nil,
            projectRepositoryPath: nil
        )
        await viewModel.refresh(context: context)

        let operation = Task {
            await viewModel.performSectionFileOperation(
                .stage, sectionKey: "unstaged", context: context)
        }
        await service.waitUntilOperationStarts()

        assertViewModelSectionEqual(viewModel.state, current, "bulk operation keeps loaded sidebar content visible")
        assertViewModelSectionEqual(
            viewModel.isRefreshing, true, "bulk operation shows non-disruptive refresh progress")
        await service.finishOperation()
        await operation.value
    }

    @Test
    @MainActor
    func destructiveSectionBulkOperationConfirmsTotalSectionCount() async {
        let service = FakeStatusService(result: .idle)
        let confirmation = RecordingFileOperationConfirmer(shouldConfirm: true)
        let viewModel = GitStatusViewModel(service: service, fileOperationConfirmer: confirmation)
        let context = GitStatusRootContext(
            kind: .standalone,
            currentDirectory: "/tmp/repo",
            worktreePath: nil,
            projectRepositoryPath: nil
        )

        await viewModel.confirmAndPerformSectionFileOperation(
            .delete, sectionKey: "untracked", pathCount: 501, context: context)

        assertViewModelSectionEqual(
            confirmation.requests, [.delete], "destructive section action asks for confirmation")
        assertViewModelSectionEqual(
            confirmation.pathCountRequests, [501],
            "destructive section confirmation uses total section count, not capped row count")
        assertViewModelSectionEqual(
            confirmation.confirmationTitleRequests,
            ["Delete All Untracked Files"],
            "destructive section confirmation names the exact operation")
        assertViewModelSectionEqual(
            service.sectionOperationRequests.map(\.description),
            ["delete-/tmp/repo-untracked"],
            "confirmed destructive section action operates on whole section")
    }

    @Test
    @MainActor
    func previewUsesResolvedRootAndReturnsOutput() async {
        let service = FakeStatusService(result: .idle)
        let previewService = RecordingPreviewService(
            result: .loaded(
                GitPreview(
                    kind: .diff,
                    path: "file.txt",
                    content: .diff(
                        GitDiffPreview(
                            fileName: "file.txt", oldContent: "old", newContent: "new")))))
        let viewModel = GitStatusViewModel(
            service: service, previewService: previewService)
        let context = GitStatusRootContext(
            kind: .worktree,
            currentDirectory: "/tmp/worktree/subdir",
            worktreePath: "/tmp/worktree",
            projectRepositoryPath: nil
        )
        let file = GitFileChange(path: "file.txt", status: .modified, sectionKey: "unstaged")

        let result = await viewModel.loadPreview(kind: .diff, file: file, context: context)

        assertViewModelSectionEqual(
            previewService.requests.map(\.description),
            ["diff-/tmp/worktree-file.txt"], "preview uses resolved status root and selected row")
        assertViewModelSectionEqual(
            result,
            .loaded(
                GitPreview(
                    kind: .diff,
                    path: "file.txt",
                    content: .diff(
                        GitDiffPreview(
                            fileName: "file.txt", oldContent: "old", newContent: "new")))),
            "loaded preview is returned for tab presentation")
        assertViewModelSectionEqual(viewModel.state, .idle, "preview does not replace git status state")
    }

    @Test
    @MainActor
    func previewFailureIsReturnedWithoutReplacingStatusState() async {
        let current = GitStatusLoadState.loaded(
            GitStatusSummary(
                rootPath: "/tmp/repo", branchName: "main", upstreamName: nil, aheadCount: 0, behindCount: 0)
        )
        let service = FakeStatusService(result: current)
        let previewService = RecordingPreviewService(
            result: .failed(kind: .blame, path: "missing.txt", message: "fatal: no such path"))
        let viewModel = GitStatusViewModel(
            service: service, previewService: previewService)
        let context = GitStatusRootContext(
            kind: .standalone, currentDirectory: "/tmp/repo", worktreePath: nil,
            projectRepositoryPath: nil)
        await viewModel.refresh(context: context)

        let result = await viewModel.loadPreview(
            kind: .blame,
            file: GitFileChange(path: "missing.txt", status: .modified, sectionKey: "unstaged"),
            context: context)

        assertViewModelSectionEqual(
            result, .failed(kind: .blame, path: "missing.txt", message: "fatal: no such path"),
            "preview failure is returned for tab presentation")
        assertViewModelSectionEqual(viewModel.state, current, "preview failure does not replace loaded status state")
    }

    @Test
    @MainActor
    func automaticRefreshUsesSameLoadingRefreshPath() async {
        let loaded = GitStatusLoadState.loaded(
            GitStatusSummary(
                rootPath: "/tmp/worktree",
                branchName: "main",
                upstreamName: nil,
                aheadCount: 0,
                behindCount: 0
            ))
        var observedLoading = false
        let service = ObservingStatusService(result: loaded) {
            observedLoading = true
        }
        let viewModel = GitStatusViewModel(service: service)
        let watcher = ViewModelTestWatcher()
        let scheduler = ViewModelTestScheduler()
        let controller = GitStatusAutoRefreshController(
            watcher: watcher,
            scheduler: scheduler,
            now: { Date(timeIntervalSince1970: 100) }
        )
        let context = GitStatusRootContext(
            kind: .worktree,
            currentDirectory: "/tmp/worktree/subdir",
            worktreePath: "/tmp/worktree",
            projectRepositoryPath: nil
        )

        controller.start(rootPath: "/tmp/worktree") {
            await viewModel.refresh(context: context)
        }
        watcher.emit(paths: ["/tmp/worktree/file.txt"])
        await scheduler.runScheduled()

        assertViewModelSectionEqual(
            observedLoading, true, "automatic refresh exposes loading state before service returns")
        assertViewModelSectionEqual(viewModel.state, loaded, "automatic refresh publishes final status")
    }
}

private func assertViewModelSectionEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    #expect(actual == expected, Comment(rawValue: message))
}
