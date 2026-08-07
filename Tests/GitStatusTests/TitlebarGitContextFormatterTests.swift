import Foundation
import Testing

@testable import Argus

@Suite
struct TitlebarGitContextFormatterTests {
    @Test
    func loadedBranchFormatsForVisibleTitlebarAndWindowTitle() {
        let context = TitlebarGitContextFormatter.context(
            from: .loaded(
                GitStatusSummary(
                    rootPath: "/repo",
                    branchName: "feature/titlebar",
                    upstreamName: nil,
                    aheadCount: 0,
                    behindCount: 0
                )))

        assertEqual(
            context?.visibleText, "feature/titlebar", "branch appears in visible titlebar git metadata")
        assertEqual(
            context?.windowTitleText, "feature/titlebar",
            "branch appears in macOS window title git metadata")
    }

    @Test
    func dirtyStatusAddsIndicator() {
        let context = TitlebarGitContextFormatter.context(
            from: .loaded(
                GitStatusSummary(
                    rootPath: "/repo",
                    branchName: "main",
                    upstreamName: nil,
                    aheadCount: 0,
                    behindCount: 0,
                    unstagedCount: 1
                )))

        assertEqual(
            context?.visibleText, "main •", "dirty titlebar metadata includes a visible indicator")
        assertEqual(
            context?.windowTitleText, "main dirty",
            "dirty window title metadata is screen-reader friendly")
    }

    @Test
    func dirtyStatusWithoutBranchStillAddsIndicator() {
        let context = TitlebarGitContextFormatter.context(
            from: .loaded(
                GitStatusSummary(
                    rootPath: "/repo",
                    branchName: nil,
                    upstreamName: nil,
                    aheadCount: 0,
                    behindCount: 0,
                    unstagedCount: 1
                )))

        assertEqual(
            context?.visibleText, "•", "dirty detached titlebar metadata includes a visible indicator")
        assertEqual(
            context?.windowTitleText, "dirty",
            "dirty detached window title metadata is screen-reader friendly")
    }

    @Test
    func cleanStatusWithoutBranchDoesNotExposeMetadata() {
        let context = TitlebarGitContextFormatter.context(
            from: .loaded(
                GitStatusSummary(
                    rootPath: "/repo",
                    branchName: nil,
                    upstreamName: nil,
                    aheadCount: 0,
                    behindCount: 0
                )))

        assertEqual(context, nil, "clean status without branch has no titlebar git metadata")
    }

    @Test
    func upstreamTrackingAddsAheadBehindCounts() {
        let context = TitlebarGitContextFormatter.context(
            from: .loaded(
                GitStatusSummary(
                    rootPath: "/repo",
                    branchName: "main",
                    upstreamName: "origin/main",
                    aheadCount: 2,
                    behindCount: 1
                )))

        assertEqual(
            context?.visibleText, "main ↑2 ↓1", "titlebar metadata includes ahead and behind counts")
        assertEqual(
            context?.windowTitleText, "main ahead 2 behind 1",
            "window title metadata includes ahead and behind counts")
    }

    @Test
    func nonLoadedStatesDoNotExposeStaleMetadata() {
        assertEqual(
            TitlebarGitContextFormatter.context(from: .loading), nil,
            "loading state clears stale titlebar metadata")
        assertEqual(
            TitlebarGitContextFormatter.context(from: .notRepository(rootPath: "/repo")), nil,
            "not-repository state clears stale titlebar metadata")
        assertEqual(
            TitlebarGitContextFormatter.context(from: .error(rootPath: "/repo", message: "boom")), nil,
            "error state clears stale titlebar metadata")
    }

    @Test
    func workspaceTitleIncludesGitContextForWindowTitle() {
        let title = WorkspaceTitleFormatter.title(
            workspaceTitle: "Feature UI",
            contextName: "Argus",
            gitContext: "feature/ui dirty ahead 2 behind 1"
        )

        assertEqual(
            title, "Feature UI — Argus — feature/ui dirty ahead 2 behind 1",
            "window title reflects visible titlebar git context")
    }

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }
}
