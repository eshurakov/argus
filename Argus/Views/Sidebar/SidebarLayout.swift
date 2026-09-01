import CoreGraphics

/// Pure layout rules for the workspace sidebar.
enum SidebarLayout {
    static let leftMinWidth: CGFloat = 80
    static let leftDefaultWidth: CGFloat = 200
    static let leftMaxFraction: CGFloat = 0.33

    static func leftMaxWidth(forWindowWidth windowWidth: CGFloat) -> CGFloat {
        max(leftMinWidth, windowWidth * leftMaxFraction)
    }

    static func clampLeftWidth(_ width: CGFloat, windowWidth: CGFloat) -> CGFloat {
        min(max(width, leftMinWidth), leftMaxWidth(forWindowWidth: windowWidth))
    }
}

struct SidebarWidthMetrics: Equatable, Sendable {
    let width: CGFloat

    var isCompact: Bool { width < 160 }
    var rowPadding: CGFloat { isCompact ? 2 : 8 }
    var rowSpacing: CGFloat { isCompact ? 2 : 8 }
    var headerSpacing: CGFloat { isCompact ? 2 : 6 }
    var disclosureWidth: CGFloat { isCompact ? 8 : 12 }
    var stackGutterWidth: CGFloat { isCompact ? 6 : 12 }

    func stackGutterWidth(laneCount: Int) -> CGFloat {
        min(isCompact ? 12 : 20, stackGutterWidth + CGFloat(max(1, laneCount) - 1) * (isCompact ? 4 : 8))
    }

    func stackLaneOffset(_ lane: Int, laneCount: Int) -> CGFloat {
        let gutterWidth = stackGutterWidth(laneCount: laneCount)
        guard laneCount > 1 else { return gutterWidth / 2 }
        return 3 + CGFloat(min(max(0, lane), laneCount - 1)) * (gutterWidth - 6) / CGFloat(laneCount - 1)
    }
}

struct SidebarStackConnection: Equatable {
    let parentBranch: String
    let dependentBranch: String
    let parent: CGPoint
    let dependent: CGPoint

    static func resolved(rows: [WorkspaceStackRow], anchors: [String: CGPoint]) -> [Self] {
        rows.compactMap { row in
            guard let parentBranch = row.parentBranch, let parent = anchors[parentBranch],
                let dependent = anchors[row.branch], dependent.y > parent.y
            else { return nil }
            return Self(parentBranch: parentBranch, dependentBranch: row.branch, parent: parent, dependent: dependent)
        }
    }

    var points: [CGPoint] {
        let start = CGPoint(x: parent.x, y: parent.y + 4)
        let tip = CGPoint(x: dependent.x, y: dependent.y - 5)
        guard parent.x != dependent.x else { return [start, tip] }
        let bendY = max(start.y, tip.y - 4)
        return [start, CGPoint(x: parent.x, y: bendY), CGPoint(x: dependent.x, y: bendY), tip]
    }
}
