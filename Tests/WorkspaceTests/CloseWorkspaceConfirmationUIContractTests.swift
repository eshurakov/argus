import Testing

@Suite
struct WorkspaceCloseUIContractTests {
    @Test
    func workspaceCloseUsesInViewConfirmationWithoutAModalRunLoop() throws {
        let confirmation = try SourceContract(
            "Argus/Views/Dialogs/CloseWorkspaceConfirmationView.swift"
        )
        confirmation.containsAll(
            [
                "Button(request.canDeleteWorktree ? \"Close Only\" : \"Close Workspace\"",
                "Button(\"Delete Worktree and Close\"",
                ".foregroundStyle(.red)"
            ], "in-view Workspace close choices"
        )
        confirmation.excludes("NSAlert", "Workspace close must not open an AppKit alert")
        confirmation.excludes("runModal()", "Workspace close must not start a modal run loop")
        confirmation.containsAll(
            [
                "let runningProcessCount: Int",
                "That will terminate a running process.",
                #"Closing \(request.title) will terminate \(processPhrase)."#
            ],
            "Workspace close names a running-process consequence"
        )
    }
}
