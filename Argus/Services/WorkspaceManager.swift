import Combine
import Foundation
import SwiftUI

enum WorkspaceDeletionStage: Int, CaseIterable, Sendable {
    case removingWorktree
    case closingWorkspace
}

/// Central state manager for all workspaces in the application.
///
/// WorkspaceManager owns the ordered list of workspaces, tracks the current
/// selection, and provides CRUD operations plus keyboard-shortcut handlers.
/// It is the single source of truth for workspace state and is shared via
/// the SwiftUI environment as an `@EnvironmentObject`.
///
/// Phase 2 adds project management: workspaces are grouped under projects,
/// each backed by a git repository with worktree support. The sidebar index
/// used by Cmd+1–8 shortcuts reflects project-grouped ordering.
@MainActor
final class WorkspaceManager: ObservableObject {

    // MARK: - Published State

    /// Ordered list of workspaces (determines sidebar order).
    @Published internal(set) var workspaces: [Workspace] = []

    /// ID of the currently selected workspace.
    @Published var selectedWorkspaceId: UUID? {
        didSet { notifyWorkspaceContextChanged() }
    }

    /// Ordered list of projects (named projects first, catch-all last).
    @Published internal(set) var projects: [Project] = []

    /// The non-removable catch-all project for standalone workspaces.
    var catchAllProject: Project!

    /// Shared worktree service for git operations.
    let worktreeService = WorktreeService()

    /// Last workspace creation error for user-visible sheet feedback.
    var lastWorkspaceCreationError: WorktreeError?

    /// Last worktree deletion error for user-visible close feedback.
    internal(set) var lastWorkspaceDeletionError: WorktreeError?

    /// Location of the minimal Phase 2 session snapshot.
    private let sessionSnapshotURL: URL

    let settings: AppSettings
    var turnCompletionRuntime: TurnCompletionRuntime?

    // MARK: - Computed Properties

    /// The currently selected workspace, or `nil` if none is selected.
    var selectedWorkspace: Workspace? {
        guard let id = selectedWorkspaceId else { return nil }
        return workspaces.first { $0.id == id }
    }

    /// Formatted title for the active workspace context.
    var activeWorkspaceTitle: String {
        guard let workspace = selectedWorkspace else {
            return WorkspaceTitleFormatter.fallbackTitle
        }
        return WorkspaceTitleFormatter.title(
            workspaceTitle: workspace.displayTitle,
            contextName: activeWorkspaceContextName(for: workspace)
        )
    }

    /// Context component for the active workspace title: named project when
    /// available, otherwise the workspace directory basename.
    func activeWorkspaceContextName(for workspace: Workspace) -> String {
        let project = project(for: workspace.id)
        let projectName = project?.isCatchAll == false ? project?.displayName : nil
        return WorkspaceTitleFormatter.contextName(
            projectName: projectName,
            directoryPath: workspace.currentDirectory
        )
    }

    /// Index of the currently selected workspace in the sidebar.
    var selectedWorkspaceIndex: Int? {
        guard let id = selectedWorkspaceId else { return nil }
        return workspaces.firstIndex { $0.id == id }
    }

    // MARK: - Constants

    /// Maximum number of workspaces per window (spec: 128).
    static let maxWorkspaces = 128

    /// Default application support path for persisted session state.
    static let defaultSessionSnapshotURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Argus/session.json")

    // MARK: - Notification Observers

    nonisolated(unsafe) private var closeSurfaceObserver: NSObjectProtocol?
    nonisolated(unsafe) private var focusSurfaceObserver: NSObjectProtocol?

    // MARK: - Initialization

    init(
        settings: AppSettings,
        sessionSnapshotURL: URL = WorkspaceManager.defaultSessionSnapshotURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.settings = settings
        self.sessionSnapshotURL = sessionSnapshotURL

        if !Self.shouldSkipSessionRestore(settings: settings, environment: environment),
            restoreSessionIfAvailable(from: sessionSnapshotURL)
        {
            // Restored from disk.
        } else {
            createFreshSession()
        }

        // Observe surface-close notifications from GhosttyApp callbacks.
        closeSurfaceObserver = NotificationCenter.default.addObserver(
            forName: .argusCloseSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                let surfaceId = notification.object as? UUID
            else { return }
            self.handleSurfaceClosed(surfaceId)
        }

        // Track the focused split pane so split commands target the pane the
        // user last clicked or typed in.
        focusSurfaceObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeFirstResponder,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                let surfaceId = notification.object as? UUID
            else { return }
            self.focusPanel(surfaceId)
        }
    }

    deinit {
        if let observer = closeSurfaceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = focusSurfaceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Session Persistence

    /// Returns true when app session restore must be skipped for tests.
    private static func shouldSkipSessionRestore(
        settings: AppSettings,
        environment: [String: String]
    ) -> Bool {
        guard settings.restorePreviousSession else { return true }
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["ARGUS_DISABLE_SESSION_RESTORE"] == "1"
            || environment["ARGUS_UNDER_TEST"] == "1"
    }

    /// Creates a new default session with one catch-all workspace.
    private func createFreshSession() {
        let catchAll = Project.catchAll()
        self.catchAllProject = catchAll
        self.projects = [catchAll]

        let workspace = freshStandaloneWorkspace()
        workspaces = [workspace]
        catchAll.addWorkspace(workspace.id)
        selectedWorkspaceId = workspace.id
    }

    /// Builds the minimal durable Phase 2 session snapshot.
    func makeSessionSnapshot() -> ArgusSessionSnapshot {
        ArgusSessionSnapshot(
            selectedWorkspaceId: selectedWorkspaceId,
            projects: projects.map { $0.snapshot() },
            workspaces: workspaces.map { $0.snapshot() }
        )
    }

    /// Writes the current minimal session snapshot to disk.
    func saveSession(to url: URL? = nil) throws {
        let targetURL = url ?? sessionSnapshotURL
        let snapshot = makeSessionSnapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: targetURL, options: [.atomic])
    }

    /// Best-effort save used by app lifecycle hooks.
    func saveSession() {
        do {
            try saveSession(to: sessionSnapshotURL)
        } catch {
            print("Failed to save Argus session: \(error.localizedDescription)")
        }
    }

    /// Restores a minimal Phase 2 session snapshot from disk if it is valid.
    @discardableResult
    private func restoreSessionIfAvailable(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
            let snapshot = try? JSONDecoder().decode(ArgusSessionSnapshot.self, from: data)
        else { return false }
        return restoreSession(from: snapshot)
    }

    /// Restores a decoded session snapshot. Incompatible or empty snapshots are
    /// discarded by returning `false` so callers can create a fresh session.
    @discardableResult
    func restoreSession(from snapshot: ArgusSessionSnapshot) -> Bool {
        guard snapshot.isCompatible,
            !snapshot.workspaces.isEmpty,
            snapshot.workspaces.count <= Self.maxWorkspaces
        else { return false }

        let reconciledSnapshot = snapshot.reconciledForRestore()
        let restoredProjects = reconciledSnapshot.projects.map(Project.init(snapshot:))
        let catchAll = restoredProjects.first(where: { $0.isCatchAll }) ?? Project.catchAll()
        let restoredWorkspaces = reconciledSnapshot.workspaces.map(Workspace.init(snapshot:))

        self.catchAllProject = catchAll
        self.projects = restoredProjects
        self.workspaces = restoredWorkspaces
        self.selectedWorkspaceId = reconciledSnapshot.selectedWorkspaceId
        notifyWorkspaceContextChanged()
        return true
    }

    // MARK: - Surface Close Handling

    /// Handles a surface-closed notification by removing the corresponding
    /// panel from its workspace.
    private func handleSurfaceClosed(_ surfaceId: UUID) {
        guard let workspace = workspace(containingPanel: surfaceId) else { return }
        guard let tabId = workspace.panelOrder.first(where: { workspace.layout(for: $0).contains(surfaceId) }) else {
            return
        }
        let layout = workspace.layout(for: tabId)
        if layout.leaves.count == 1 {
            turnCompletionRuntime?.removeAttention(workspaceId: workspace.id, tabId: tabId)
        } else if surfaceId == tabId, let replacement = layout.removingLeaf(surfaceId)?.leaves.first {
            turnCompletionRuntime?.migrateAttention(workspaceId: workspace.id, from: tabId, to: replacement)
        }
        workspace.closePane(surfaceId)

        // An empty workspace is equivalent to a closed workspace.
        if workspace.panelOrder.isEmpty {
            removeWorkspace(workspace.id)
        }
    }

    // MARK: - Workspace CRUD

    /// Creates and appends a new workspace, selecting it immediately.
    ///
    /// - Parameters:
    ///   - title: Display title; defaults to `"Terminal"`.
    ///   - workingDirectory: Initial working directory for the first panel.
    /// - Returns: The new workspace, or `nil` if the limit has been reached.
    @discardableResult
    func addWorkspace(title: String? = nil, workingDirectory: String? = nil) -> Workspace? {
        guard workspaces.count < Self.maxWorkspaces else { return nil }

        let workspace = freshStandaloneWorkspace(
            title: title ?? "Terminal",
            workingDirectory: workingDirectory
        )
        workspaces.append(workspace)
        catchAllProject.addWorkspace(workspace.id)
        selectedWorkspaceId = workspace.id
        return workspace
    }

    /// Removes a workspace by ID, closing all of its panels.
    ///
    /// When the last workspace is removed a new empty workspace is created
    /// automatically (spec: "When the last workspace is closed, the system
    /// MUST create a new empty workspace automatically.").
    func removeWorkspace(_ workspaceId: UUID) {
        removeWorkspaceFromState(workspaceId)
    }

    func setTurnCompletionRuntime(_ runtime: TurnCompletionRuntime) {
        turnCompletionRuntime = runtime
    }

    func shouldConfirmWorktreeDeletionBeforeClosing(_ workspaceId: UUID) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }),
            workspace.worktreePath != nil,
            let project = project(for: workspaceId),
            !project.isCatchAll
        else { return false }
        return true
    }

    func removeWorkspaceFromState(_ workspaceId: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }

        let workspace = workspaces[index]

        turnCompletionRuntime?.removeAttention(forWorkspace: workspaceId)

        // Close all panels in the workspace before removal.
        for panelId in workspace.panelOrder {
            workspace.closeTab(panelId)
        }

        // Remove from parent project.
        if let project = project(for: workspaceId) {
            project.removeWorkspace(workspaceId)
        }

        workspaces.remove(at: index)

        // Maintain selection invariant.
        if selectedWorkspaceId == workspaceId {
            if workspaces.isEmpty {
                // Spec: always have at least one workspace.
                let newWorkspace = freshStandaloneWorkspace()
                workspaces.append(newWorkspace)
                catchAllProject.addWorkspace(newWorkspace.id)
                selectedWorkspaceId = newWorkspace.id
            } else {
                // Select the workspace at the same position (clamped).
                let newIndex = min(index, workspaces.count - 1)
                selectedWorkspaceId = workspaces[newIndex].id
            }
        }
    }

    func notifyWorkspaceContextChanged() {
        NotificationCenter.default.post(name: .workspaceContextDidChange, object: nil)
    }

    func freshStandaloneWorkspace(
        title: String = "Terminal",
        workingDirectory: String? = nil
    ) -> Workspace {
        Workspace(
            title: title,
            workingDirectory: workingDirectory ?? settings.defaultStandaloneWorkspaceDirectory
        )
    }
}
