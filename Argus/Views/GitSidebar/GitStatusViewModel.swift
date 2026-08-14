import Foundation
import SwiftUI

@MainActor
final class GitStatusViewModel: ObservableObject {
    @Published private(set) var state: GitStatusLoadState = .idle
    @Published private(set) var stateWorkspaceId: UUID?
    @Published private(set) var stateRootPath: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isMutationInProgress = false

    private let service: any GitStatusProviding
    let resolver: GitStatusRootResolver
    let pathClipboard: any GitStatusPathCopying
    let fileOperationConfirmer: any GitStatusFileOperationConfirming
    let previewService: any GitPreviewProviding

    private static let legacyWorkspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    private var snapshotOwner: GitStatusSnapshotOwner?
    private var requestGeneration: UInt64 = 0
    private var activeRequestIds: Set<UInt64> = []
    private var activeRefreshRequests: [GitStatusSnapshotOwner: UInt64] = [:]
    private var activeMutationRequest: (id: UInt64, owner: GitStatusSnapshotOwner)?
    private var pendingRefreshOwners: Set<GitStatusSnapshotOwner> = []

    init(
        service: any GitStatusProviding = GitStatusService(),
        resolver: GitStatusRootResolver = GitStatusRootResolver(),
        pathClipboard: any GitStatusPathCopying = PasteboardGitStatusPathClipboard(),
        fileOperationConfirmer: any GitStatusFileOperationConfirming = AlertGitStatusFileOperationConfirmer(),
        previewService: any GitPreviewProviding = GitPreviewService()
    ) {
        self.service = service
        self.resolver = resolver
        self.pathClipboard = pathClipboard
        self.fileOperationConfirmer = fileOperationConfirmer
        self.previewService = previewService
    }

    func rootPath(for context: GitStatusRootContext) -> String {
        resolver.root(for: context)
    }

    func owner(
        workspaceId: UUID,
        context: GitStatusRootContext,
        presentation: GitStatusPresentation = .default
    ) -> GitStatusSnapshotOwner {
        let request = GitStatusRequest(
            rootPath: resolver.root(for: context),
            presentation: GitStatusPresentation(
                combineWorkingChangeSections: presentation.combineWorkingChangeSections,
                showBaseBranchChanges: presentation.showBaseBranchChanges,
                configuredBaseBranch: presentation.configuredBaseBranch ?? context.configuredBaseBranch
            )
        )
        return GitStatusSnapshotOwner(workspaceId: workspaceId, request: request)
    }

    func ownsSnapshot(_ owner: GitStatusSnapshotOwner) -> Bool {
        snapshotOwner == owner
    }

    func canPerformActions(for owner: GitStatusSnapshotOwner) -> Bool {
        ownsSnapshot(owner) && !isRefreshing
    }

    func activate(_ owner: GitStatusSnapshotOwner) {
        guard snapshotOwner != owner else { return }
        requestGeneration &+= 1
        snapshotOwner = owner
        stateWorkspaceId = owner.workspaceId
        stateRootPath = owner.rootPath
        state = .loading
        updateProgressState()
    }

    func clearSelection() {
        requestGeneration &+= 1
        snapshotOwner = nil
        stateWorkspaceId = nil
        stateRootPath = nil
        state = .idle
        updateProgressState()
    }

    func refresh(owner: GitStatusSnapshotOwner, exposesWorkspaceId: Bool) async {
        activate(owner, exposesWorkspaceId: exposesWorkspaceId)
        if activeRefreshRequests[owner] == requestGeneration { return }
        if activeMutationRequest?.owner == owner {
            pendingRefreshOwners.insert(owner)
            return
        }

        let requestId = beginRequest(owner: owner)
        pendingRefreshOwners.remove(owner)
        activeRefreshRequests[owner] = requestId
        let result = await service.status(request: owner.request)
        publish(result, owner: owner, requestId: requestId)
        if activeRefreshRequests[owner] == requestId {
            activeRefreshRequests[owner] = nil
        }
        finishRequest(requestId)
    }

    func initializeRepository(owner: GitStatusSnapshotOwner, exposesWorkspaceId: Bool) async {
        guard prepareMutationOwner(owner, exposesWorkspaceId: exposesWorkspaceId) else { return }
        guard let requestId = beginMutation(owner: owner) else { return }
        let result = await service.initializeRepository(request: owner.request)
        publish(result, owner: owner, requestId: requestId)
        finishMutation(requestId)
    }

    func performFileOperation(
        _ operation: GitStatusFileOperation,
        path: String,
        owner: GitStatusSnapshotOwner,
        exposesWorkspaceId: Bool
    ) async {
        guard prepareMutationOwner(owner, exposesWorkspaceId: exposesWorkspaceId) else { return }
        guard let requestId = beginMutation(owner: owner) else { return }
        let result = await service.performFileOperation(operation, request: owner.request, path: path)
        publish(result, owner: owner, requestId: requestId)
        finishMutation(requestId)
    }

    func performBulkFileOperation(
        _ operation: GitStatusFileOperation,
        paths: [String],
        owner: GitStatusSnapshotOwner,
        exposesWorkspaceId: Bool
    ) async {
        guard prepareMutationOwner(owner, exposesWorkspaceId: exposesWorkspaceId) else { return }
        guard let requestId = beginMutation(owner: owner) else { return }
        let result = await service.performBulkFileOperation(operation, request: owner.request, paths: paths)
        publish(result, owner: owner, requestId: requestId)
        finishMutation(requestId)
    }

    func performSectionFileOperation(
        _ operation: GitStatusFileOperation,
        sectionKind: GitChangeSectionKind,
        owner: GitStatusSnapshotOwner,
        exposesWorkspaceId: Bool
    ) async {
        guard prepareMutationOwner(owner, exposesWorkspaceId: exposesWorkspaceId) else { return }
        guard let requestId = beginMutation(owner: owner) else { return }
        let result = await service.performSectionFileOperation(
            operation,
            request: owner.request,
            sectionKind: sectionKind
        )
        publish(result, owner: owner, requestId: requestId)
        finishMutation(requestId)
    }

    private func activate(_ owner: GitStatusSnapshotOwner, exposesWorkspaceId: Bool) {
        guard snapshotOwner != owner else { return }
        requestGeneration &+= 1
        snapshotOwner = owner
        stateWorkspaceId = exposesWorkspaceId ? owner.workspaceId : nil
        stateRootPath = owner.rootPath
        state = .loading
        updateProgressState()
    }

    private func prepareMutationOwner(
        _ owner: GitStatusSnapshotOwner,
        exposesWorkspaceId: Bool
    ) -> Bool {
        if exposesWorkspaceId {
            return ownsSnapshot(owner)
        }
        activate(owner, exposesWorkspaceId: false)
        return true
    }

    private func beginMutation(owner: GitStatusSnapshotOwner) -> UInt64? {
        guard activeMutationRequest == nil, activeRefreshRequests[owner] == nil else { return nil }
        let requestId = beginRequest(owner: owner)
        activeMutationRequest = (requestId, owner)
        isMutationInProgress = true
        return requestId
    }

    private func finishMutation(_ requestId: UInt64) {
        let completedOwner =
            activeMutationRequest?.id == requestId
            ? activeMutationRequest?.owner
            : nil
        if completedOwner != nil {
            activeMutationRequest = nil
            isMutationInProgress = false
        }
        finishRequest(requestId)

        guard let completedOwner,
            pendingRefreshOwners.remove(completedOwner) != nil,
            snapshotOwner == completedOwner
        else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self, self.snapshotOwner == completedOwner else { return }
            await self.refresh(owner: completedOwner, exposesWorkspaceId: true)
        }
    }

    private func beginRequest(owner: GitStatusSnapshotOwner) -> UInt64 {
        requestGeneration &+= 1
        let requestId = requestGeneration
        activeRequestIds.insert(requestId)
        isRefreshing = true
        return requestId
    }

    private func finishRequest(_ requestId: UInt64) {
        activeRequestIds.remove(requestId)
        updateProgressState()
    }

    private func updateProgressState() {
        let currentRefreshIsActive = snapshotOwner.flatMap { activeRefreshRequests[$0] } != nil
        isRefreshing = currentRefreshIsActive || activeMutationRequest != nil
    }

    private func publish(
        _ result: GitStatusLoadState,
        owner: GitStatusSnapshotOwner,
        requestId: UInt64
    ) {
        guard requestId == requestGeneration, snapshotOwner == owner else { return }
        state = result
    }

    func legacyOwner(context: GitStatusRootContext) -> GitStatusSnapshotOwner {
        GitStatusSnapshotOwner(
            workspaceId: Self.legacyWorkspaceId,
            request: GitStatusRequest(
                rootPath: resolver.root(for: context),
                presentation: GitStatusPresentation(configuredBaseBranch: context.configuredBaseBranch)
            )
        )
    }
}
