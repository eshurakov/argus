import Foundation

/// A live Agent Status update received from an Agent Integration.
///
/// A nil state is used only by `agent.statusCleared` to remove the exact
/// status entry that belongs to the reporting session.
struct AgentStatusEvent: Sendable, Equatable {
    let agentKey: String
    let workspaceId: UUID
    let surfaceId: UUID?
    let state: AgentStatusState?
    let sessionId: String
    let sequence: UInt64
}

enum AgentStatusDeliveryResult: Sendable, Equatable {
    case accepted(applied: Bool)
    case rejected(code: AgentStatusRejectionCode, message: String)
}

enum AgentStatusRejectionCode: String, Sendable, Equatable {
    case unavailable
    case unknownWorkspace = "unknown_workspace"
    case unknownTerminalSurface = "unknown_terminal_surface"
}

/// Main-actor boundary between socket input and ephemeral Agent Status Entries.
///
/// Status updates are ordered per agent and scope. A new reporting session may
/// replace an older one, while late updates from the same session cannot move
/// the UI backwards. This is process-local state and is never persisted.
@MainActor
final class AgentStatusRuntime {
    private struct SourceKey: Hashable {
        let agentKey: String
        let workspaceId: UUID
        let surfaceId: UUID?
    }

    private struct LatestUpdate {
        let sessionId: String
        let sequence: UInt64
    }

    private let workspaceManager: WorkspaceManager
    private let store: AgentStatusStore
    private var latestUpdates: [SourceKey: LatestUpdate] = [:]
    private var retiredSessionIDs: [SourceKey: Set<String>] = [:]

    init(workspaceManager: WorkspaceManager, store: AgentStatusStore) {
        self.workspaceManager = workspaceManager
        self.store = store
    }

    func receive(_ event: AgentStatusEvent) -> AgentStatusDeliveryResult {
        guard !event.agentKey.isEmpty, !event.sessionId.isEmpty, event.sequence > 0 else {
            return .rejected(code: .unavailable, message: "Invalid Agent Status identity")
        }
        guard workspaceManager.workspaces.contains(where: { $0.id == event.workspaceId }) else {
            return .rejected(code: .unknownWorkspace, message: "Unknown Workspace")
        }
        if let surfaceId = event.surfaceId,
            workspaceManager.resolveTerminalSurface(
                workspaceId: event.workspaceId,
                surfaceId: surfaceId
            ) == nil
        {
            return .rejected(code: .unknownTerminalSurface, message: "Unknown or mismatched Terminal Surface")
        }

        let key = SourceKey(
            agentKey: event.agentKey,
            workspaceId: event.workspaceId,
            surfaceId: event.surfaceId
        )
        guard acceptOrdering(for: key, sessionId: event.sessionId, sequence: event.sequence) else {
            return .accepted(applied: false)
        }

        if let state = event.state {
            store.setStatus(
                state,
                agentKey: event.agentKey,
                workspaceId: event.workspaceId,
                surfaceId: event.surfaceId
            )
        } else {
            store.clearStatus(
                agentKey: event.agentKey,
                workspaceId: event.workspaceId,
                surfaceId: event.surfaceId
            )
        }
        return .accepted(applied: true)
    }

    /// Removes all Agent Status Entries associated with a closed Terminal Surface.
    func removeStatus(workspaceId: UUID, surfaceId: UUID) {
        store.clearStatuses(workspaceId: workspaceId, surfaceId: surfaceId)
        removeOrdering(workspaceId: workspaceId, surfaceId: surfaceId)
    }

    /// Removes all Agent Status Entries associated with a closed Workspace.
    func removeStatuses(forWorkspace workspaceId: UUID) {
        store.clearStatuses(forWorkspace: workspaceId)
        latestUpdates = latestUpdates.filter { $0.key.workspaceId != workspaceId }
        retiredSessionIDs = retiredSessionIDs.filter { $0.key.workspaceId != workspaceId }
    }

    func clearAll() {
        store.clearAll()
        latestUpdates.removeAll()
        retiredSessionIDs.removeAll()
    }

    private func acceptOrdering(for key: SourceKey, sessionId: String, sequence: UInt64) -> Bool {
        if retiredSessionIDs[key]?.contains(sessionId) == true {
            return false
        }

        if let latest = latestUpdates[key] {
            if latest.sessionId == sessionId {
                guard sequence > latest.sequence else { return false }
            } else {
                retiredSessionIDs[key, default: []].insert(latest.sessionId)
            }
        }
        latestUpdates[key] = LatestUpdate(sessionId: sessionId, sequence: sequence)
        return true
    }

    private func removeOrdering(workspaceId: UUID, surfaceId: UUID?) {
        latestUpdates = latestUpdates.filter {
            $0.key.workspaceId != workspaceId || $0.key.surfaceId != surfaceId
        }
        retiredSessionIDs = retiredSessionIDs.filter {
            $0.key.workspaceId != workspaceId || $0.key.surfaceId != surfaceId
        }
    }
}
