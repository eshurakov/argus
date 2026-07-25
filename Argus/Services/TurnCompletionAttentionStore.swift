import AppKit
import Combine
import Foundation

struct TurnCompletionAttentionTarget: Hashable, Sendable {
    let workspaceId: UUID
    let tabId: UUID
}

enum TurnCompletionAttentionRecording: Sendable, Equatable {
    case acceptedUnviewed(TurnCompletionAttentionTarget)
    case acceptedViewed
    case duplicate
}

/// Process-wide, runtime-only owner of unseen Turn Completion Attention.
///
/// This is intentionally separate from AgentStatusStore: Agent Status Entries
/// represent current telemetry, while this store represents unseen events.
@MainActor
final class TurnCompletionAttentionStore: ObservableObject {
    static let shared = TurnCompletionAttentionStore()

    @Published private(set) var attentionTargets: Set<TurnCompletionAttentionTarget> = []

    private var acceptedEventIDs: Set<IntegrationEventID> = []

    /// Records a validated event. Event identifiers remain deduplicated for
    /// the life of this process, including after their attention is cleared.
    func record(
        agentKey: String,
        eventId: String,
        target: TurnCompletionAttentionTarget,
        isViewed: Bool
    ) -> TurnCompletionAttentionRecording {
        let integrationEventID = IntegrationEventID(agentKey: agentKey, eventId: eventId)
        guard acceptedEventIDs.insert(integrationEventID).inserted else { return .duplicate }

        guard !isViewed else { return .acceptedViewed }
        attentionTargets.insert(target)
        return .acceptedUnviewed(target)
    }

    func hasAttention(workspaceId: UUID, tabId: UUID) -> Bool {
        attentionTargets.contains(TurnCompletionAttentionTarget(workspaceId: workspaceId, tabId: tabId))
    }

    func workspaceHasAttention(_ workspaceId: UUID) -> Bool {
        attentionTargets.contains { $0.workspaceId == workspaceId }
    }

    func clearAttention(workspaceId: UUID, tabId: UUID) {
        attentionTargets.remove(TurnCompletionAttentionTarget(workspaceId: workspaceId, tabId: tabId))
    }

    func clearAttention(forWorkspace workspaceId: UUID) {
        attentionTargets = attentionTargets.filter { $0.workspaceId != workspaceId }
    }

    func clearAllAttention() {
        attentionTargets.removeAll()
    }

    /// Rehomes attention if a future model operation migrates a Top-level Tab
    /// to another root or Workspace. Existing attention is merged at target.
    func migrateAttention(
        from source: TurnCompletionAttentionTarget,
        to destination: TurnCompletionAttentionTarget
    ) {
        guard attentionTargets.remove(source) != nil else { return }
        attentionTargets.insert(destination)
    }

    private struct IntegrationEventID: Hashable {
        let agentKey: String
        let eventId: String
    }
}

/// Main-actor boundary between socket input and Workspace runtime state.
@MainActor
final class TurnCompletionRuntime {
    private let workspaceManager: WorkspaceManager
    private let attentionStore: TurnCompletionAttentionStore
    private let isMainWindowKey: @MainActor () -> Bool
    private let onAcceptedUnviewed: @MainActor @Sendable () -> Void

    init(
        workspaceManager: WorkspaceManager,
        attentionStore: TurnCompletionAttentionStore,
        isMainWindowKey: @escaping @MainActor () -> Bool,
        onAcceptedUnviewed: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.workspaceManager = workspaceManager
        self.attentionStore = attentionStore
        self.isMainWindowKey = isMainWindowKey
        self.onAcceptedUnviewed = onAcceptedUnviewed
    }

    func receive(_ event: TurnCompletionEvent) -> TurnCompletionDeliveryResult {
        guard
            let resolved = workspaceManager.resolveTerminalSurface(
                workspaceId: event.workspaceId,
                surfaceId: event.surfaceId
            )
        else {
            return .rejected(code: .unknownTerminalSurface, message: "Unknown or mismatched terminal surface")
        }

        let target = TurnCompletionAttentionTarget(workspaceId: event.workspaceId, tabId: resolved.tabId)
        let isViewed =
            workspaceManager.selectedWorkspaceId == event.workspaceId
            && resolved.workspace.activeTabId == resolved.tabId
            && isMainWindowKey()

        switch attentionStore.record(
            agentKey: event.agentKey,
            eventId: event.eventId,
            target: target,
            isViewed: isViewed
        ) {
        case .acceptedUnviewed:
            onAcceptedUnviewed()
            return .accepted(requiresAttention: true)
        case .acceptedViewed, .duplicate:
            return .accepted(requiresAttention: false)
        }
    }

    /// Acknowledges a tab only after an integration boundary establishes it is
    /// viewed. It never changes Selected Workspace, Active Tab, or focus.
    func acknowledgeViewedTab(workspaceId: UUID, tabId: UUID, isMainWindowKey: Bool) {
        guard isMainWindowKey,
            workspaceManager.selectedWorkspaceId == workspaceId,
            let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId }),
            workspace.activeTabId == tabId
        else { return }
        attentionStore.clearAttention(workspaceId: workspaceId, tabId: tabId)
    }

    func removeAttention(forWorkspace workspaceId: UUID) {
        attentionStore.clearAttention(forWorkspace: workspaceId)
    }

    func removeAttention(workspaceId: UUID, tabId: UUID) {
        attentionStore.clearAttention(workspaceId: workspaceId, tabId: tabId)
    }

    func migrateAttention(workspaceId: UUID, from tabId: UUID, to replacementTabId: UUID) {
        attentionStore.migrateAttention(
            from: TurnCompletionAttentionTarget(workspaceId: workspaceId, tabId: tabId),
            to: TurnCompletionAttentionTarget(workspaceId: workspaceId, tabId: replacementTabId)
        )
    }
}

@MainActor
enum TurnCompletionSoundPlayer {
    static func play() {
        NSSound(named: NSSound.Name("Glass"))?.play()
    }
}

struct TurnCompletionEvent: Sendable, Equatable {
    let agentKey: String
    let workspaceId: UUID
    let surfaceId: UUID
    let eventId: String
}

enum TurnCompletionDeliveryResult: Sendable, Equatable {
    case accepted(requiresAttention: Bool)
    case rejected(code: TurnCompletionRejectionCode, message: String)
}

enum TurnCompletionRejectionCode: String, Sendable, Equatable {
    case unknownTerminalSurface = "unknown_terminal_surface"
}
