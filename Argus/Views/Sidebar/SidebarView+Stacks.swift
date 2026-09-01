import SwiftUI

extension ProjectSection {
    @ViewBuilder
    func stackSection(_ group: WorkspaceStackGroup) -> some View {
        if let workspaceId = group.workspaceIds.first,
            let firstWorkspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId })
        {
            VStack(spacing: 0) {
                SidebarStackHeader(
                    workspace: firstWorkspace,
                    group: group,
                    isCollapsed: project.collapsedStackIds.contains(group.id),
                    onToggle: { workspaceManager.toggleWorkspaceStack(group.id, in: project.id) }
                )
                .modifier(SidebarWorkspaceReordering(projectId: project.id, workspaceId: workspaceId))
                .contextMenu {
                    workspaceMoveActions(for: workspaceId, isStack: true)
                }

                if project.collapsedStackIds.contains(group.id) {
                    SidebarCollapsedWorkspaceSummary(workspaceIds: group.workspaceIds)
                } else {
                    stackRows(group)
                }
            }
            .padding(.top, 4)
        }
    }

    private func stackRows(_ group: WorkspaceStackGroup) -> some View {
        VStack(spacing: 0) {
            ForEach(group.rows) { row in
                if let workspaceId = row.workspaceId {
                    workspaceRow(workspaceId, stackRelationship: row)
                } else {
                    SidebarStackReferenceRow(row: row)
                }
            }
        }
        .environment(\.sidebarStackLaneCount, group.laneCount)
        .overlayPreferenceValue(SidebarStackRowAnchors.self) { anchors in
            SidebarStackRail(
                rows: group.rows,
                anchors: anchors,
                selectedWorkspaceId: workspaceManager.selectedWorkspaceId
            )
        }
    }
}

private struct SidebarStackHeader: View {
    @ObservedObject var workspace: Workspace
    let group: WorkspaceStackGroup
    let isCollapsed: Bool
    let onToggle: () -> Void
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.sidebarWidthMetrics) private var sidebarMetrics
    @Environment(WindowFocusState.self) private var windowFocus
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private var firstRow: WorkspaceStackRow? {
        group.rows.first { $0.workspaceId == workspace.id }
    }

    private var title: String {
        workspace.displayTitle.isEmpty ? firstRow?.branch ?? "Stack" : workspace.displayTitle
    }

    private var sourceContext: String {
        guard let parent = firstRow?.parentBranch else {
            return firstRow?.issue == nil ? "Stack · parent not recorded" : "Stack · parent unavailable"
        }
        guard let base = group.baseBranch, base != parent else { return "Stack · from \(parent)" }
        return "Stack · from \(parent) · source \(base)"
    }

    private var sourceHelp: String {
        let parent = firstRow?.sidebarParentDescription ?? "No recorded parent."
        let source = group.baseBranch.map { "Recorded source: \($0)." } ?? ""
        let issues = Set(group.rows.compactMap(\.issue)).sorted().joined(separator: " ")
        return ["Locally recorded Stack.", parent, source, issues].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: sidebarMetrics.headerSpacing) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: sidebarMetrics.disclosureWidth)
                if !sidebarMetrics.isCompact {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 11))
                        .frame(width: 14)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(
                            .system(
                                size: appSettings.presentationMetrics.textSize(forBaseSize: 11),
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(sourceContext)
                        .font(
                            .system(
                                size: appSettings.presentationMetrics.textSize(forBaseSize: 9),
                                design: .monospaced
                            )
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if !sidebarMetrics.isCompact {
                    Spacer(minLength: 0)
                }
                Text("\(group.workspaceIds.count)")
                    .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 10), design: .monospaced))
                    .fixedSize()
            }
            .foregroundStyle(.secondary)
            .windowFocusChrome()
            .padding(.horizontal, sidebarMetrics.rowPadding)
            .padding(.vertical, appSettings.presentationMetrics.workspaceRowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered || isFocused ? ChromeColors.hoveredTabFill : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: isFocused && windowFocus.isKeyWindow ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .cursor(.pointingHand)
        .help("\(isCollapsed ? "Expand" : "Collapse") \(title) Stack. \(sourceHelp)")
        .accessibilityLabel("\(title), Stack Group, \(group.workspaceIds.count) Workspaces. \(sourceHelp)")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityIdentifier("workspace-stack-\(group.id)")
    }
}

extension WorkspaceStackRow {
    var sidebarParentDescription: String {
        if let parentBranch { return "Recorded parent: \(parentBranch)." }
        return issue == nil ? "No recorded parent." : "Recorded parent unavailable."
    }

    var sidebarDependentsDescription: String {
        guard !dependentBranches.isEmpty else { return "No recorded direct dependents." }
        let label = dependentBranches.count == 1 ? "Recorded direct dependent" : "Recorded direct dependents"
        return "\(label): \(dependentBranches.joined(separator: ", "))."
    }

    var sidebarRelationshipDescription: String {
        let context =
            "Locally recorded Stack. Branch: \(branch). \(sidebarParentDescription) \(sidebarDependentsDescription)"
        return issue.map { "\(context) \($0)" } ?? context
    }
}

private struct SidebarStackLaneCountKey: EnvironmentKey {
    static let defaultValue = 1
}

extension EnvironmentValues {
    var sidebarStackLaneCount: Int {
        get { self[SidebarStackLaneCountKey.self] }
        set { self[SidebarStackLaneCountKey.self] = newValue }
    }
}

struct SidebarStackGutter: View {
    let branch: String
    let lane: Int
    @Environment(\.sidebarWidthMetrics) private var sidebarMetrics
    @Environment(\.sidebarStackLaneCount) private var laneCount

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .anchorPreference(key: SidebarStackRowAnchors.self, value: .center) { [branch: $0] }
            .offset(x: sidebarMetrics.stackLaneOffset(lane, laneCount: laneCount) - 0.5)
            .frame(width: sidebarMetrics.stackGutterWidth(laneCount: laneCount), alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct SidebarStackRowAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGPoint>] { [:] }

    static func reduce(value: inout [String: Anchor<CGPoint>], nextValue: () -> [String: Anchor<CGPoint>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct SidebarStackRail: View {
    let rows: [WorkspaceStackRow]
    let anchors: [String: Anchor<CGPoint>]
    let selectedWorkspaceId: UUID?

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, _ in
                let selectedBranch = selectedWorkspaceId.flatMap { selectedId in
                    rows.first { $0.workspaceId == selectedId }?.branch
                }
                let points = anchors.mapValues { geometry[$0] }
                for connection in SidebarStackConnection.resolved(rows: rows, anchors: points) {
                    let isRelated =
                        connection.dependentBranch == selectedBranch || connection.parentBranch == selectedBranch
                    context.stroke(
                        connectionPath(connection),
                        with: .color(isRelated ? .accentColor.opacity(0.75) : .secondary.opacity(0.45)),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
                    )
                }
                for row in rows {
                    guard let point = points[row.branch] else { continue }
                    let marker = Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
                    context.stroke(
                        marker,
                        with: .color(row.branch == selectedBranch ? .accentColor : .secondary.opacity(0.55)),
                        lineWidth: 1
                    )
                }
            }
        }
        .windowFocusChrome()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func connectionPath(_ connection: SidebarStackConnection) -> Path {
        let points = connection.points
        return Path { path in
            for (index, point) in points.enumerated() {
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            if let tip = points.last {
                path.move(to: CGPoint(x: tip.x - 2, y: tip.y - 3))
                path.addLine(to: tip)
                path.addLine(to: CGPoint(x: tip.x + 2, y: tip.y - 3))
            }
        }
    }
}

private struct SidebarStackReferenceRow: View {
    let row: WorkspaceStackRow
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.sidebarWidthMetrics) private var sidebarMetrics

    var body: some View {
        HStack(spacing: sidebarMetrics.rowSpacing) {
            SidebarStackGutter(branch: row.branch, lane: row.lane)
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.branch)
                    .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 10), design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Workspace not open")
                    .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 9)))
                    .lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if !sidebarMetrics.isCompact {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, sidebarMetrics.rowPadding)
        .padding(.vertical, appSettings.presentationMetrics.workspaceRowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.secondary)
        .windowFocusChrome()
        .help("\(row.branch), Workspace not open. \(row.sidebarRelationshipDescription)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Branch \(row.branch), Workspace not open")
        .accessibilityValue(row.sidebarRelationshipDescription)
    }
}
