import Testing

@testable import Argus

@Suite
struct AgentStatusUIContractTests {
    @Test
    func oneEphemeralStoreIsInjectedFromTheApp() throws {
        try SourceContract("Argus/App/ArgusApp.swift").containsAll(
            [
                "@StateObject private var agentStatusStore = AgentStatusStore()",
                ".environmentObject(agentStatusStore)"
            ], "process-wide Agent Status Store ownership"
        )

        try SourceContract("Argus/Models/SessionSnapshot.swift").excludes(
            "AgentStatus",
            "Session Snapshot must exclude Agent Status Entries"
        )
    }

    @Test
    func tabIconsPreserveLoadingThenStatusThenDefaultPrecedence() throws {
        let tabBar = try SourceContract("Argus/Views/Content/TabBarView.swift")
        let iconSelection = try tabBar.section(
            after: "if panel.isLoading",
            before: "Text(title)"
        )

        #expect(iconSelection.contains("ProgressView()"))
        #expect(iconSelection.contains("else if let agentStatus"))
        #expect(iconSelection.contains("agentStatus.state.symbolName"))
        #expect(iconSelection.contains("agentStatus.state.color"))
        #expect(iconSelection.contains("else if let icon = panel.displayIcon"))
        tabBar.containsAll(
            [
                "workspace.layout(for: tabId).leaves",
                "workspace.panels[$0]?.panelType == .terminal",
                "agentStatusStore.effectiveStatus(workspaceId: workspace.id)"
            ], "Terminal Surface and Workspace-level tab status resolution"
        )
    }

    @Test
    func sidebarStatusReplacesTypeIconAndNamesStateForAccessibility() throws {
        let row = try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift")

        row.containsAll(
            [
                "if let agentStatus",
                "SemanticIcon(name: agentStatus.state.symbolName, pointSize: 11, weight: .semibold)",
                ".foregroundColor(agentStatus.state.color)",
                "SemanticIcon(name: workspace.workspaceType.icon, pointSize: 11, weight: .semibold)",
                ".accessibilityValue(workspaceAccessibilityValue)",
                #"values.append("Agent status: \(agentStatus.state.label)")"#,
                "includesNonterminalPanels:"
            ], "sidebar Agent Status display")
    }

    @Test
    func implementationDoesNotInventDeferredAgentSubsystems() throws {
        let store = try SourceContract("Argus/Services/AgentStatusStore.swift")
        for forbidden in [
            "Socket", "PID", "Process", "JSON", "Codable", "NotificationCenter", "TTS", "speech"
        ] {
            store.excludes(forbidden, "Agent Status Store must remain socket-independent and ephemeral")
        }
    }
}
