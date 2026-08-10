import Testing

@Suite
struct PullRequestWorkspaceUIContractTests {
    @Test
    func newWorkspaceSheetUsesCompactMenuForThreeTextOnlySources() throws {
        let sheet = try SourceContract("Argus/Views/Dialogs/NewWorkspaceSheet.swift")
        sheet.containsAll(
            [
                "case new = \"New Branch\"",
                "case existing = \"Existing Branch\"",
                "case pullRequest = \"Pull Request\"",
                "Text(\"Source\")",
                "Picker(\"Source\", selection: $branchMode)",
                ".pickerStyle(.menu)",
                ".controlSize(.small)",
                ".fixedSize()",
                "TextField(\"URL or number\", text: $pullRequestInput)",
                "if branchMode != .pullRequest",
                "workspaceManager.createWorkspace(",
                "fromPullRequest: trimmedInput",
                "catch {",
                "errorMessage = error.localizedDescription"
            ],
            "Pull Request source picker and creation flow"
        )
        sheet.excludes(
            "Image(system" + "Name:",
            "Pull Request intake must remain free of SF Symbol creation"
        )
        sheet.excludes(
            ".pickerStyle(.segmented)",
            "the source selector must remain a compact menu"
        )
        sheet.excludes(
            "Text(\"Branch\")",
            "the selected source must provide the branch field context"
        )
        sheet.excludes(
            "Text(\"Pull Request\")",
            "the selected source must provide the Pull Request field context"
        )
    }

    @Test
    func pullRequestModeDoesNotStartBranchLoadingOrGeneration() throws {
        let sheet = try SourceContract("Argus/Views/Dialogs/NewWorkspaceSheet.swift")
        let modeChange = try sheet.section(
            after: ".onChange(of: branchMode)",
            before: "    }\n}"
        )
        #expect(modeChange.contains("case .pullRequest:"))
        #expect(modeChange.contains("break"))

        let createState = try sheet.section(
            after: "private var canCreate: Bool", before: "private var filteredAvailableBranches")
        #expect(createState.contains("case .pullRequest:"))
        #expect(createState.contains("pullRequestInput.trimmingCharacters"))
    }
}
