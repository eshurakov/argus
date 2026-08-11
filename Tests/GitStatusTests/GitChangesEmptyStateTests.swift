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
        #expect(statusContent.contains("if summary.isClean {"))
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
}
