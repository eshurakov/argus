import Foundation
import Testing

@testable import Argus

@Suite
struct WorkspaceStackUIContractTests {
    @Test
    func projectSectionsUseTheSharedProjectionAndStableIdentity() throws {
        let projects = try SourceContract("Argus/Views/Sidebar/SidebarView+Projects.swift")
        projects.containsAll(
            [
                "ForEach(workspaceManager.sidebarItems(for: project))",
                "case .workspace(let workspaceId):",
                "case .stack(let group):",
                ".id(group.id)",
                "if project.isExpanded || !showsHeader",
                "shortcutDigit: workspaceManager.workspaceShortcutDigit(for: workspace.id)",
                ".id(workspace.id)"
            ], "Project sections use the same projection as Workspace navigation")
        try SourceContract("Argus/Views/Sidebar/SidebarView+Stacks.swift").containsAll(
            [
                "ForEach(group.rows)",
                "if let workspaceId = row.workspaceId",
                "workspaceRow(workspaceId, stackRelationship: row)",
                "SidebarStackReferenceRow(row: row)"
            ], "only open Workspaces receive selectable rows and shortcut numbers")
        try SourceContract("Argus/Views/Sidebar/SidebarView+Header.swift").contains(
            "ProjectSection(project: catchAll, showsHeader: false)", "Catch-all Project stays headerless")
    }

    @Test
    func groupTitlesObserveTheFirstOpenWorkspaceWithoutBecomingIdentity() throws {
        let stacks = try SourceContract("Argus/Views/Sidebar/SidebarView+Stacks.swift")
        stacks.contains("group.workspaceIds.first", "the first open Workspace supplies the Stack Group title")
        let header = try stacks.section(after: "private struct SidebarStackHeader: View {", before: "\n}\n")
        for fragment in [
            "@ObservedObject var workspace: Workspace",
            "workspace.displayTitle.isEmpty",
            "firstRow?.branch ?? \"Stack\"",
            "group.workspaceIds.count",
            "firstRow?.parentBranch",
            "group.baseBranch.map",
            "group.rows.compactMap(\\.issue)",
            "Stack · parent not recorded",
            "Stack · parent unavailable",
            ".accessibilityIdentifier(\"workspace-stack-\\(group.id)\")"
        ] {
            #expect(header.contains(fragment))
        }
        #expect(!header.contains("group.rows.count"))
        #expect(!header.contains(".id(title)"))
        #expect(!header.contains("Stack trunk:"))
        #expect(!header.contains("parentBranch ?? group.baseBranch"))
        #expect(!header.contains("Local gh-stack"))
    }

    @Test
    func groupHeadersDiscloseWithoutSelectingOrClosingWorkspaces() throws {
        let stacks = try SourceContract("Argus/Views/Sidebar/SidebarView+Stacks.swift")
        let section = try stacks.section(after: "func stackSection(", before: "private func stackRows(")
        #expect(section.contains("project.collapsedStackIds.contains(group.id)"))
        #expect(section.contains("workspaceManager.toggleWorkspaceStack(group.id, in: project.id)"))
        #expect(!section.contains("selectWorkspace("))
        #expect(!section.contains("requestCloseWorkspace("))
        #expect(!section.contains(".focus()"))
        let header = try stacks.section(after: "private struct SidebarStackHeader: View {", before: "\n}\n")
        for fragment in [
            "Button(action: onToggle)", ".buttonStyle(.plain)", ".contentShape(Rectangle())",
            "ChromeColors.hoveredTabFill", ".focused($isFocused)", ".onHover", ".cursor(.pointingHand)",
            ".help(", ".accessibilityLabel(", ".accessibilityValue(isCollapsed ? \"Collapsed\" : \"Expanded\")"
        ] {
            #expect(header.contains(fragment))
        }
        #expect(!header.contains("workspaceShortcutDigit"))
    }

    @Test
    func groupedRowsKeepTheGutterInsideTheWorkspaceButtonAndSelection() throws {
        let row = try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift")
        row.containsAll(
            [
                "var stackRelationship: WorkspaceStackRow?", "var showsStackGutter = false",
                "parts.append(stackRelationship.sidebarRelationshipDescription)", ".help(workspaceHelp)"
            ], "relationship inputs are optional and accessible")
        let button = try row.section(after: "private var workspaceRowButton: some View {", before: "@ViewBuilder")
        let action = try #require(button.range(of: "Button(action: onSelect)"))
        let gutter = try #require(
            button.range(of: "SidebarStackGutter(branch: stackRelationship.branch, lane: stackRelationship.lane)"))
        let icon = try #require(button.range(of: "workspaceIcon"))
        let selection = try #require(button.range(of: ".fill(backgroundColor)"))
        let hitArea = try #require(button.range(of: ".contentShape(Rectangle())"))
        #expect(action.lowerBound < gutter.lowerBound)
        #expect(gutter.lowerBound < icon.lowerBound)
        #expect(icon.lowerBound < selection.lowerBound)
        #expect(selection.lowerBound < hitArea.lowerBound)
        #expect(button.contains("runningProcessBadge"))
        row.contains("CountBadge(count: runningProcessCount)", "both widths retain the running-process badge")
        #expect(button.contains(".accessibilityAddTraits(isSelected ? .isSelected : [])"))
        #expect(!button.contains(".padding(.leading"))
    }

    @Test
    func connectorsFollowMeasuredRecordedParentsAndStayDecorative() throws {
        let stacks = try SourceContract("Argus/Views/Sidebar/SidebarView+Stacks.swift")
        stacks.containsAll(
            [
                ".anchorPreference(key: SidebarStackRowAnchors.self, value: .center)",
                ".overlayPreferenceValue(SidebarStackRowAnchors.self)",
                "[String: Anchor<CGPoint>]"
            ], "connector anchors come from the actual row gutter layout")
        let rail = try stacks.section(after: "private struct SidebarStackRail: View {", before: "\n}\n")
        for fragment in [
            "GeometryReader", "Canvas", "anchors.mapValues { geometry[$0] }",
            "SidebarStackConnection.resolved(rows: rows, anchors: points)",
            "connectionPath(connection)", "Path { path in",
            ".allowsHitTesting(false)", ".accessibilityHidden(true)"
        ] {
            #expect(rail.contains(fragment))
        }
        #expect(!rail.contains("workspaceIcon"))
        #expect(!rail.contains("rowHeight"))
        #expect(!rail.contains("rows.enumerated()"))
    }

    @Test
    func missingWorkspaceReferencesExplainRelationshipsWithoutActingAsWorkspaces() throws {
        let stacks = try SourceContract("Argus/Views/Sidebar/SidebarView+Stacks.swift")
        let reference = try stacks.section(after: "private struct SidebarStackReferenceRow: View {", before: "\n}\n")
        for fragment in [
            "Text(row.branch)", "Workspace not open", ".foregroundStyle(.secondary)",
            "SidebarStackGutter(branch: row.branch, lane: row.lane)", ".help(",
            ".accessibilityLabel(", ".accessibilityValue(row.sidebarRelationshipDescription)"
        ] {
            #expect(reference.contains(fragment))
        }
        for fragment in ["Button", "onTapGesture", "onDrag", "selectWorkspace", "shortcutDigit", "globalIndex"] {
            #expect(!reference.contains(fragment))
        }
        stacks.containsAll(
            ["Recorded parent: \\(parentBranch)", "dependentBranches.joined(separator:", "Recorded direct dependents"],
            "relationships retain the metadata fields even when trailing references are not shown")
    }

    @Test
    func collapsedSummariesPreserveSelectionAndUndimmedBooleanAttention() throws {
        let row = try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift")
        let summary = try row.section(after: "struct SidebarCollapsedWorkspaceSummary: View {", before: "\n}\n")
        #expect(summary.contains("workspaceIds.contains(workspace.id)"))
        #expect(summary.contains("SidebarCollapsedSelectionLabel(workspace: selectedWorkspace)"))
        #expect(summary.contains("workspaceIds.contains { turnCompletionAttentionStore.workspaceHasAttention($0) }"))
        #expect(summary.contains("Label(\"Unviewed completion\", systemImage: \"bell.fill\")"))
        let attention = try #require(summary.range(of: "if hasAttention {"))
        #expect(!summary[attention.lowerBound...].contains(".windowFocusChrome()"))
        for fragment in ["selectWorkspace", "clearAttention", "acknowledge", "attentionTargets.count"] {
            #expect(!summary.contains(fragment))
        }
        try SourceContract("Argus/Views/Sidebar/SidebarView+Projects.swift").contains(
            "SidebarCollapsedWorkspaceSummary(workspaceIds: project.workspaceIds)",
            "collapsed Projects summarize hidden Workspaces")
        try SourceContract("Argus/Views/Sidebar/SidebarView+Stacks.swift").contains(
            "SidebarCollapsedWorkspaceSummary(workspaceIds: group.workspaceIds)",
            "collapsed Stack Groups summarize only real Workspaces")
    }

    @Test
    func blockActionsUseManagerFeasibilityAndPropagateRejectedDrops() throws {
        let projects = try SourceContract("Argus/Views/Sidebar/SidebarView+Projects.swift")
        projects.containsAll(
            [
                "Button(isStack ? \"Move Stack Up\" : \"Move Up\")",
                "Button(isStack ? \"Move Stack Down\" : \"Move Down\")",
                "workspaceManager.moveWorkspace(in: project.id, moving: workspaceId, offset: -1)",
                "workspaceManager.moveWorkspace(in: project.id, moving: workspaceId, offset: 1)",
                ".disabled(!workspaceManager.canMoveWorkspace(in: project.id, moving: workspaceId, offset: -1))",
                ".disabled(!workspaceManager.canMoveWorkspace(in: project.id, moving: workspaceId, offset: 1))",
                ".modifier(SidebarWorkspaceReordering(projectId: project.id, workspaceId: workspace.id))",
                "Button(\"Rename…\")", "Button(\"Change Working Directory…\")", "Button(\"Enter Path Directly…\")",
                "Button(\"Copy Path\")", "workspaceManager.requestCloseWorkspace(workspace.id)"
            ], "member actions preserve Workspace scope while movement delegates block semantics")
        let drop = try projects.section(
            after: "private struct SidebarWorkspaceDropDelegate: DropDelegate {", before: "\n}\n")
        #expect(drop.contains("return workspaceManager.reorderWorkspace("))
        #expect(!drop.contains("return true"))
        try SourceContract("Argus/Views/Sidebar/SidebarView+Stacks.swift").containsAll(
            [
                ".modifier(SidebarWorkspaceReordering(projectId: project.id, workspaceId: workspaceId))",
                "workspaceMoveActions(for: workspaceId, isStack: true)"
            ], "Stack Group headers share the same block drag and move actions")
    }

    @Test
    func discoveryUsesAReservedNonmodalRetrySlotAndExplicitProjectRefresh() throws {
        let header = try SourceContract("Argus/Views/Sidebar/SidebarView+Header.swift")
        let discovery = try header.section(after: "struct SidebarStackDiscoveryStatus: View {", before: "\n}\n")
        for fragment in [
            "refreshingWorkspaceStackProjectIds.contains(projectId)", "ProgressView()",
            "workspaceManager.workspaceStackErrors[projectId]",
            "workspaceManager.refreshWorkspaceStacks(in: projectId)",
            ".frame(width: 20, height: 20)", ".contentShape(Rectangle())", ".onHover",
            ".focused($isFocused)", ".cursor(.pointingHand)", ".help(", ".accessibilityValue(error)",
            "Color.clear", ".allowsHitTesting(false)", ".accessibilityHidden(true)"
        ] {
            #expect(discovery.contains(fragment))
        }
        #expect(!discovery.contains(".alert("))
        #expect(!discovery.contains(".sheet("))
        #expect(!discovery.contains(".onAppear"))
        try SourceContract("Argus/Views/Sidebar/SidebarView+Projects.swift").containsAll(
            [
                "if !project.isCatchAll {", "SidebarStackDiscoveryStatus(projectId: project.id)",
                "Button(\"Refresh Stacks\")", "workspaceManager.refreshWorkspaceStacks(in: project.id)",
                ".disabled(workspaceManager.refreshingWorkspaceStackProjectIds.contains(project.id))"
            ], "Named Projects have an explicit refresh action without duplicate discovery requests")
    }

    @Test
    func onlyExplicitNavigationRequestsRevealAfterExpansionCanRender() throws {
        let header = try SourceContract("Argus/Views/Sidebar/SidebarView+Header.swift")
        header.containsAll(
            [
                "ScrollViewReader { proxy in", ".onChange(of: workspaceManager.workspaceRevealRevision)",
                "await Task.yield()", "workspaceManager.workspaceRevealRevision == revision",
                "workspaceManager.selectedWorkspaceId == workspaceId", "proxy.scrollTo(workspaceId)"
            ], "explicit navigation, including reselection, reveals after the manager expands the hierarchy")
        header.excludes(
            ".onChange(of: workspaceManager.selectedWorkspaceId)", "selection observation must not force reveal")
        header.excludes(".onChange(of: workspaceManager.workspaceStack", "background discovery must not force reveal")
        header.excludes("toggleWorkspaceStack", "the reveal view must not change disclosure state")
        header.excludes("project.isExpanded =", "the reveal view must not override a user collapse")
    }

    @Test
    func stackRelationshipsStayInTheListWithoutASelectedStackFooter() throws {
        try SourceContract("Argus/Views/Sidebar/SidebarView+Header.swift").excludes(
            "SidebarSelectedStackFooter", "Stack Groups provide relationship context without a separate footer")
    }
}

extension WorkspaceStackUIContractTests {
    @Test(arguments: [(80.0, true), (100.0, true), (159.0, true), (160.0, false), (200.0, false)])
    func compactPresentationUsesTheAllocatedWidth(width: Double, compact: Bool) {
        let metrics = SidebarWidthMetrics(width: width)
        #expect(metrics.isCompact == compact)
        let standard = SidebarWidthMetrics(width: SidebarLayout.leftDefaultWidth)
        if compact {
            #expect(metrics.rowPadding < standard.rowPadding)
            #expect(metrics.rowSpacing < standard.rowSpacing)
            #expect(metrics.stackGutterWidth < standard.stackGutterWidth)
            #expect(metrics.stackGutterWidth >= 4)
        } else {
            #expect(metrics.rowPadding == standard.rowPadding)
            #expect(metrics.rowSpacing == standard.rowSpacing)
            #expect(metrics.stackGutterWidth == standard.stackGutterWidth)
        }
    }

    @Test
    func sidebarWidthIsMeasuredOnceAndSharedRatherThanClippingOverflow() throws {
        let sidebar = try SourceContract("Argus/Views/Sidebar/SidebarView.swift")
        sidebar.contains(
            ".environment(\\.sidebarWidthMetrics, SidebarWidthMetrics(width: geometry.size.width))",
            "compact presentation follows actual allocation, not a stale persisted width")
        for companion in ["Header", "Projects", "WorkspaceRow", "Stacks"] {
            try SourceContract("Argus/Views/Sidebar/SidebarView+\(companion).swift").contains(
                "@Environment(\\.sidebarWidthMetrics)", "all sidebar rows consume the shared width decision")
        }
        sidebar.excludes(".clipped()", "required controls must fit instead of being clipped")
        sidebar.excludes(".scaleEffect(", "narrow layout must not shrink action hit targets")
    }

    @Test
    func narrowProjectHeadersShareActionsAndUserDisclosureCancelsPendingReveal() throws {
        let projects = try SourceContract("Argus/Views/Sidebar/SidebarView+Projects.swift")
        projects.containsAll(
            [
                "if !sidebarMetrics.isCompact || hasStackDiscoveryStatus",
                "if !sidebarMetrics.isCompact || !hasStackDiscoveryStatus",
                "SidebarStackDiscoveryStatus(projectId: project.id)", "addWorkspaceButton",
                ".frame(width: 20, height: 20)", "Button(\"Add Workspace…\")", "Button(\"Refresh Stacks\")"
            ], "compact headers reserve one action slot and keep both operations in the context menu")
        let disclosure = try projects.section(
            after: "private var disclosureButton: some View {", before: "\n    private var")
        let cancellation = try #require(disclosure.range(of: "cancelPendingWorkspaceStackReveal(in: project.id)"))
        let toggle = try #require(disclosure.range(of: "project.isExpanded.toggle()"))
        #expect(cancellation.upperBound < toggle.lowerBound)
        let between = disclosure[cancellation.upperBound..<toggle.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(between.isEmpty)
    }

    @Test
    func compactRowsRetainBadgesAndRails() throws {
        let row = try SourceContract("Argus/Views/Sidebar/SidebarView+WorkspaceRow.swift")
        let compact = try row.section(after: "if sidebarMetrics.isCompact {", before: "} else {")
        let labels = try #require(compact.range(of: "workspaceLabels"))
        let badge = try #require(compact.range(of: "runningProcessBadge"))
        #expect(compact.contains("VStack(alignment: .leading"))
        #expect(compact.contains("workspaceIcon"))
        #expect(labels.lowerBound < badge.lowerBound)
        #expect(compact.contains(".frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)"))
        let badgeView = try row.section(after: "private var runningProcessBadge: some View {", before: "@ViewBuilder")
        #expect(badgeView.contains("if runningProcessCount > 0 || sidebarMetrics.isCompact"))
        #expect(badgeView.contains(".opacity(runningProcessCount > 0 ? 1 : 0)"))
        #expect(badgeView.contains(".allowsHitTesting(runningProcessCount > 0)"))
        #expect(badgeView.contains(".accessibilityHidden(runningProcessCount == 0)"))
        try SourceContract("Argus/Views/Sidebar/SidebarView+Stacks.swift").containsAll(
            [
                "if !sidebarMetrics.isCompact {", "Image(systemName: \"square.3.layers.3d\")",
                ".frame(width: sidebarMetrics.stackGutterWidth(laneCount: laneCount), alignment: .leading)",
                ".environment(\\.sidebarStackLaneCount, group.laneCount)",
                ".offset(x: sidebarMetrics.stackLaneOffset(lane, laneCount: laneCount) - 0.5)",
                ".anchorPreference(key: SidebarStackRowAnchors.self, value: .center)"
            ], "compact Stacks omit decoration but keep measured directional rails")
    }
}
