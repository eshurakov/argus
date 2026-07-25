import AppKit
import Foundation

extension WorkspaceManager {
    func selectWorkspace(_ workspaceId: UUID) {
        guard workspaces.contains(where: { $0.id == workspaceId }) else { return }
        selectedWorkspace?.activePanel?.unfocus()
        selectedWorkspaceId = workspaceId
        selectedWorkspace?.activePanel?.focus()
        acknowledgeSelectedActiveTabIfViewed()
    }

    func selectWorkspaceByIndex(_ index: Int) {
        let ordered = sidebarOrderedWorkspaces
        guard index >= 0, index < ordered.count else { return }
        selectWorkspace(ordered[index].workspace.id)
    }

    func selectLastWorkspace() {
        guard let last = sidebarOrderedWorkspaces.last else { return }
        selectWorkspace(last.workspace.id)
    }

    func selectNextWorkspace() {
        guard let currentId = selectedWorkspaceId,
            let currentIndex = workspaces.firstIndex(where: { $0.id == currentId })
        else { return }
        selectWorkspace(workspaces[(currentIndex + 1) % workspaces.count].id)
    }

    func selectPreviousWorkspace() {
        guard let currentId = selectedWorkspaceId,
            let currentIndex = workspaces.firstIndex(where: { $0.id == currentId })
        else { return }
        let previousIndex = (currentIndex - 1 + workspaces.count) % workspaces.count
        selectWorkspace(workspaces[previousIndex].id)
    }

    func renameWorkspace(_ workspaceId: UUID, title: String) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return }
        workspace.setCustomTitle(title)
        if selectedWorkspaceId == workspaceId {
            notifyWorkspaceContextChanged()
        }
    }

    @discardableResult
    func setStandaloneWorkspaceRoot(_ workspaceId: UUID, directoryURL: URL) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }),
            workspace.workspaceType == .external
        else { return false }

        let standardizedURL = directoryURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return false }

        guard workspace.currentDirectory != standardizedURL.path else { return true }
        workspace.currentDirectory = standardizedURL.path
        if selectedWorkspaceId == workspaceId {
            notifyWorkspaceContextChanged()
        }
        return true
    }

    func reorderWorkspace(from source: Int, to destination: Int) {
        guard source >= 0, source < workspaces.count,
            destination >= 0, destination < workspaces.count,
            source != destination
        else { return }
        workspaces.insert(workspaces.remove(at: source), at: destination)
    }

    func reorderWorkspace(
        in projectId: UUID,
        moving workspaceId: UUID,
        before targetWorkspaceId: UUID
    ) {
        guard let project = projects.first(where: { $0.id == projectId }),
            let source = project.workspaceIds.firstIndex(of: workspaceId),
            let target = project.workspaceIds.firstIndex(of: targetWorkspaceId),
            source != target
        else { return }
        project.moveWorkspace(from: source, to: source < target ? max(target - 1, 0) : target)
        syncFlatWorkspaceOrderToSidebarOrder()
    }

    @discardableResult
    func addTab(workingDirectory: String? = nil) -> TerminalPanel? {
        selectedWorkspace?.addTerminalPanel(workingDirectory: workingDirectory)
    }

    @discardableResult
    func addBrowserTab(url: URL? = nil) -> BrowserPanel? {
        selectedWorkspace?.addBrowserPanel(url: url, configuration: browserPanelConfiguration)
    }

    func requestFindInActiveBrowser() {
        (selectedWorkspace?.activePanel as? BrowserPanel)?.requestFind()
    }

    func selectPreviousTab() {
        selectedWorkspace?.selectPreviousTab()
        acknowledgeSelectedActiveTabIfViewed()
    }

    func selectNextTab() {
        selectedWorkspace?.selectNextTab()
        acknowledgeSelectedActiveTabIfViewed()
    }

    @discardableResult
    func splitActiveTerminal(direction: PanelSplitDirection) -> TerminalPanel? {
        selectedWorkspace?.splitActiveTerminal(direction: direction)
    }

    func closeCurrentTab() {
        guard let workspace = selectedWorkspace else { return }
        guard let activePanelId = workspace.activePanelId,
            let activeTabId = workspace.activeTabId
        else { return }

        if (workspace.activeTabLayout?.leaves.count ?? 1) > 1 {
            closePane(activePanelId, in: workspace)
            return
        }

        requestCloseTab(activeTabId, in: workspace.id)
    }

    /// Removes a workspace, optionally deleting its associated git worktree first.
    @discardableResult
    func removeWorkspace(
        _ workspaceId: UUID,
        deletingWorktree: Bool,
        onProgress: (@MainActor @Sendable (WorkspaceDeletionStage) -> Void)? = nil
    ) async -> Bool {
        lastWorkspaceDeletionError = nil
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return false }

        if deletingWorktree,
            let worktreePath = workspace.worktreePath,
            let project = project(for: workspaceId),
            !project.isCatchAll
        {
            do {
                onProgress?(.removingWorktree)
                try await worktreeService.removeWorktree(
                    repositoryPath: project.repositoryPath,
                    worktreePath: worktreePath,
                    force: true
                )
            } catch let error as WorktreeError {
                lastWorkspaceDeletionError = error
                print("Failed to remove worktree before closing workspace: \(error.localizedDescription)")
                return false
            } catch {
                let deletionError = WorktreeError.worktreeRemovalFailed(error.localizedDescription)
                lastWorkspaceDeletionError = deletionError
                print("Failed to remove worktree before closing workspace: \(deletionError.localizedDescription)")
                return false
            }
        }
        onProgress?(.closingWorkspace)
        await Task.yield()
        removeWorkspaceFromState(workspaceId)
        return true
    }

    func requestCloseTab(_ tabId: UUID, in workspaceId: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }),
            workspace.panelOrder.contains(tabId)
        else { return }

        let closesLastTerminalTab =
            workspace.panelOrder.count == 1
            && workspace.layout(for: tabId).leaves.contains(where: {
                workspace.panels[$0]?.panelType == .terminal
            })
        if closesLastTerminalTab {
            NotificationCenter.default.post(
                name: .showCloseWorkspaceConfirmation,
                object: nil,
                userInfo: [
                    "workspaceId": workspace.id,
                    "requestedByLastTerminalTab": true
                ]
            )
            return
        }

        turnCompletionRuntime?.removeAttention(workspaceId: workspaceId, tabId: tabId)
        workspace.closeTab(tabId)
        if workspace.panelOrder.isEmpty {
            removeWorkspace(workspace.id)
        }
    }

    func handleWorkspaceShortcut(number: Int) {
        if number == 9 {
            selectLastWorkspace()
        } else {
            selectWorkspaceByIndex(number - 1)
        }
    }

    func workspace(containingPanel panelId: UUID) -> Workspace? {
        workspaces.first { $0.panels[panelId] != nil }
    }

    /// Resolves a Terminal Surface only when it currently belongs to the
    /// supplied Workspace, returning its containing Top-level Tab.
    func resolveTerminalSurface(
        workspaceId: UUID,
        surfaceId: UUID
    ) -> (workspace: Workspace, tabId: UUID)? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }),
            let tabId = workspace.topLevelTabId(containingTerminalSurface: surfaceId)
        else { return nil }
        return (workspace, tabId)
    }

    func focusPanel(_ panelId: UUID) {
        guard let workspace = workspace(containingPanel: panelId) else { return }
        if selectedWorkspaceId != workspace.id {
            selectedWorkspaceId = workspace.id
        }
        workspace.selectPanel(panelId)
        acknowledgeSelectedActiveTabIfViewed()
    }

    func sidebarNumber(for workspaceId: UUID) -> Int? {
        globalSidebarIndex(for: workspaceId)
    }

    var sidebarOrderedWorkspaces: [(project: Project, workspace: Workspace)] {
        projects.flatMap { project in
            project.workspaceIds.compactMap { workspaceId in
                workspaces.first(where: { $0.id == workspaceId }).map { (project, $0) }
            }
        }
    }

    func globalSidebarIndex(for workspaceId: UUID) -> Int? {
        sidebarOrderedWorkspaces.firstIndex { $0.workspace.id == workspaceId }.map { $0 + 1 }
    }

    private func syncFlatWorkspaceOrderToSidebarOrder() {
        let orderedIds = sidebarOrderedWorkspaces.map(\.workspace.id)
        let indexById = Dictionary(
            uniqueKeysWithValues: orderedIds.enumerated().map { ($0.element, $0.offset) }
        )
        workspaces.sort { lhs, rhs in
            (indexById[lhs.id] ?? Int.max) < (indexById[rhs.id] ?? Int.max)
        }
    }

    private var browserPanelConfiguration: BrowserPanelConfiguration {
        BrowserPanelConfiguration(
            homepage: settings.homepage,
            searchProvider: settings.searchProvider,
            pageZoom: settings.defaultZoom,
            developerToolsEnabled: settings.webInspectorEnabled,
            dataStore: settings.browserDataStore
        )
    }

    func acknowledgeSelectedActiveTabIfViewed() {
        guard let workspace = selectedWorkspace, let tabId = workspace.activeTabId else { return }
        turnCompletionRuntime?.acknowledgeViewedTab(
            workspaceId: workspace.id,
            tabId: tabId,
            isMainWindowKey: NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.isKeyWindow }
        )
    }

    private func closePane(_ panelId: UUID, in workspace: Workspace) {
        guard let tabId = workspace.panelOrder.first(where: { workspace.layout(for: $0).contains(panelId) }) else {
            return
        }
        let layout = workspace.layout(for: tabId)
        if layout.leaves.count == 1 {
            turnCompletionRuntime?.removeAttention(workspaceId: workspace.id, tabId: tabId)
        } else if panelId == tabId, let replacement = layout.removingLeaf(panelId)?.leaves.first {
            turnCompletionRuntime?.migrateAttention(workspaceId: workspace.id, from: tabId, to: replacement)
        }
        workspace.closePane(panelId)
    }
}
