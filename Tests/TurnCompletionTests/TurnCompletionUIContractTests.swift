import Testing

@testable import Argus

@Suite
struct TurnCompletionUIContractTests {
    @Test
    func tabBellSitsBetweenLoadingAndAgentStatusInReservedGeometry() throws {
        let tabBar = try SourceContract("Argus/Views/Content/TabBarView.swift")
        let iconSelection = try tabBar.section(
            after: "if panel.isLoading",
            before: "Text(title)"
        )

        // Loading keeps first precedence structurally: the section starts
        // inside the loading branch.
        #expect(iconSelection.contains("ProgressView()"))

        let attentionBranch = try #require(iconSelection.range(of: "else if hasAttention"))
        let statusBranch = try #require(iconSelection.range(of: "else if let agentStatus"))
        let defaultBranch = try #require(iconSelection.range(of: "else if let icon = panel.displayIcon"))
        #expect(attentionBranch.lowerBound < statusBranch.lowerBound)
        #expect(statusBranch.lowerBound < defaultBranch.lowerBound)

        #expect(iconSelection.contains("Image(systemName: \"bell.fill\")"))
        #expect(iconSelection.contains(".foregroundStyle(.orange)"))
        #expect(iconSelection.contains(".accessibilityHidden(true)"))
        tabBar.containsAll(
            [
                ".frame(width: 14, height: 14)",
                "turnCompletionAttentionStore.hasAttention(",
                "workspaceId: workspace.id,",
                "tabId: panelId"
            ], "Top-level Tab reads shared Turn Completion Attention into a fixed icon slot"
        )
    }

    @Test
    func tabAccessibilityValueNamesTheCompletedAgentTurn() throws {
        try SourceContract("Argus/Views/Content/TabBarView.swift").containsAll(
            [
                ".accessibilityValue(tabAccessibilityValue)",
                #"values.append("Agent turn completed")"#
            ], "Top-level Tab accessibility announces the completed agent turn"
        )
    }

    @Test
    func workspaceBellUsesSharedPrecedenceAheadOfAgentAndPullRequestStatus() throws {
        let row = try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift")
        let iconSelection = try row.section(
            after: "private var workspaceIcon: some View",
            before: "private var showsShortcutOverlay"
        )

        #expect(iconSelection.contains("switch workspaceIconKind"))
        #expect(iconSelection.contains("case .attention:"))
        #expect(iconSelection.contains("Image(systemName: \"bell.fill\")"))
        #expect(iconSelection.contains(".foregroundStyle(.orange)"))
        #expect(iconSelection.contains(".frame(width: 20, height: 20)"))
        #expect(iconSelection.contains(".accessibilityHidden(true)"))
        row.containsAll(
            ["hasAttention: hasAttention", "turnCompletionAttentionStore.workspaceHasAttention(workspace.id)"],
            "Workspace row passes shared Turn Completion Attention to the icon resolver"
        )
        let resolver = try SourceContract("Argus/Views/Sidebar/PullRequestStatusView.swift").section(
            after: "init(hasAttention:", before: "enum PullRequestStatusSignal")
        let attention = try #require(resolver.range(of: "if hasAttention"))
        let agent = try #require(resolver.range(of: "else if let agentState, agentState != .idle"))
        let pullRequest = try #require(resolver.range(of: "else if showsPullRequestStatus"))
        #expect(attention.lowerBound < agent.lowerBound)
        #expect(agent.lowerBound < pullRequest.lowerBound)
    }

    @Test
    func workspaceAccessibilityReportsTabsNeedingAttention() throws {
        try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift").containsAll(
            [
                ".accessibilityValue(workspaceAccessibilityValue)",
                #"values.append("One or more tabs need attention")"#
            ], "Workspace accessibility reports that one or more tabs need attention"
        )
    }

    @Test
    func viewsReadAttentionWithoutClearingOrMutatingSelectionAndFocus() throws {
        let tabBar = try SourceContract("Argus/Views/Content/TabBarView.swift")
        let row = try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift")
        for view in [tabBar, row] {
            view.excludes(
                "turnCompletionAttentionStore.clear",
                "views must not clear Turn Completion Attention"
            )
            view.excludes(
                "turnCompletionAttentionStore.record",
                "views must not record Turn Completion Attention"
            )
            view.excludes(
                "turnCompletionAttentionStore.migrate",
                "views must not migrate Turn Completion Attention"
            )
        }

        // Attention rendering must never drive tab or Workspace selection.
        let tabIconSelection = try tabBar.section(after: "if panel.isLoading", before: "Text(title)")
        #expect(!tabIconSelection.contains("selectPanel"))
        let rowIconSelection = try row.section(
            after: "private var workspaceIcon: some View",
            before: "private var showsShortcutOverlay"
        )
        #expect(!rowIconSelection.contains("onSelect"))

        try SourceContract("Argus/Models/SessionSnapshot.swift").excludes(
            "TurnCompletion",
            "Turn Completion Attention is runtime-only and must not persist in the Session Snapshot"
        )
    }
}
