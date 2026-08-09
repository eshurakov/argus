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

        assertViewModelEqual(service.requestedRoots, ["/tmp/worktree"], "refresh uses resolved worktree root")
        assertViewModelEqual(viewModel.state, service.result, "refresh publishes loaded state")
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

        assertViewModelEqual(service.initializedRoots, ["/tmp/new-repo"], "initialize uses resolved root")
        assertViewModelEqual(viewModel.state, loaded, "successful initialize publishes refreshed clean status")
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

        assertViewModelEqual(
            clipboard.copiedPaths, ["Sources/App/File.swift"], "copy-path copies the displayed row path")
        assertViewModelEqual(service.operationRequests.isEmpty, true, "copy-path does not run a git operation")
        assertViewModelEqual(service.requestedRoots.isEmpty, true, "copy-path does not refresh git state")
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

        assertViewModelEqual(
            service.operationRequests.map(\.description), ["stage-/tmp/worktree-file.txt"],
            "file operation uses resolved root and row path")
        assertViewModelEqual(viewModel.state, refreshed, "file operation publishes refreshed status immediately")
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

        assertViewModelEqual(confirmation.requests, [.discard], "destructive operation asks for confirmation")
        assertViewModelEqual(
            service.bulkOperationRequests.isEmpty, true,
            "canceled destructive operation does not call git")
        assertViewModelEqual(
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

        assertViewModelEqual(confirmation.requests, [.delete], "confirmed delete asks for confirmation")
        assertViewModelEqual(
            service.bulkOperationRequests.map(\.description),
            ["delete-/tmp/repo-scratch.txt"], "confirmed delete runs as a bulk operation")
        assertViewModelEqual(
            viewModel.state, refreshed, "confirmed destructive operation publishes refreshed status")
    }

    @Test
    @MainActor
    func requestIdentityIncludesPresentationAndConfiguredBase() async {
        let service = RequestRecordingStatusService(
            result: .loaded(
                GitStatusSummary(
                    rootPath: "/tmp/repo",
                    branchName: "feature",
                    upstreamName: nil,
                    aheadCount: 0,
                    behindCount: 0
                )))
        let viewModel = GitStatusViewModel(service: service)
        let workspaceId = UUID()
        let context = GitStatusRootContext(
            kind: .worktree,
            currentDirectory: "/tmp/repo",
            worktreePath: "/tmp/repo",
            projectRepositoryPath: nil,
            configuredBaseBranch: "main"
        )

        let classic = viewModel.owner(workspaceId: workspaceId, context: context)
        let combined = viewModel.owner(
            workspaceId: workspaceId,
            context: context,
            presentation: GitStatusPresentation(combineWorkingChangeSections: true)
        )
        let base = viewModel.owner(
            workspaceId: workspaceId,
            context: context,
            presentation: GitStatusPresentation(showBaseBranchChanges: true)
        )

        assertViewModelEqual(classic != combined, true, "combination setting changes snapshot owner")
        assertViewModelEqual(classic != base, true, "base setting changes snapshot owner")
        assertViewModelEqual(
            classic.request.presentation.configuredBaseBranch, "main", "owner carries Project base branch")

        await viewModel.refresh(owner: classic)
        await viewModel.refresh(owner: combined)
        assertViewModelEqual(
            service.requests.map(\.presentation),
            [classic.request.presentation, combined.request.presentation],
            "status refreshes carry the complete request presentation"
        )
    }
}

private func assertViewModelEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    #expect(actual == expected, Comment(rawValue: message))
}

private final class RequestRecordingStatusService: GitStatusProviding, @unchecked Sendable {
    let result: GitStatusLoadState
    private(set) var requests: [GitStatusRequest] = []

    init(result: GitStatusLoadState) {
        self.result = result
    }

    func status(rootPath: String) async -> GitStatusLoadState { result }

    func status(request: GitStatusRequest) async -> GitStatusLoadState {
        requests.append(request)
        return result
    }

    func initializeRepository(rootPath: String) async -> GitStatusLoadState { result }

    func performFileOperation(
        _ operation: GitStatusFileOperation,
        rootPath: String,
        path: String
    ) async -> GitStatusLoadState { result }

    func performBulkFileOperation(
        _ operation: GitStatusFileOperation,
        rootPath: String,
        paths: [String]
    ) async -> GitStatusLoadState { result }

    func performSectionFileOperation(
        _ operation: GitStatusFileOperation,
        rootPath: String,
        sectionKey: String
    ) async -> GitStatusLoadState { result }
}
