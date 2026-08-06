import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct AgentStatusRuntimeTests {
    @Test
    func statusUpdatesAreAppliedAndOlderUpdatesAreIgnored() throws {
        let manager = makeWorkspaceManager()
        let store = AgentStatusStore()
        let runtime = AgentStatusRuntime(workspaceManager: manager, store: store)
        let workspace = try #require(manager.selectedWorkspace)
        let surfaceId = try #require(workspace.panelOrder.first)

        let running = runtime.receive(
            AgentStatusEvent(
                agentKey: "pi",
                workspaceId: workspace.id,
                surfaceId: surfaceId,
                state: .running,
                sessionId: "session-1",
                sequence: 2
            )
        )
        let stale = runtime.receive(
            AgentStatusEvent(
                agentKey: "pi",
                workspaceId: workspace.id,
                surfaceId: surfaceId,
                state: .idle,
                sessionId: "session-1",
                sequence: 1
            )
        )

        #expect(running == .accepted(applied: true))
        #expect(stale == .accepted(applied: false))
        #expect(store.effectiveStatus(workspaceId: workspace.id, surfaceId: surfaceId)?.state == .running)
    }

    @Test
    func aNewSessionReplacesAnOlderSessionAndLateUpdatesCannotClearIt() throws {
        let manager = makeWorkspaceManager()
        let store = AgentStatusStore()
        let runtime = AgentStatusRuntime(workspaceManager: manager, store: store)
        let workspace = try #require(manager.selectedWorkspace)
        let surfaceId = try #require(workspace.panelOrder.first)

        _ = runtime.receive(
            AgentStatusEvent(
                agentKey: "pi",
                workspaceId: workspace.id,
                surfaceId: surfaceId,
                state: .running,
                sessionId: "old-session",
                sequence: 1
            )
        )
        _ = runtime.receive(
            AgentStatusEvent(
                agentKey: "pi",
                workspaceId: workspace.id,
                surfaceId: surfaceId,
                state: .idle,
                sessionId: "new-session",
                sequence: 1
            )
        )
        let lateClear = runtime.receive(
            AgentStatusEvent(
                agentKey: "pi",
                workspaceId: workspace.id,
                surfaceId: surfaceId,
                state: nil,
                sessionId: "old-session",
                sequence: 2
            )
        )

        #expect(lateClear == .accepted(applied: false))
        #expect(store.effectiveStatus(workspaceId: workspace.id, surfaceId: surfaceId)?.state == .idle)
    }

    @Test
    func statusIsRejectedForUnknownWorkspaceOrSurface() throws {
        let manager = makeWorkspaceManager()
        let store = AgentStatusStore()
        let runtime = AgentStatusRuntime(workspaceManager: manager, store: store)
        let workspace = try #require(manager.selectedWorkspace)
        let surfaceId = try #require(workspace.panelOrder.first)

        let unknownWorkspace = runtime.receive(
            AgentStatusEvent(
                agentKey: "pi",
                workspaceId: UUID(),
                surfaceId: surfaceId,
                state: .running,
                sessionId: "session",
                sequence: 1
            )
        )
        let unknownSurface = runtime.receive(
            AgentStatusEvent(
                agentKey: "pi",
                workspaceId: workspace.id,
                surfaceId: UUID(),
                state: .running,
                sessionId: "session",
                sequence: 1
            )
        )

        #expect(unknownWorkspace == .rejected(code: .unknownWorkspace, message: "Unknown Workspace"))
        #expect(
            unknownSurface
                == .rejected(
                    code: .unknownTerminalSurface,
                    message: "Unknown or mismatched Terminal Surface"
                )
        )
    }

    @Test
    func statusCanBeCleared() throws {
        let manager = makeWorkspaceManager()
        let store = AgentStatusStore()
        let runtime = AgentStatusRuntime(workspaceManager: manager, store: store)
        let workspace = try #require(manager.selectedWorkspace)
        let surfaceId = try #require(workspace.panelOrder.first)

        _ = runtime.receive(
            AgentStatusEvent(
                agentKey: "pi",
                workspaceId: workspace.id,
                surfaceId: surfaceId,
                state: .running,
                sessionId: "session",
                sequence: 1
            )
        )
        let cleared = runtime.receive(
            AgentStatusEvent(
                agentKey: "pi",
                workspaceId: workspace.id,
                surfaceId: surfaceId,
                state: nil,
                sessionId: "session",
                sequence: 2
            )
        )

        #expect(cleared == .accepted(applied: true))
        #expect(store.effectiveStatus(workspaceId: workspace.id, surfaceId: surfaceId) == nil)
    }

    @Test
    func closingAWorkspaceOrSurfaceRemovesItsRuntimeStatus() throws {
        let manager = makeWorkspaceManager()
        let store = AgentStatusStore()
        let runtime = AgentStatusRuntime(workspaceManager: manager, store: store)
        let workspace = try #require(manager.selectedWorkspace)
        let surfaceId = try #require(workspace.panelOrder.first)

        _ = runtime.receive(
            AgentStatusEvent(
                agentKey: "pi",
                workspaceId: workspace.id,
                surfaceId: surfaceId,
                state: .running,
                sessionId: "session",
                sequence: 1
            )
        )
        runtime.removeStatus(workspaceId: workspace.id, surfaceId: surfaceId)
        #expect(store.entries.isEmpty)

        _ = runtime.receive(
            AgentStatusEvent(
                agentKey: "pi",
                workspaceId: workspace.id,
                surfaceId: surfaceId,
                state: .error,
                sessionId: "session-2",
                sequence: 1
            )
        )
        runtime.removeStatuses(forWorkspace: workspace.id)
        #expect(store.entries.isEmpty)
    }

    private func makeWorkspaceManager() -> WorkspaceManager {
        let suiteName = "ArgusAgentStatusRuntimeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return WorkspaceManager(
            settings: AppSettings(defaults: defaults),
            environment: ["ARGUS_UNDER_TEST": "1"]
        )
    }
}
