import Testing

@testable import Argus

@Suite
struct WorkspaceRootPathUIContractTests {
    @Test
    func directWorkspaceRootPathEntryUsesTheSharedMutationFlow() throws {
        try SourceContract("Argus/Views/Sidebar/SidebarView+Projects.swift").contains(
            "Button(\"Enter Path Directly…\")",
            "Standalone Workspace context menu must offer direct path entry"
        )
        try SourceContract("Argus/Services/WorkspaceManager+Navigation.swift").containsAll(
            [
                "func setStandaloneWorkspaceRoot(_ workspaceId: UUID, path: String)",
                "NSString(string: trimmedPath).expandingTildeInPath",
                "directoryURL: URL(fileURLWithPath: expandedPath)"
            ], "entered Workspace Root paths use manager normalization")
        try SourceContract("Argus/Views/MainWindowView.swift").containsAll(
            [
                "@State private var changeWorkspaceRootSheetRequest: ChangeWorkspaceRootSheetRequest?",
                ".changeWorkspaceRootSheet("
            ], "direct Workspace Root path-entry sheet presentation")
        try SourceContract("Argus/Views/Dialogs/ChangeWorkspaceRootSheet.swift").containsAll(
            [
                "ChangeWorkspaceRootSheet(workspaceId: request.workspaceId)",
                ".sheet(item: $request)",
                ".showChangeWorkspaceRootSheet",
                "TextField(\"Enter an absolute path or ~/path\", text: $path)",
                "Button(\"Browse…\", action: browseForDirectory)",
                "workspaceManager.setStandaloneWorkspaceRoot(workspaceId, path: trimmedPath)",
                "Button(\"Apply\", action: apply)"
            ], "direct Workspace Root path-entry controls")
    }
}
