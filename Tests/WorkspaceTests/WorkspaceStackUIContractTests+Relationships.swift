import Foundation
import Testing

@testable import Argus

extension WorkspaceStackUIContractTests {
    @Test(arguments: [80.0, 100.0, 200.0], [1, 2, 3, 8, 128])
    func forkLanesStayDistinctInsideABoundedGutter(width: Double, laneCount: Int) {
        let metrics = SidebarWidthMetrics(width: width)
        let gutterWidth = metrics.stackGutterWidth(laneCount: laneCount)
        let offsets = (0..<laneCount).map { metrics.stackLaneOffset($0, laneCount: laneCount) }
        #expect(gutterWidth <= (metrics.isCompact ? 12 : 20))
        #expect(Set(offsets).count == laneCount)
        #expect(offsets == offsets.sorted())
        #expect(offsets.allSatisfy { $0 >= 3 && $0 <= gutterWidth - 3 })
        if laneCount == 1 { #expect(gutterWidth == metrics.stackGutterWidth) }
        if metrics.isCompact {
            let labelWidth = width - 16 - 2 * metrics.rowPadding - gutterWidth - 2 * metrics.rowSpacing - 20
            #expect(labelWidth >= 24)
        }
    }

    @Test
    func measuredForkConnectionsStartAtActualParentAndBypassSiblingSubtrees() throws {
        let rows = [
            WorkspaceStackRow(branch: "root", parentBranch: "main", dependentBranches: ["a", "b"], workspaceId: nil),
            WorkspaceStackRow(
                branch: "a", parentBranch: "root", dependentBranches: ["tip"], workspaceId: UUID(), lane: 1),
            WorkspaceStackRow(branch: "tip", parentBranch: "a", dependentBranches: [], workspaceId: UUID(), lane: 1),
            WorkspaceStackRow(branch: "b", parentBranch: "root", dependentBranches: [], workspaceId: UUID(), lane: 1)
        ]
        let anchors = [
            "root": CGPoint(x: 3, y: 13), "a": CGPoint(x: 7, y: 47),
            "tip": CGPoint(x: 7, y: 88), "b": CGPoint(x: 7, y: 157)
        ]
        let connections = SidebarStackConnection.resolved(rows: rows, anchors: anchors)
        #expect(connections.map(\.parentBranch) == ["root", "a", "root"])
        #expect(connections.map(\.dependentBranch) == ["a", "tip", "b"])
        let sibling = try #require(connections.last)
        #expect(sibling.parent == anchors["root"])
        #expect(sibling.dependent == anchors["b"])
        #expect(
            sibling.points == [
                CGPoint(x: 3, y: 17), CGPoint(x: 3, y: 148), CGPoint(x: 7, y: 148), CGPoint(x: 7, y: 152)
            ])
        #expect(connections[1].points == [CGPoint(x: 7, y: 51), CGPoint(x: 7, y: 83)])
    }

    @Test
    func unknownParentsMissingAnchorsAndBackwardsGeometryNeverInventConnections() {
        let rows = [
            WorkspaceStackRow(
                branch: "root", parentBranch: nil, dependentBranches: ["child"], workspaceId: UUID(),
                issue: "Conflicting parents"),
            WorkspaceStackRow(branch: "child", parentBranch: "root", dependentBranches: [], workspaceId: UUID()),
            WorkspaceStackRow(branch: "unanchored", parentBranch: "missing", dependentBranches: [], workspaceId: nil)
        ]
        let anchors = [
            "main": CGPoint(x: 3, y: 0), "root": CGPoint(x: 3, y: 50), "child": CGPoint(x: 3, y: 20),
            "unanchored": CGPoint(x: 3, y: 80)
        ]
        #expect(SidebarStackConnection.resolved(rows: rows, anchors: anchors).isEmpty)
    }

    @Test(arguments: [0, 1, 3])
    func relationshipHelpKeepsFullNamesPluralDependentsAndRelevantIssues(_ count: Int) {
        let dependents = (0..<count).map { "feature/complete-dependent-name-\($0)" }
        let row = WorkspaceStackRow(
            branch: "feature/complete-current-name", parentBranch: "feature/complete-parent-name",
            dependentBranches: dependents, workspaceId: UUID(), issue: "Relevant metadata issue"
        )
        let description = row.sidebarRelationshipDescription
        #expect(description.contains(row.branch))
        #expect(description.contains("Recorded parent: feature/complete-parent-name."))
        #expect(description.contains("Relevant metadata issue"))
        #expect(dependents.allSatisfy { description.contains($0) })
        #expect(
            row.sidebarDependentsDescription
                == (count == 0
                    ? "No recorded direct dependents."
                    : "Recorded direct dependent\(count == 1 ? "" : "s"): \(dependents.joined(separator: ", "))."))
        #expect(!description.contains("gh-stack"))
        let root = WorkspaceStackRow(branch: "root", parentBranch: nil, dependentBranches: dependents, workspaceId: nil)
        #expect(root.sidebarParentDescription == "No recorded parent.")
        var conflicted = root
        conflicted.issue = "Conflicting recorded parents"
        #expect(conflicted.sidebarParentDescription == "Recorded parent unavailable.")
        #expect(!conflicted.sidebarRelationshipDescription.contains("main"))
    }
}
