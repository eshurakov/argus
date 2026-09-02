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
        for (showsPullRequestStatus, expectedWithoutAttention) in [(false, withoutPullRequest), (true, withPullRequest)]
        {
            for hasAttention in [false, true] {
                let icon = SidebarWorkspaceIcon(
                    hasAttention: hasAttention, agentState: agentState, showsPullRequestStatus: showsPullRequestStatus)

                #expect(
                    icon == (hasAttention ? .attention : expectedWithoutAttention),
                    "Attention: \(hasAttention), Agent Status: \(String(describing: agentState)), Pull Request: \(showsPullRequestStatus)"
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

@Suite
struct PullRequestStatusUIContractTests {
    @Test
    func sharedLeadingIconIsAStableSiblingOfWorkspaceSelection() throws {
        let row = try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift")
        let body = try row.section(after: "var body: some View", before: "private var workspaceRowButton")
        let selection = try row.section(after: "private var workspaceRowButton", before: "private var workspaceLabels")
        let icon = try row.section(
            after: "private var workspaceIcon: some View", before: "private var showsShortcutOverlay")

        for fragment in [
            "ZStack(alignment: workspaceIconAlignment)", "workspaceRowButton", "if showsPullRequestIcon",
            "PullRequestStatusIcon("
        ] {
            #expect(body.contains(fragment), Comment(rawValue: fragment))
        }
        #expect(!body.contains("Button(action: onSelect)"))
        #expect(selection.contains("Button(action: onSelect)"))
        #expect(!selection.contains("PullRequestStatusIcon"))
        row.excludes("pullRequestBadgeWidth", "Pull Request Status must not reserve trailing label space")
        for fragment in [
            "switch workspaceIconKind", "case .attention:", "case .agent(let state):", "case .pullRequest:",
            "workspace.workspaceType.icon", ".frame(width: 20, height: 20)",
            ".alignmentGuide(workspaceIconAlignment.horizontal)", ".alignmentGuide(workspaceIconAlignment.vertical)"
        ] {
            #expect(icon.contains(fragment), Comment(rawValue: fragment))
        }
        row.containsAll(
            [
                "hasAttention: hasAttention", "agentState: agentStatus?.state",
                "&& PullRequestStatusPresentation(state: pullRequestState, date: .now).showsIcon",
                "workspaceIconKind == .pullRequest && !showsShortcutOverlay"
            ], "shared precedence and Command digits control whether the inspection target exists")
    }

    @Test
    func inspectionOffersHoverHelpKeyboardFocusAndNativePopoverDismissal() throws {
        let source = try SourceContract("Argus/Views/Sidebar/PullRequestStatusView.swift")
        let icon = try source.section(after: "struct PullRequestStatusIcon", before: "struct PullRequestStatusSummary")
        for fragment in [
            "Button(action: onInspect)", "ChromeColors.hoveredTabFill", ".onHover", ".contentShape(Rectangle())",
            ".cursor(.pointingHand)", ".help(\"Show Pull Request status.",
            ".accessibilityLabel(\"Show Pull Request status\")",
            ".accessibilityValue(presentation.help)", ".frame(width: 20, height: 20)",
            ".opacity(presentation.showsIcon ? 1 : 0)", ".allowsHitTesting(presentation.showsIcon)",
            ".accessibilityHidden(!presentation.showsIcon)", "if let signal = presentation.signal",
            "else if let status = presentation.state.status"
        ] {
            #expect(icon.contains(fragment), Comment(rawValue: fragment))
        }
        #expect(!icon.contains("Text("))
        #expect(!icon.contains("ProgressView"))
        try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift").containsAll(
            [
                ".focused($isPullRequestIconFocused)", ".focused($isFocused)",
                ".popover(isPresented: $showsPullRequestSummary", "PullRequestStatusSummary(",
                "case .icon:", "if showsPullRequestIcon", "isPullRequestIconFocused = true",
                "case .row: isFocused = true", "summaryReturnFocus = .none", "case .none: break",
                ".onChange(of: showsPullRequestIcon)",
                "if !isShown, isPullRequestIconFocused, !showsPullRequestSummary { isFocused = true }"
            ], "inspection restores its trigger without stealing focus from an open popover or the system browser")
        source.contains(".onExitCommand(perform: onClose)", "Escape dismisses the native summary")
    }

    @Test
    func refreshProgressBelongsOnlyToTheInvokingPopover() throws {
        let source = try SourceContract("Argus/Views/Sidebar/PullRequestStatusView.swift")
        let header = try source.section(after: "private func header(", before: "private func loadedContent(")
        #expect(!header.contains("ProgressView"))
        let actions = try source.section(after: "private func actions(", before: "struct PullRequestStatusMenuItems")
        #expect(actions.contains("if showsRefreshProgress && presentation.state.isRefreshing"))
        #expect(actions.contains("ProgressView()"))
        #expect(actions.contains(".accessibilityLabel(\"Refreshing Pull Request status\")"))
        let request = try #require(actions.range(of: "model.refresh(workspaceID: workspaceID)"))
        let progress = try #require(
            actions.range(of: "showsRefreshProgress = model.state(for: workspaceID)?.isRefreshing == true"))
        #expect(request.upperBound < progress.lowerBound)
        let completion = try source.section(after: ".onReceive(model.$states)", before: ".onDisappear")
        #expect(completion.contains("states[workspaceID]?.isRefreshing != true"))
        #expect(completion.contains("showsRefreshProgress = false"))
        #expect(!completion.contains("model.state("))
        #expect(!completion.contains("showsRefreshProgress = true"))
        source.containsAll(
            [
                "@State private var showsRefreshProgress = false",
                ".onDisappear { showsRefreshProgress = false }",
                ".onChange(of: workspaceID) { _, _ in showsRefreshProgress = false }"
            ], "manual refresh progress stays local to its popover and resets on dismissal or replacement")
    }

    @Test
    func summaryKeepsStatusAndActionsWithoutRepositoryOrBranchDetails() throws {
        let source = try SourceContract("Argus/Views/Sidebar/PullRequestStatusView.swift")
        let summary = try source.section(
            after: "struct PullRequestStatusSummary", before: "struct PullRequestStatusMenuItems")
        for fragment in [
            "Text(presentation.title)", "Text(status.title)", "status.lifecycle.symbolName",
            "Text(\"Review: \\(status.review.label)\")", "Text(\"Checks: \\(status.checks.summary)\")",
            "Text(error.localizedDescription)", "Stale — showing last known status", "Last checked",
            "Button(\"Open Pull Request\")", "Button(\"Copy URL\")", "Button(\"Refresh\")",
            ".help(\"Open Pull Request in the default system browser\")", ".textSelection(.enabled)"
        ] {
            #expect(summary.contains(fragment), Comment(rawValue: fragment))
        }
        for fragment in ["identity.repository", "headBranchName", "baseBranchName", "branchRow("] {
            #expect(!summary.contains(fragment), Comment(rawValue: fragment))
        }
        let navigation = try SourceContract("Argus/Services/WorkspaceManager+PullRequestStatus.swift")
        navigation.contains("NSWorkspace.shared.open", "the default action delegates to the system browser")
        navigation.excludes("selectWorkspace(", "opening externally must not change Workspace selection")
        navigation.excludes("addBrowserPanel(", "opening externally must not create an embedded Browser Tab")
    }

    @Test
    func noMatchKeepsContextualInspectionAndRetryWithoutNavigating() throws {
        let source = try SourceContract("Argus/Views/Sidebar/PullRequestStatusView.swift")
        let menu = try source.section(
            after: "struct PullRequestStatusMenuItems", before: "if let status = state.status")
        for fragment in [
            "Button(\"Show Pull Request Status\")", "Button(\"Refresh Pull Request Status\")",
            "name: .showPullRequestStatus, object: workspaceID", "model.refresh(workspaceID: workspaceID)",
            ".canRefresh", "!model.isActive"
        ] {
            #expect(menu.contains(fragment), Comment(rawValue: fragment))
        }
        #expect(!menu.contains("showsIcon"))
        #expect(!menu.contains("selectWorkspace"))
        #expect(!menu.contains("openPullRequest"))
        let project = try SourceContract("Argus/Views/Sidebar/SidebarView+Projects.swift")
        let gate = try project.section(after: "if appSettings.showPullRequestStatus", before: "Button(\"Copy Path\")")
        #expect(gate.contains("!project.isCatchAll"))
        #expect(gate.contains("workspace.workspaceType == .worktree"))
        #expect(gate.contains("PullRequestStatusMenuItems(workspaceID: workspace.id)"))
        #expect(!gate.contains(".status"))
        let row = try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift")
        let inspection = try row.section(
            after: ".onReceive(NotificationCenter.default.publisher(for: .showPullRequestStatus))",
            before: "private var workspaceRowButton")
        #expect(inspection.contains("showsPullRequestStatus"))
        #expect(inspection.contains("summaryReturnFocus = .row"))
        #expect(!inspection.contains("showsPullRequestIcon"))
    }

    @Test
    func windowOwnsStatusLifecycleOutsideConditionalSidebars() throws {
        let window = try SourceContract("Argus/Views/MainWindowView.swift")
        window.containsAll(
            [
                "@StateObject private var pullRequestStatusModel = WorkspacePullRequestStatusModel()",
                ".environmentObject(pullRequestStatusModel)"
            ], "one window-owned model supplies rows and popovers")
        let layout = try window.section(after: "struct MainWindowView:", before: ".frame(minWidth:")
        #expect(layout.contains("if sidebarState.isVisible"))
        #expect(layout.contains("if gitSidebarState.isVisible"))
        #expect(!layout.contains("WorkspacePullRequestStatusLifecycle("))
        let lifecycle = try window.section(
            after: "WorkspacePullRequestStatusLifecycle(", before: ".environment(windowFocus)")
        for fragment in [
            "model: pullRequestStatusModel", "targets: workspaceManager.pullRequestStatusTargets",
            "selectedWorkspaceID: workspaceManager.selectedWorkspaceId", "isEnabled: appSettings.showPullRequestStatus",
            ".allowsHitTesting(false)", ".accessibilityHidden(true)"
        ] {
            #expect(lifecycle.contains(fragment), Comment(rawValue: fragment))
        }
    }

    @Test
    func lifecyclePausesForWindowApplicationSleepAndTestInstanceState() throws {
        try SourceContract("Argus/Views/WorkspacePullRequestStatusLifecycle.swift").containsAll(
            [
                "NSApplication.didBecomeActiveNotification", "NSApplication.didResignActiveNotification",
                "NSApplication.didHideNotification", "NSApplication.didUnhideNotification",
                "NSWindow.didMiniaturizeNotification", "NSWindow.didDeminiaturizeNotification",
                "NSWorkspace.willSleepNotification", "NSWorkspace.didWakeNotification",
                "environment[\"XCTestConfigurationFilePath\"] != nil", "environment[\"ARGUS_UNDER_TEST\"] == \"1\"",
                "environment[\"ARGUS_DISABLE_SESSION_RESTORE\"] == \"1\"", "!isTest", "!isSleeping",
                "NSApp.isActive", "!NSApp.isHidden", "window?.isVisible == true", "window?.isMiniaturized == false",
                "isActive: active", "isActive: false", "nsView.detach()", "updateTask?.cancel()", "model?.stop()",
                "removeObservers()"
            ], "the window bridge owns scheduling and never starts provider work in a test instance")
    }

    @Test
    func timelineRenderingDoesNoIOAndStatusRefreshDoesNotChangeFocus() throws {
        let row = try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift")
        let summary = try SourceContract("Argus/Views/Sidebar/PullRequestStatusView.swift")
        let timelines = [
            try row.section(after: "TimelineView(", before: ".popover("),
            try summary.section(after: "TimelineView(", before: ".onExitCommand(")
        ]
        for timeline in timelines {
            #expect(timeline.contains("context.date"))
            for fragment in [
                ".refresh(", ".update(", ".tick(", "GitHubPullRequestService(", "URLSession", "Process(", ".task"
            ] {
                #expect(!timeline.contains(fragment), Comment(rawValue: fragment))
            }
        }
        let refresh = try summary.section(after: "Button(\"Refresh\")", before: ".controlSize(.small)")
        #expect(refresh.contains("model.refresh(workspaceID: workspaceID)"))
        #expect(refresh.contains("!presentation.canRefresh || !model.isActive"))
        #expect(!refresh.contains("workspaceManager"))
        #expect(!refresh.contains("onOpen"))
        let runtime = try SourceContract("Argus/Services/WorkspacePullRequestStatusModel.swift")
        for fragment in [
            "WorkspaceManager", "selectWorkspace(", "selectPanel(", "makeFirstResponder(", "NSApp.activate"
        ] {
            runtime.excludes(fragment, "refresh is not navigation or activation")
        }
    }
}
