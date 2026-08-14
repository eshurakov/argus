import Foundation
import Testing

@testable import Argus

@Suite
struct GitBranchBarUIContractTests {
    @Test
    func branchBarShowsChangeTotalsAndTogglesAllSections() throws {
        let view = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
        let branchBar = try view.section(
            after: "private func branchBar(",
            before: "private func upstreamSyncText")

        for expected in [
            "summary.totalFileCount", "totalDiffStats(summary)",
            "totals.additions", "totals.deletions",
            "setAllSectionsExpanded(allCollapsed, summary: summary)",
            "Collapse all file sections", "Expand all file sections",
            "HoverStateView { isHovered in",
            "isHovered ? ChromeColors.hoveredTabFill : Color.clear",
            ".cursor(.pointingHand)",
            ".help(actionName)", ".accessibilityLabel(actionName)"
        ] {
            #expect(branchBar.contains(expected))
        }
    }

    @Test
    func branchBarUsesOneCompactAdaptiveRow() throws {
        let view = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
        let branchBar = try view.section(
            after: "private func branchBar(",
            before: "private func upstreamSyncText")

        let identityLine = try #require(branchBar.range(of: "branchIdentityLine(summary)"))
        let statsLine = try #require(branchBar.range(of: "branchStatsText(summary, totals: totals)"))
        let upstreamLine = try #require(
            branchBar.range(of: "upstreamSummary(summary, upstreamName: upstreamName)"))
        let identityDeclaration = try #require(
            branchBar.range(of: "private func branchIdentityLine("))
        let statsDeclaration = try #require(
            branchBar.range(of: "private func branchStatsText("))
        let identitySection = String(
            branchBar[identityDeclaration.upperBound..<statsDeclaration.lowerBound])

        #expect(identityLine.lowerBound < statsLine.lowerBound)
        #expect(statsLine.lowerBound < upstreamLine.lowerBound)
        #expect(branchBar.contains(".frame(maxWidth: .infinity, minHeight: 30"))
        #expect(branchBar.contains(".accessibilityElement(children: .combine)"))
        #expect(branchBar.contains("branchIdentityLine(summary)\n                    .layoutPriority(2)"))
        #expect(branchBar.contains("branchStatsText(summary, totals: totals)"))
        #expect(branchBar.contains(".layoutPriority(1)"))
        #expect(identitySection.contains(".truncationMode(.middle)"))
        #expect(identitySection.contains(".help(summary.branchName ?? \"Detached HEAD\")"))
    }

    @Test
    func branchBarKeepsStatsReadableAndSyncCountsVisible() throws {
        let view = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
        let branchBar = try view.section(
            after: "private func branchBar(",
            before: "private func upstreamSyncText")
        let statsDeclaration = try #require(
            branchBar.range(of: "private func branchStatsText("))
        let upstreamDeclaration = try #require(
            branchBar.range(of: "private func upstreamSummary("))
        let helpDeclaration = try #require(
            branchBar.range(of: "private func upstreamHelpText("))
        let statsSection = String(
            branchBar[statsDeclaration.upperBound..<upstreamDeclaration.lowerBound])
        let upstreamSection = String(
            branchBar[upstreamDeclaration.upperBound..<helpDeclaration.lowerBound])

        #expect(branchBar.contains("if summary.totalFileCount > 0"))
        #expect(branchBar.contains("if let upstreamName = summary.upstreamName"))
        #expect(statsSection.contains(".lineLimit(1)"))
        #expect(statsSection.contains("totals.additions) additions"))
        #expect(!statsSection.contains(".fixedSize()"))
        #expect(upstreamSection.contains(".truncationMode(.tail)"))
        #expect(upstreamSection.contains(".fixedSize()"))
        #expect(upstreamSection.contains("upstreamHelpText(summary, upstreamName: upstreamName)"))
    }
}
