import AppKit
import SwiftUI
import Testing

@testable import Argus

@Suite(.serialized)
@MainActor
struct ProjectCollectionUITests {
    @Test(arguments: [80.0, 159.0, 160.0, 240.0])
    func nativeHeaderDisclosureKeepsSelectionAndFitsAllocatedWidth(width: Double) async throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let collection = try #require(manager.createCollection(name: "Client aPI with a long Collection name"))
        manager.moveProject(fixture.project.id, toCollection: collection.id)
        let selection = manager.selectedWorkspaceId
        let header = SidebarCollectionHeader(collection: collection)
            .environmentObject(manager)
            .environmentObject(manager.settings)
            .environment(WindowFocusState())
            .environment(\.sidebarWidthMetrics, SidebarWidthMetrics(width: width))
        let host = NSHostingView(rootView: header)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        let button = try #require(
            accessibilityDescendants(host).first {
                $0.accessibilityIdentifier?() == "collection-\(collection.id)"
            })
        #expect(button.accessibilityRole?() == .button)
        #expect((button.accessibilityFrame?().width ?? 0) <= width + 1)
        #expect((button.accessibilityFrame?().width ?? 0) >= width - 1)
        #expect((button.accessibilityFrame?().height ?? 0) >= 20)
        #expect(button.accessibilityPerformPress?() == true)
        #expect(manager.collections.first?.isExpanded == false)
        #expect(manager.selectedWorkspaceId == selection)
        #expect(manager.workspaceRevealRevision == 0)
    }

    @Test(arguments: [80.0, 200.0])
    func collectionInsetDoesNotShrinkWorkspaceSelectionHitArea(width: Double) async throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let row = SidebarWorkspaceRow(
            workspace: fixture.child, globalIndex: 2, shortcutDigit: 2,
            isSelected: true, onSelect: { manager.selectWorkspace(fixture.child.id) }
        )
        .environmentObject(manager)
        .environmentObject(manager.settings)
        .environmentObject(AgentStatusStore())
        .environmentObject(TurnCompletionAttentionStore())
        .environmentObject(WorkspacePullRequestStatusModel())
        .environment(WindowFocusState())
        .environment(\.sidebarWidthMetrics, SidebarWidthMetrics(width: width))
        .environment(\.sidebarCollectionContentInset, width < 160 ? 0 : 8)
        let host = NSHostingView(rootView: row)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        let button = try #require(
            accessibilityDescendants(host).first {
                $0.accessibilityRole?() == .button && $0.accessibilityLabel?()?.hasPrefix("Workspace 2") == true
            })
        #expect((button.accessibilityFrame?().width ?? 0) >= width - 1)
        #expect((button.accessibilityFrame?().width ?? 0) <= width + 1)
        #expect(button.accessibilityPerformPress?() == true)
        #expect(manager.workspaceRevealRevision == 1)
        #expect(manager.selectedWorkspaceId == fixture.child.id)
    }

    @Test
    func collapsedSummaryShowsProjectWorkspaceAndUnacknowledgedAttention() async throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        fixture.project.displayName = "Client API"
        fixture.child.setCustomTitle("Implement feature")
        let attention = TurnCompletionAttentionStore()
        let target = TurnCompletionAttentionTarget(workspaceId: fixture.child.id, tabId: UUID())
        _ = attention.record(agentKey: "test", eventId: "complete", target: target, isViewed: false)
        let summary = SidebarCollapsedWorkspaceSummary(
            workspaceIds: fixture.project.workspaceIds, showsProjectContext: true
        )
        .environmentObject(manager)
        .environmentObject(manager.settings)
        .environmentObject(attention)
        .environment(WindowFocusState())
        let host = NSHostingView(rootView: summary)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        let labels = accessibilityDescendants(host).flatMap { element in
            let value: String? = element.accessibilityValue?()
            return [element.accessibilityLabel?(), value].compactMap { $0 }
        }.joined(separator: " ")
        #expect(labels.contains("Client API / Implement feature"))
        #expect(labels.contains("Turn Completion Attention"))
        #expect(attention.attentionTargets == [target])
        #expect(manager.selectedWorkspaceId == fixture.child.id)
    }

    @Test
    func creationAndExplicitMoveActionsAreWiredToNativeSheetsAndManager() throws {
        let app = try SourceContract("Argus/App/ArgusApp.swift")
        let header = try SourceContract("Argus/Views/Sidebar/SidebarView+Header.swift")
        for source in [app, header] {
            source.contains("Button(\"New Collection…\")", "both menus expose Collection creation")
            source.contains("name: .showCollectionSheet", "both menus use the native sheet route")
        }
        try SourceContract("Argus/Views/MainWindowView.swift").contains(
            ".sheet(item: $collectionSheetRequest)", "Collection naming uses a sheet, not a content window")
        let collections = try SourceContract("Argus/Views/Sidebar/SidebarView+Collections.swift")
        collections.containsAll(
            [
                "Menu(\"Move to Collection\")", "Button(\"No Collection\")", "Button(\"Move Project Up\")",
                "Button(\"Move Project Down\")", "Button(\"Remove Collection\")", "Button(\"Rename Collection…\")",
                ".cursor(.pointingHand)", ".onHover", ".focused($isFocused)", ".contentShape(Rectangle())"
            ], "explicit actions and native interaction are available without dragging")
        collections.excludes(".textCase(", "Collection names retain entered casing")
        collections.excludes("collection.projectIds.count", "Collection headers do not show counts")
    }

    private func accessibilityDescendants(_ object: AnyObject) -> [AnyObject] {
        [object] + (object.accessibilityChildren?() ?? []).flatMap { accessibilityDescendants($0 as AnyObject) }
    }
}
