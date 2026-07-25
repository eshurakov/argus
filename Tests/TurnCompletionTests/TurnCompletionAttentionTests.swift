import Foundation
import Testing

@testable import Argus

@MainActor
private final class TurnCompletionCallbackSpy {
    private(set) var callCount = 0

    func record() {
        callCount += 1
    }
}

@Suite
@MainActor
struct TurnCompletionAttentionTests {
    @Test
    func attentionCollapsesPerTabAndSummarizesWorkspace() {
        let store = TurnCompletionAttentionStore()
        let workspaceId = UUID()
        let firstTab = UUID()
        let secondTab = UUID()

        #expect(
            store.record(
                agentKey: "kilo",
                eventId: "one",
                target: TurnCompletionAttentionTarget(workspaceId: workspaceId, tabId: firstTab),
                isViewed: false
            ) == .acceptedUnviewed(TurnCompletionAttentionTarget(workspaceId: workspaceId, tabId: firstTab)))
        #expect(
            store.record(
                agentKey: "kilo",
                eventId: "two",
                target: TurnCompletionAttentionTarget(workspaceId: workspaceId, tabId: firstTab),
                isViewed: false
            ) == .acceptedUnviewed(TurnCompletionAttentionTarget(workspaceId: workspaceId, tabId: firstTab)))

        store.record(
            agentKey: "other-agent",
            eventId: "one",
            target: TurnCompletionAttentionTarget(workspaceId: workspaceId, tabId: secondTab),
            isViewed: false
        )

        #expect(store.attentionTargets.count == 2)
        #expect(store.workspaceHasAttention(workspaceId))
        store.clearAttention(workspaceId: workspaceId, tabId: firstTab)
        #expect(!store.hasAttention(workspaceId: workspaceId, tabId: firstTab))
        #expect(store.hasAttention(workspaceId: workspaceId, tabId: secondTab))
    }

    @Test
    func duplicateEventIsIdempotentAndViewedEventsDoNotCreateAttention() {
        let store = TurnCompletionAttentionStore()
        let target = TurnCompletionAttentionTarget(workspaceId: UUID(), tabId: UUID())

        #expect(store.record(agentKey: "kilo", eventId: "event", target: target, isViewed: true) == .acceptedViewed)
        #expect(store.attentionTargets.isEmpty)
        #expect(store.record(agentKey: "kilo", eventId: "event", target: target, isViewed: false) == .duplicate)
        #expect(store.attentionTargets.isEmpty)
    }

    @Test
    func tabAndWorkspaceCleanupLeaveOtherAttentionUntouched() {
        let store = TurnCompletionAttentionStore()
        let firstWorkspace = UUID()
        let secondWorkspace = UUID()
        let firstTarget = TurnCompletionAttentionTarget(workspaceId: firstWorkspace, tabId: UUID())
        let secondTarget = TurnCompletionAttentionTarget(workspaceId: secondWorkspace, tabId: UUID())
        store.record(agentKey: "kilo", eventId: "one", target: firstTarget, isViewed: false)
        store.record(agentKey: "kilo", eventId: "two", target: secondTarget, isViewed: false)

        store.clearAttention(forWorkspace: firstWorkspace)

        #expect(!store.workspaceHasAttention(firstWorkspace))
        #expect(store.hasAttention(workspaceId: secondWorkspace, tabId: secondTarget.tabId))
    }

    @Test
    func unviewedTerminalSurfaceCreatesAttentionAndCallsCallbackOnce() throws {
        let fixture = makeRuntimeFixture(isMainWindowKey: false)
        let workspace = try #require(fixture.manager.selectedWorkspace)
        let surfaceId = try #require(workspace.activePanelId)
        let state = selectionState(in: fixture.manager, workspace: workspace)

        let result = fixture.runtime.receive(
            event(
                workspaceId: workspace.id,
                surfaceId: surfaceId,
                eventId: "unviewed"
            ))

        #expect(result == .accepted(requiresAttention: true))
        #expect(fixture.attentionStore.hasAttention(workspaceId: workspace.id, tabId: surfaceId))
        #expect(fixture.callbackSpy.callCount == 1)
        #expect(selectionState(in: fixture.manager, workspace: workspace) == state)
    }

    @Test
    func viewedActiveTabDoesNotCreateAttentionOrPlaySound() throws {
        let fixture = makeRuntimeFixture(isMainWindowKey: true)
        let workspace = try #require(fixture.manager.selectedWorkspace)
        let surfaceId = try #require(workspace.activePanelId)

        let result = fixture.runtime.receive(
            event(
                workspaceId: workspace.id,
                surfaceId: surfaceId,
                eventId: "viewed"
            ))

        #expect(result == .accepted(requiresAttention: false))
        #expect(fixture.attentionStore.attentionTargets.isEmpty)
        #expect(fixture.callbackSpy.callCount == 0)
    }

    @Test
    func duplicateUnviewedEventIsAcceptedWithoutRepeatingCallback() throws {
        let fixture = makeRuntimeFixture(isMainWindowKey: false)
        let workspace = try #require(fixture.manager.selectedWorkspace)
        let surfaceId = try #require(workspace.activePanelId)
        let completion = event(workspaceId: workspace.id, surfaceId: surfaceId, eventId: "duplicate")

        #expect(fixture.runtime.receive(completion) == .accepted(requiresAttention: true))
        #expect(fixture.runtime.receive(completion) == .accepted(requiresAttention: false))
        #expect(fixture.attentionStore.hasAttention(workspaceId: workspace.id, tabId: surfaceId))
        #expect(fixture.callbackSpy.callCount == 1)
    }

    @Test
    func mismatchedWorkspaceAndNonterminalPanelAreRejectedWithoutChangingState() throws {
        let fixture = makeRuntimeFixture(isMainWindowKey: false)
        let selectedWorkspace = try #require(fixture.manager.selectedWorkspace)
        let otherWorkspace = try #require(fixture.manager.addWorkspace(workingDirectory: "/tmp/other"))
        let otherSurfaceId = try #require(otherWorkspace.activePanelId)
        fixture.manager.selectedWorkspaceId = selectedWorkspace.id
        selectedWorkspace.selectPanel(try #require(selectedWorkspace.activePanelId))
        let filePanel = selectedWorkspace.openFilePanel(rootPath: "/tmp", relativePath: "not-a-terminal.txt")
        selectedWorkspace.selectPanel(try #require(selectedWorkspace.panelOrder.first))
        let state = selectionState(in: fixture.manager, workspace: selectedWorkspace)

        for completion in [
            event(workspaceId: selectedWorkspace.id, surfaceId: otherSurfaceId, eventId: "mismatch"),
            event(workspaceId: selectedWorkspace.id, surfaceId: filePanel.id, eventId: "file")
        ] {
            #expect(
                fixture.runtime.receive(completion)
                    == .rejected(
                        code: .unknownTerminalSurface,
                        message: "Unknown or mismatched terminal surface"
                    ))
        }

        #expect(fixture.attentionStore.attentionTargets.isEmpty)
        #expect(fixture.callbackSpy.callCount == 0)
        #expect(selectionState(in: fixture.manager, workspace: selectedWorkspace) == state)
    }

    @Test
    func splitTerminalSurfaceCreatesAttentionForContainingTopLevelTab() throws {
        let fixture = makeRuntimeFixture(isMainWindowKey: false)
        let workspace = try #require(fixture.manager.selectedWorkspace)
        let tabId = try #require(workspace.activePanelId)
        let splitSurface = try #require(workspace.splitActiveTerminal(direction: .vertical)).id
        let state = selectionState(in: fixture.manager, workspace: workspace)

        let result = fixture.runtime.receive(
            event(
                workspaceId: workspace.id,
                surfaceId: splitSurface,
                eventId: "split"
            ))

        #expect(result == .accepted(requiresAttention: true))
        #expect(fixture.attentionStore.hasAttention(workspaceId: workspace.id, tabId: tabId))
        #expect(!fixture.attentionStore.hasAttention(workspaceId: workspace.id, tabId: splitSurface))
        #expect(fixture.callbackSpy.callCount == 1)
        #expect(selectionState(in: fixture.manager, workspace: workspace) == state)
    }

    private func makeRuntimeFixture(isMainWindowKey: Bool) -> TurnCompletionRuntimeFixture {
        let suiteName = "ArgusTests.TurnCompletionAttention.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = WorkspaceManager(
            settings: AppSettings(defaults: defaults),
            sessionSnapshotURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathComponent("session.json"),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
        let attentionStore = TurnCompletionAttentionStore()
        let callbackSpy = TurnCompletionCallbackSpy()
        let runtime = TurnCompletionRuntime(
            workspaceManager: manager,
            attentionStore: attentionStore,
            isMainWindowKey: { isMainWindowKey },
            onAcceptedUnviewed: { callbackSpy.record() }
        )
        return TurnCompletionRuntimeFixture(
            manager: manager,
            attentionStore: attentionStore,
            callbackSpy: callbackSpy,
            runtime: runtime
        )
    }

    private func event(workspaceId: UUID, surfaceId: UUID, eventId: String) -> TurnCompletionEvent {
        TurnCompletionEvent(
            agentKey: "kilo",
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            eventId: eventId
        )
    }

    private func selectionState(in manager: WorkspaceManager, workspace: Workspace) -> SelectionState {
        SelectionState(
            selectedWorkspaceId: manager.selectedWorkspaceId,
            activeTabId: workspace.activeTabId,
            focusedPaneId: workspace.activePanelId
        )
    }
}

@MainActor
private struct TurnCompletionRuntimeFixture {
    let manager: WorkspaceManager
    let attentionStore: TurnCompletionAttentionStore
    let callbackSpy: TurnCompletionCallbackSpy
    let runtime: TurnCompletionRuntime
}

private struct SelectionState: Equatable {
    let selectedWorkspaceId: UUID?
    let activeTabId: UUID?
    let focusedPaneId: UUID?
}
