import AppKit
import Foundation
import Testing

@testable import Argus

@Suite
struct GitStatusViewModelTests {
    @Test
    @MainActor
    func manualRefreshPublishesLoadingThenLoadedState() async {
        let service = FakeStatusService(
            result: .loaded(
                GitStatusSummary(
                    rootPath: "/tmp/worktree",
                    branchName: "main",
                    upstreamName: nil,
                    aheadCount: 0,
                    behindCount: 0,
                    stagedCount: 0,
                    unstagedCount: 0,
                    untrackedCount: 0
                )))
        let viewModel = GitStatusViewModel(service: service)
        let context = GitStatusRootContext(
            kind: .worktree,
            currentDirectory: "/tmp/worktree/subdir",
            worktreePath: "/tmp/worktree",
            projectRepositoryPath: "/tmp/repo"
        )

        await viewModel.refresh(context: context)

        assertEqual(service.requestedRoots, ["/tmp/worktree"], "refresh uses resolved worktree root")
        assertEqual(viewModel.state, service.result, "refresh publishes loaded state")
    }

    @Test
    @MainActor
    func initializingRepositoryPublishesCleanRefreshedStatus() async {
        let loaded = GitStatusLoadState.loaded(
            GitStatusSummary(
                rootPath: "/tmp/new-repo",
                branchName: "main",
                upstreamName: nil,
                aheadCount: 0,
                behindCount: 0,
                stagedCount: 0,
                unstagedCount: 0,
                untrackedCount: 0
            ))
        let service = FakeStatusService(
            result: .notRepository(rootPath: "/tmp/new-repo"), initializeResult: loaded)
        let viewModel = GitStatusViewModel(service: service)
        let context = GitStatusRootContext(
            kind: .standalone,
            currentDirectory: "/tmp/new-repo",
            worktreePath: nil,
            projectRepositoryPath: nil
        )

        await viewModel.initializeRepository(context: context)

        assertEqual(service.initializedRoots, ["/tmp/new-repo"], "initialize uses resolved root")
        assertEqual(viewModel.state, loaded, "successful initialize publishes refreshed clean status")
    }

    @Test
    @MainActor
    func copyPathWritesDisplayedFilePathWithoutGitMutation() async {
        let clipboard = RecordingPathClipboard()
        let service = FakeStatusService(
            result: .loaded(
                GitStatusSummary(
                    rootPath: "/tmp/repo",
                    branchName: "main",
                    upstreamName: nil,
                    aheadCount: 0,
                    behindCount: 0
                )))
        let viewModel = GitStatusViewModel(service: service, pathClipboard: clipboard)

        viewModel.copyPath("Sources/App/File.swift")

        assertEqual(
            clipboard.copiedPaths, ["Sources/App/File.swift"], "copy-path copies the displayed row path")
        assertEqual(service.operationRequests.isEmpty, true, "copy-path does not run a git operation")
        assertEqual(service.requestedRoots.isEmpty, true, "copy-path does not refresh git state")
    }

    @Test
    @MainActor
    func fileOperationUsesResolvedRootAndPublishesRefreshedStatus() async {
        let refreshed = GitStatusLoadState.loaded(
            GitStatusSummary(
                rootPath: "/tmp/worktree",
                branchName: "main",
                upstreamName: nil,
                aheadCount: 0,
                behindCount: 0,
                stagedCount: 1,
                unstagedCount: 0,
                untrackedCount: 0
            ))
        let service = FakeStatusService(result: .idle, operationResult: refreshed)
        let viewModel = GitStatusViewModel(service: service)
        let context = GitStatusRootContext(
            kind: .worktree,
            currentDirectory: "/tmp/worktree/subdir",
            worktreePath: "/tmp/worktree",
            projectRepositoryPath: nil
        )

        await viewModel.performFileOperation(.stage, path: "file.txt", context: context)

        assertEqual(
            service.operationRequests.map(\.description), ["stage-/tmp/worktree-file.txt"],
            "file operation uses resolved root and row path")
        assertEqual(viewModel.state, refreshed, "file operation publishes refreshed status immediately")
    }

    @Test
    @MainActor
    func canceledDestructiveFileOperationDoesNotMutateState() async {
        let service = FakeStatusService(result: .idle)
        let confirmation = RecordingFileOperationConfirmer(shouldConfirm: false)
        let viewModel = GitStatusViewModel(service: service, fileOperationConfirmer: confirmation)
        let context = GitStatusRootContext(
            kind: .standalone,
            currentDirectory: "/tmp/repo",
            worktreePath: nil,
            projectRepositoryPath: nil
        )

        await viewModel.confirmAndPerformFileOperation(.discard, paths: ["file.txt"], context: context)

        assertEqual(confirmation.requests, [.discard], "destructive operation asks for confirmation")
        assertEqual(
            service.bulkOperationRequests.isEmpty, true,
            "canceled destructive operation does not call git")
        assertEqual(
            viewModel.state, .idle, "canceled destructive operation leaves sidebar state unchanged")
    }

    @Test
    @MainActor
    func confirmedDestructiveFileOperationRunsAndRefreshes() async {
        let refreshed = GitStatusLoadState.loaded(
            GitStatusSummary(
                rootPath: "/tmp/repo",
                branchName: "main",
                upstreamName: nil,
                aheadCount: 0,
                behindCount: 0
            ))
        let service = FakeStatusService(result: .idle, operationResult: refreshed)
        let confirmation = RecordingFileOperationConfirmer(shouldConfirm: true)
        let viewModel = GitStatusViewModel(service: service, fileOperationConfirmer: confirmation)
        let context = GitStatusRootContext(
            kind: .standalone,
            currentDirectory: "/tmp/repo",
            worktreePath: nil,
            projectRepositoryPath: nil
        )

        await viewModel.confirmAndPerformFileOperation(
            .delete, paths: ["scratch.txt"], context: context)

        assertEqual(confirmation.requests, [.delete], "confirmed delete asks for confirmation")
        assertEqual(
            service.bulkOperationRequests.map(\.description),
            ["delete-/tmp/repo-scratch.txt"], "confirmed delete runs as a bulk operation")
        assertEqual(
            viewModel.state, refreshed, "confirmed destructive operation publishes refreshed status")
    }
}

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

        assertEqual(
            service.bulkOperationRequests.isEmpty, true,
            "capped section bulk actions do not operate only on displayed file paths")
        assertEqual(
            service.sectionOperationRequests.map(\.description),
            ["stage-/tmp/repo-untracked"], "bulk action operates on the whole git section")
        assertEqual(viewModel.state, refreshed, "section bulk operation publishes refreshed status")
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

        assertEqual(viewModel.state, current, "bulk operation keeps loaded sidebar content visible")
        assertEqual(viewModel.isRefreshing, true, "bulk operation shows non-disruptive refresh progress")
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

        assertEqual(
            confirmation.requests, [.delete], "destructive section action asks for confirmation")
        assertEqual(
            confirmation.pathCountRequests, [501],
            "destructive section confirmation uses total section count, not capped row count")
        assertEqual(
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

        assertEqual(
            previewService.requests.map(\.description),
            ["diff-/tmp/worktree-file.txt"], "preview uses resolved status root and selected row")
        assertEqual(
            result,
            .loaded(
                GitPreview(
                    kind: .diff,
                    path: "file.txt",
                    content: .diff(
                        GitDiffPreview(
                            fileName: "file.txt", oldContent: "old", newContent: "new")))),
            "loaded preview is returned for tab presentation")
        assertEqual(viewModel.state, .idle, "preview does not replace git status state")
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

        assertEqual(
            result, .failed(kind: .blame, path: "missing.txt", message: "fatal: no such path"),
            "preview failure is returned for tab presentation")
        assertEqual(viewModel.state, current, "preview failure does not replace loaded status state")
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

        assertEqual(
            observedLoading, true, "automatic refresh exposes loading state before service returns")
        assertEqual(viewModel.state, loaded, "automatic refresh publishes final status")
    }

}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    #expect(actual == expected, Comment(rawValue: message))
}
