import Foundation
import Testing

@testable import Argus

@Suite
struct GitChangesEmptyStateTests {
    @Test
    func cleanWorkingTreeReplacesEmptyFileSectionsWithAnEmptyState() throws {
        let view = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")

        let statusContent = try view.section(
            after: "private func statusContent(",
            before: "private func cleanWorkingTreeContent")
        #expect(statusContent.contains("if summary.hasNoSectionContent {"))
        #expect(statusContent.contains("cleanWorkingTreeContent()"))
        #expect(statusContent.contains("} else {"))
        #expect(statusContent.contains("changeSections(summary, owner: owner)"))

        let cleanState = try view.section(
            after: "private func cleanWorkingTreeContent",
            before: "private func changeSections")
        #expect(cleanState.contains("Working tree clean"))
        #expect(cleanState.contains("No staged, unstaged, or untracked changes"))
        #expect(cleanState.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
    }

    @Test
    func onlySectionsWithChangesAreListed() throws {
        let view = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")

        let changeSections = try view.section(
            after: "private func changeSections(",
            before: "private func branchBar")
        #expect(changeSections.contains("ForEach(summary.sections)"))
        #expect(!changeSections.contains("populatedSections"))
        #expect(!changeSections.contains(".filter { $0.count > 0 }"))
    }

    @Test
    func againstBaseChangesKeepSectionsVisibleWhileTheWorkingTreeIsClean() {
        let summary = summaryWithCleanWorkingTree(
            againstBaseFiles: [
                GitFileChange(path: "stacked.txt", status: .modified, sectionKind: .againstBase)
            ]
        )

        #expect(summary.isClean, "Against Base entries do not make Working Changes dirty")
        #expect(
            !summary.hasNoSectionContent,
            "committed Against Base changes keep the file sections visible"
        )
    }

    @Test
    func unavailableAgainstBaseKeepsItsExplanationVisibleWhileTheWorkingTreeIsClean() {
        let summary = summaryWithCleanWorkingTree(
            againstBaseState: .unavailable(message: "No base branch was found for this workspace.")
        )

        #expect(
            !summary.hasNoSectionContent,
            "an unavailable section carries the explanation of its own comparison"
        )
    }

    @Test
    func cleanWorkingTreeWithoutAgainstBaseContentHasNoSectionContent() {
        #expect(
            summaryWithCleanWorkingTree().hasNoSectionContent,
            "nothing to show in any active comparison context is the clean state"
        )
        #expect(
            GitStatusSummary(
                rootPath: "/tmp/repo",
                branchName: "feature",
                upstreamName: nil,
                aheadCount: 0,
                behindCount: 0
            ).hasNoSectionContent,
            "a clean working tree without Against Base is the clean state"
        )
    }

    private func summaryWithCleanWorkingTree(
        againstBaseFiles: [GitFileChange] = [],
        againstBaseState: GitChangeSectionState = .available
    ) -> GitStatusSummary {
        GitStatusSummary(
            rootPath: "/tmp/repo",
            branchName: "eshurakov/silver-atlas",
            upstreamName: nil,
            aheadCount: 0,
            behindCount: 0,
            againstBaseFiles: againstBaseFiles,
            againstBaseState: againstBaseState,
            showBaseBranchChanges: true
        )
    }
}
