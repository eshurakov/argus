import Testing

@testable import Argus

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
