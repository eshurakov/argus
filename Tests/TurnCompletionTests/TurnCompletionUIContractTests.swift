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
    func workspaceBellPrecedesAgentStatusAndTypeIcon() throws {
        let row = try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift")
        let iconSelection = try row.section(
            after: "if hasAttention",
            before: "// Title and Workspace context"
        )

        let statusBranch = try #require(iconSelection.range(of: "else if let agentStatus"))
        let defaultBranch = try #require(iconSelection.range(of: "workspace.workspaceType.icon"))
        #expect(statusBranch.lowerBound < defaultBranch.lowerBound)

        #expect(iconSelection.contains("Image(systemName: \"bell.fill\")"))
        #expect(iconSelection.contains(".foregroundStyle(.orange)"))
        #expect(iconSelection.contains(".frame(width: 14)"))
        #expect(iconSelection.contains(".accessibilityHidden(true)"))
        row.contains(
            "turnCompletionAttentionStore.workspaceHasAttention(workspace.id)",
            "Workspace row summarizes shared Turn Completion Attention"
        )
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
            after: "if hasAttention",
            before: "// Title and Workspace context"
        )
        #expect(!rowIconSelection.contains("onSelect"))

        try SourceContract("Argus/Models/SessionSnapshot.swift").excludes(
            "TurnCompletion",
            "Turn Completion Attention is runtime-only and must not persist in the Session Snapshot"
        )
    }
}
