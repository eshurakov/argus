import Testing

@testable import Argus

@Suite
struct EmptyWorkspaceUIContractTests {
    @Test
    func emptyWorkspaceContentKeepsChromeAndOffersSharedTerminalCreation() throws {
        let content = try SourceContract("Argus/Views/Content/ContentAreaView.swift")
        content.containsAll(
            [
                "TabBarView(workspace: workspace)",
                "if workspace.panelOrder.isEmpty",
                "EmptyWorkspaceContentView()",
                "Text(\"No tabs open\")",
                "Button(\"New Terminal Tab\")",
                "workspaceManager.addTab()"
            ],
            "selected Workspace empty state"
        )
        content.excludes(
            "WorkspaceContentView(workspace: workspace).sheet",
            "empty Workspaces remain in the main content surface"
        )

        try SourceContract("Argus/Views/Content/TabBarView.swift").contains(
            "workspaceManager.addTab()",
            "tab-bar terminal creation uses the shared manager path"
        )
    }
}
