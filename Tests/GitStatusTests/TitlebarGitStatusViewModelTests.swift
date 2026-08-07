import Foundation
import Testing

@testable import Argus

@Suite
struct TitlebarGitStatusViewModelTests {
    @Test
    @MainActor
    func titlebarMetadataIsScopedToRefreshedWorkspace() async {
        let workspaceA = UUID()
        let workspaceB = UUID()
        let service = TitlebarFakeStatusService(
            result: .loaded(
                GitStatusSummary(
                    rootPath: "/tmp/worktree-a",
                    branchName: "feature/a",
                    upstreamName: "origin/feature/a",
                    aheadCount: 1,
                    behindCount: 0
                )))
        let viewModel = GitStatusViewModel(service: service)
        let context = GitStatusRootContext(
            kind: .worktree,
            currentDirectory: "/tmp/worktree-a/subdir",
            worktreePath: "/tmp/worktree-a",
            projectRepositoryPath: nil
        )

        await viewModel.refresh(workspaceId: workspaceA, context: context)

        assertEqual(
            viewModel.titlebarGitContext(for: workspaceA)?.visibleText, "feature/a ↑1 ↓0",
            "refreshed workspace exposes titlebar git metadata")
        assertEqual(
            viewModel.titlebarGitContext(for: workspaceB), nil,
            "different active workspace does not reuse stale titlebar git metadata")
    }

    @Test
    @MainActor
    func automaticRefreshKeepsNotRepositoryContentVisible() async {
        let notRepository = GitStatusLoadState.notRepository(rootPath: "/Users/test")
        let observation = GitStatusRefreshObservation()
        let service = ObservingStatusService(result: notRepository) {
            observation.requestCount += 1
            guard observation.requestCount == 2 else { return }
            observation.stateDuringRefresh = observation.viewModel?.state
            observation.wasRefreshing = observation.viewModel?.isRefreshing ?? false
        }
        let viewModel = GitStatusViewModel(service: service)
        observation.viewModel = viewModel
        let context = GitStatusRootContext(
            kind: .standalone,
            currentDirectory: "/Users/test",
            worktreePath: nil,
            projectRepositoryPath: nil
        )

        await viewModel.refresh(context: context)
        await viewModel.refresh(context: context)

        assertEqual(
            observation.stateDuringRefresh,
            notRepository,
            "automatic refresh keeps current not-repository content visible")
        assertEqual(observation.wasRefreshing, true, "automatic refresh still exposes progress")
        assertEqual(viewModel.state, notRepository, "refresh republishes not-repository status")
    }

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }
}

@MainActor
private final class GitStatusRefreshObservation {
    weak var viewModel: GitStatusViewModel?
    var requestCount = 0
    var stateDuringRefresh: GitStatusLoadState?
    var wasRefreshing = false
}

private final class TitlebarFakeStatusService: GitStatusProviding, @unchecked Sendable {
    let result: GitStatusLoadState
    private(set) var requestedRoots: [String] = []

    init(result: GitStatusLoadState) {
        self.result = result
    }

    func status(rootPath: String) async -> GitStatusLoadState {
        requestedRoots.append(rootPath)
        return result
    }

    func initializeRepository(rootPath: String) async -> GitStatusLoadState {
        result
    }

    func performFileOperation(_ operation: GitStatusFileOperation, rootPath: String, path: String)
        async -> GitStatusLoadState
    {
        result
    }

    func performBulkFileOperation(
        _ operation: GitStatusFileOperation, rootPath: String, paths: [String]
    ) async -> GitStatusLoadState {
        result
    }
}
