import AppKit
import SwiftUI
import Testing

@testable import Argus

@Suite
@MainActor
struct PullRequestStatusPresentationTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    @Test(arguments: [
        (AgentStatusState?.none, SidebarWorkspaceIcon.workspaceType, SidebarWorkspaceIcon.pullRequest),
        (.idle, .agent(.idle), .pullRequest),
        (.running, .agent(.running), .agent(.running)),
        (.needsInput, .agent(.needsInput), .agent(.needsInput)),
        (.error, .agent(.error), .agent(.error))
    ])
    func sharedIconUsesAttentionThenNonIdleAgentThenPullRequestThenIdleThenType(
        agentState: AgentStatusState?, withoutPullRequest: SidebarWorkspaceIcon, withPullRequest: SidebarWorkspaceIcon
    ) {
        let scenarios = [(false, withoutPullRequest), (true, withPullRequest)]
        for (showsPullRequestStatus, expectedWithoutAttention) in scenarios {
            for hasAttention in [false, true] {
                let icon = SidebarWorkspaceIcon(
                    hasAttention: hasAttention, agentState: agentState, showsPullRequestStatus: showsPullRequestStatus)

                #expect(
                    icon == (hasAttention ? .attention : expectedWithoutAttention),
                    Comment(
                        rawValue: "Attention: \(hasAttention), Agent Status: \(String(describing: agentState)), "
                            + "Pull Request: \(showsPullRequestStatus)")
                )
            }
        }
    }

    @Test(arguments: [
        (
            PullRequestChecks(failed: 1, pending: 1), PullRequestReviewDecision.changesRequested,
            Optional(PullRequestStatusSignal.failedChecks)
        ),
        (PullRequestChecks(failed: 1), .approved, .failedChecks),
        (PullRequestChecks(pending: 1), .changesRequested, .changesRequested),
        (PullRequestChecks.unavailable, .changesRequested, .changesRequested),
        (PullRequestChecks(pending: 1), .approved, .pendingChecks),
        (PullRequestChecks(passed: 1), .approved, .approved),
        (PullRequestChecks(passed: 1), .required, nil),
        (PullRequestChecks(), .none, nil)
    ])
    func checkAndReviewSignalsUseActionablePrecedence(
        checks: PullRequestChecks, review: PullRequestReviewDecision, expected: PullRequestStatusSignal?
    ) {
        let state = WorkspacePullRequestState(
            status: status(review: review, checks: checks), lastSuccess: date, hasLoaded: true)

        #expect(PullRequestStatusPresentation(state: state, date: date).signal == expected)
    }

    @Test(arguments: [PullRequestLifecycle.open, .draft])
    func failedChecksRemainSeparateFromLifecycle(lifecycle: PullRequestLifecycle) {
        let state = WorkspacePullRequestState(
            status: status(lifecycle: lifecycle, checks: PullRequestChecks(failed: 1)),
            lastSuccess: date, hasLoaded: true)
        let presentation = PullRequestStatusPresentation(state: state, date: date)

        #expect(presentation.title == "#42 · \(lifecycle.label)")
        #expect(presentation.signal == .failedChecks)
        #expect(presentation.help.contains("1 failed"))
    }

    @Test(arguments: [PullRequestLifecycle.merged, .closed])
    func completedLifecycleSuppressesCheckSignalsButNotStaleness(lifecycle: PullRequestLifecycle) {
        let state = WorkspacePullRequestState(
            status: status(lifecycle: lifecycle, review: .changesRequested, checks: PullRequestChecks(failed: 1)),
            lastSuccess: date, hasLoaded: true)
        let fresh = PullRequestStatusPresentation(state: state, date: date)
        let stale = PullRequestStatusPresentation(state: state, date: date.addingTimeInterval(661))

        #expect(fresh.signal == nil)
        #expect(stale.signal == .stale)
        #expect(stale.title == fresh.title)
        #expect(stale.help.contains(lifecycle.label))
    }

    @Test(arguments: [
        (PullRequestChecks.unavailable, PullRequestReviewDecision.approved),
        (PullRequestChecks(passed: 1, unknown: 1), .approved),
        (PullRequestChecks(passed: 1), .unavailable)
    ])
    func incompleteDataNeverPresentsApproval(checks: PullRequestChecks, review: PullRequestReviewDecision) {
        let state = WorkspacePullRequestState(
            status: status(review: review, checks: checks), lastSuccess: date, hasLoaded: true)
        let presentation = PullRequestStatusPresentation(state: state, date: date)

        #expect(presentation.signal == .unavailable)
        #expect(presentation.help.contains(checks.summary))
        #expect(presentation.help.contains(review.label))
    }

    @Test(arguments: [
        (WorkspacePullRequestState(), "Pull Request not checked", false, true),
        (WorkspacePullRequestState(isRefreshing: true), "Pull Request not checked", false, false),
        (WorkspacePullRequestState(hasLoaded: true), "No Pull Request", false, true),
        (WorkspacePullRequestState(isRefreshing: true, hasLoaded: true), "No Pull Request", false, false),
        (
            WorkspacePullRequestState(error: .unauthenticated, hasLoaded: true),
            "Pull Request status unavailable", true, true
        ),
        (
            WorkspacePullRequestState(isRefreshing: true, error: .unauthenticated, hasLoaded: true),
            "Pull Request status unavailable", true, false
        )
    ])
    func noMatchAndErrorsRemainDistinctWithoutLoadingIndicators(
        state: WorkspacePullRequestState, title: String, showsIcon: Bool, canRefresh: Bool
    ) {
        let presentation = PullRequestStatusPresentation(state: state, date: date)

        #expect(presentation.title == title)
        #expect(presentation.showsIcon == showsIcon)
        #expect(presentation.canRefresh == canRefresh)
        #expect(presentation.signal == nil)
        #expect(!presentation.isStale)
        let icon = SidebarWorkspaceIcon(
            hasAttention: false, agentState: .idle, showsPullRequestStatus: presentation.showsIcon)
        #expect(icon == (showsIcon ? .pullRequest : .agent(.idle)))
        if let error = state.error { #expect(presentation.help.contains(error.localizedDescription)) }
    }

    @Test
    func refreshAndFailureRetainLastKnownContentAndExplainFreshness() {
        let loaded = status()
        var state = WorkspacePullRequestState(
            status: loaded, isRefreshing: true, lastSuccess: date, hasLoaded: true)
        let refreshing = PullRequestStatusPresentation(state: state, date: date)

        #expect(refreshing.showsIcon)
        #expect(!refreshing.canRefresh)
        #expect(refreshing.title == "#42 · Open")
        #expect(refreshing.signal == .approved)
        for detail in [loaded.title, loaded.review.label, loaded.checks.summary, "Last checked"] {
            #expect(refreshing.help.contains(detail))
        }
        state.isRefreshing = false
        let idle = PullRequestStatusPresentation(state: state, date: date)
        #expect(refreshing.title == idle.title)
        #expect(refreshing.help == idle.help)
        #expect(refreshing.signal == idle.signal)
        state.error = .providerTimedOut
        let failed = PullRequestStatusPresentation(state: state, date: date)
        #expect(failed.title == refreshing.title)
        #expect(failed.signal == .stale)
        #expect(failed.help.contains("Stale"))
        #expect(failed.help.contains(PullRequestStatusError.providerTimedOut.localizedDescription))
        #expect(failed.canRefresh)
    }

    @Test(arguments: [(TimeInterval?(0), false), (600, false), (660, false), (660.001, true), (nil, true)])
    func freshnessAllowsTheBackgroundIntervalOrRequiresSuccess(elapsed: TimeInterval?, isStale: Bool) {
        let state = WorkspacePullRequestState(
            status: status(), lastSuccess: elapsed.map { date.addingTimeInterval(-$0) }, hasLoaded: true)
        let presentation = PullRequestStatusPresentation(state: state, date: date)

        #expect(presentation.isStale == isStale)
        #expect(presentation.signal == (isStale ? .stale : .approved))
        #expect(presentation.help.contains("Stale") == isStale)
    }

    @Test
    func rateLimitBlocksRefreshUntilResetAndLoadingStillBlocksItAfterward() {
        let retryAfter = date.addingTimeInterval(60)
        var state = WorkspacePullRequestState(error: .rateLimited(retryAfter: retryAfter), hasLoaded: true)

        #expect(!PullRequestStatusPresentation(state: state, date: date).canRefresh)
        #expect(PullRequestStatusPresentation(state: state, date: retryAfter).canRefresh)
        #expect(PullRequestStatusPresentation(state: state, date: retryAfter.addingTimeInterval(1)).canRefresh)
        state.isRefreshing = true
        #expect(!PullRequestStatusPresentation(state: state, date: retryAfter).canRefresh)
        state.isRefreshing = false
        state.error = .rateLimited(retryAfter: nil)
        #expect(PullRequestStatusPresentation(state: state, date: date).canRefresh)
    }

    @Test
    func quotaAndSecondaryLimitsDisableManualRefreshUntilTheDeadline() {
        let deadline = date.addingTimeInterval(600)
        for error in [
            PullRequestStatusError.quotaPaused(until: deadline),
            .secondaryRateLimited(retryAfter: deadline)
        ] {
            let state = WorkspacePullRequestState(status: status(), lastSuccess: date, error: error, hasLoaded: true)
            let presentation = PullRequestStatusPresentation(state: state, date: date)
            #expect(!presentation.canRefresh)
            #expect(presentation.signal == .stale)
            #expect(presentation.help.contains("resume at"))
            #expect(PullRequestStatusPresentation(state: state, date: deadline).canRefresh)
        }
    }

    @Test
    func everyLifecycleAndSignalUsesAnAvailableSystemSymbol() {
        let lifecycles: [PullRequestLifecycle] = [.open, .draft, .merged, .closed]
        let signals: [PullRequestStatusSignal] = [
            .failedChecks, .changesRequested, .pendingChecks, .approved, .unavailable, .stale
        ]
        for symbol in lifecycles.map(\.symbolName) + signals.map(\.symbolName) {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, Comment(rawValue: symbol))
        }
    }

    @Test(arguments: [PullRequestLifecycle.open, .draft, .merged, .closed])
    func iconKeepsItsCompactFootprintWithoutRenderingTheNumber(lifecycle: PullRequestLifecycle) throws {
        let first = try iconBitmap(number: 42, lifecycle: lifecycle)
        let second = try iconBitmap(number: 58_130, lifecycle: lifecycle)

        #expect(first.pixelsWide == 40)
        #expect(first.pixelsHigh == 40)
        #expect(first.pixelsWide == second.pixelsWide)
        #expect(first.pixelsHigh == second.pixelsHigh)
        let firstPNG = try #require(first.representation(using: .png, properties: [:]))
        let secondPNG = try #require(second.representation(using: .png, properties: [:]))
        #expect(firstPNG == secondPNG)
        #expect(
            (0..<first.pixelsWide).contains { x in
                (0..<first.pixelsHigh).contains { y in
                    (first.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1
                }
            })
    }

    private func iconBitmap(number: Int, lifecycle: PullRequestLifecycle) throws -> NSBitmapImageRep {
        let state = WorkspacePullRequestState(
            status: status(number: number, lifecycle: lifecycle, review: .required),
            lastSuccess: date, hasLoaded: true)
        let renderer = ImageRenderer(
            content: PullRequestStatusIcon(
                presentation: PullRequestStatusPresentation(state: state, date: date), onInspect: {}
            )
            .environment(\.locale, Locale(identifier: "nl_NL"))
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }

    private func status(
        number: Int = 42,
        lifecycle: PullRequestLifecycle = .open,
        review: PullRequestReviewDecision = .approved,
        checks: PullRequestChecks = PullRequestChecks(passed: 2)
    ) -> PullRequestStatus {
        let repository = RepositoryIdentity(
            provider: .github, host: "reviews.invalid", owner: "team", repositoryName: "argus")
        return PullRequestStatus(
            identity: PullRequestIdentity(repository: repository, number: number),
            url: URL(string: "https://reviews.invalid/team/argus/pull/\(number)")!,
            title: "Keep Pull Request status separate from local Changes",
            headBranchName: "feature/status", headCommitObjectID: String(repeating: "a", count: 40),
            headRepository: repository, baseBranchName: "main", lifecycle: lifecycle, review: review, checks: checks)
    }
}
