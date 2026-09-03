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
/// each backed by a git repository with worktree support. Cmd+1–8 select by
/// global sidebar order; Cmd+9 selects the last Workspace.
@MainActor
// swiftlint:disable:next type_body_length
final class WorkspaceManager: ObservableObject {

    // MARK: - Published State

    /// Ordered list of workspaces (determines sidebar order).
    @Published var workspaces: [Workspace] = []

    /// ID of the currently selected workspace.
    @Published var selectedWorkspaceId: UUID? {
        didSet {
            if oldValue != selectedWorkspaceId {
                pendingWorkspaceStackReveal = nil
            }
            notifyWorkspaceContextChanged()
        }
    }

    /// Changes whenever the selected Workspace's filesystem context changes
    /// without changing Workspace identity.
    @Published private(set) var workspaceContextRevision: UInt64 = 0

    @Published internal(set) var workspaceRevealRevision: UInt64 = 0
    @Published internal(set) var workspaceStackSnapshots: [UUID: WorkspaceStackSnapshot] = [:]
    @Published internal(set) var workspaceStackErrors: [UUID: String] = [:]
    @Published internal(set) var refreshingWorkspaceStackProjectIds: Set<UUID> = []

    /// Ordered list of projects (named projects first, catch-all last).
    @Published var projects: [Project] = [] {
        didSet { reconcileWorkspaceStackObservations() }
    }

    @Published internal(set) var collections: [ProjectCollection] = []

    let workspaceStackReader: any WorkspaceStackReading
    var workspaceStackObservations: [UUID: (project: Project, observation: WorkspaceStackObservation)] = [:]
    var isObservingWorkspaceStacks = false
    var pendingWorkspaceStackReveal: PendingWorkspaceStackReveal?

    /// The non-removable catch-all project for standalone workspaces.
    var catchAllProject: Project!

    /// Shared worktree service for git operations.
    let worktreeService: WorktreeService

    /// Provider boundary used only by explicit Pull Request intake.
    let pullRequestService: GitHubPullRequestService

    /// Compatibility spelling for callers that name the provider explicitly.
    var githubPullRequestService: GitHubPullRequestService { pullRequestService }

    /// Last workspace creation error for user-visible sheet feedback.
    var lastWorkspaceCreationError: WorktreeError?

    /// Last typed Pull Request creation error for diagnostics and sheet retry.
    var lastPullRequestWorkspaceError: PullRequestWorkspaceError?

    /// Last worktree deletion error for user-visible close feedback.
    var lastWorkspaceDeletionError: WorktreeError?

    /// Location of the minimal Phase 2 session snapshot.
    ///
    /// This is the production Session Snapshot location for normal app
    /// instances and a temporary per-process location for test instances.
    let sessionSnapshotURL: URL

    let settings: AppSettings
    var turnCompletionRuntime: TurnCompletionRuntime?
    var agentStatusRuntime: AgentStatusRuntime?

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
        return sidebarOrderedWorkspaces.firstIndex { $0.workspace.id == id }
    }

    // MARK: - Constants

    /// Maximum number of workspaces per window (spec: 128).
    static let maxWorkspaces = 128

    /// Default application support path for persisted session state.
    static let defaultSessionSnapshotURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Argus/session.json")

    /// Root for session snapshots created by test instances. The process ID
    /// keeps concurrent test-host app instances isolated from one another.
    private static let testSessionSnapshotRootURL = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("Argus", isDirectory: true)
        .appendingPathComponent("TestSessions", isDirectory: true)

    // MARK: - Notification Observers

    nonisolated(unsafe) private var closeSurfaceObserver: NSObjectProtocol?
    nonisolated(unsafe) private var closeTabObserver: NSObjectProtocol?
    nonisolated(unsafe) private var focusSurfaceObserver: NSObjectProtocol?

    // MARK: - Initialization

    init(
        settings: AppSettings,
        sessionSnapshotURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        worktreeService: WorktreeService = WorktreeService(),
        pullRequestService: GitHubPullRequestService = GitHubPullRequestService(),
        workspaceStackReader: any WorkspaceStackReading = WorkspaceStackService()
    ) {
        self.settings = settings
        self.worktreeService = worktreeService
        self.pullRequestService = pullRequestService
        self.workspaceStackReader = workspaceStackReader
        self.sessionSnapshotURL = Self.resolvedSessionSnapshotURL(
            suppliedURL: sessionSnapshotURL,
            environment: environment
        )

        if !Self.shouldSkipSessionRestore(settings: settings, environment: environment),
            restoreSessionIfAvailable(from: self.sessionSnapshotURL)
        {
            // Restored from disk.
        } else {
            createFreshSession()
        }

        installNotificationObservers()
    }

    private func installNotificationObservers() {
        closeSurfaceObserver = NotificationCenter.default.addObserver(
            forName: .argusCloseSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                let surfaceId = notification.object as? UUID
            else { return }
            let processAlive = notification.userInfo?["processAlive"] as? Bool
            MainActor.assumeIsolated {
                self.handleSurfaceClosed(surfaceId, processAlive: processAlive)
            }
        }

        closeTabObserver = NotificationCenter.default.addObserver(
            forName: .argusCloseTab,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                let surfaceId = notification.object as? UUID
            else { return }
            MainActor.assumeIsolated {
                guard let workspace = self.workspace(containingPanel: surfaceId),
                    let tabId = workspace.panelOrder.first(where: {
                        workspace.layout(for: $0).contains(surfaceId)
                    })
                else { return }
                self.requestCloseTab(tabId, in: workspace.id)
            }
        }

        focusSurfaceObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeFirstResponder,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                let surfaceId = notification.object as? UUID
            else { return }
            MainActor.assumeIsolated { self.focusPanel(surfaceId) }
        }
    }

    /// Compatibility initializer for callers that use the provider-qualified
    /// dependency name while retaining the shorter primary spelling.
    convenience init(
        settings: AppSettings,
        sessionSnapshotURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        worktreeService: WorktreeService = WorktreeService(),
        githubPullRequestService: GitHubPullRequestService,
        workspaceStackReader: any WorkspaceStackReading = WorkspaceStackService()
    ) {
        self.init(
            settings: settings,
            sessionSnapshotURL: sessionSnapshotURL,
            environment: environment,
            worktreeService: worktreeService,
            pullRequestService: githubPullRequestService,
            workspaceStackReader: workspaceStackReader
        )
    }

    deinit {
        if let observer = closeSurfaceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = closeTabObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = focusSurfaceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Session Persistence

    /// Returns true when app session restore is disabled by Settings or by a
    /// supported test/restore environment override.
    private static func shouldSkipSessionRestore(
        settings: AppSettings,
        environment: [String: String]
    ) -> Bool {
        guard settings.restorePreviousSession else { return true }
        return isTestInstance(environment: environment)
    }

    /// Returns true when this process is a test instance. Test instances use
    /// isolated temporary Session Snapshot storage rather than the production
    /// application-support location.
    private static func isTestInstance(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["ARGUS_DISABLE_SESSION_RESTORE"] == "1"
            || environment["ARGUS_UNDER_TEST"] == "1"
    }

    /// Resolves the Session Snapshot location for this process. A caller-
    /// supplied URL takes precedence, including in tests.
    private static func resolvedSessionSnapshotURL(
        suppliedURL: URL?,
        environment: [String: String]
    ) -> URL {
        if let suppliedURL { return suppliedURL }
        guard isTestInstance(environment: environment) else {
            return defaultSessionSnapshotURL
        }

        return
            testSessionSnapshotRootURL
            .appendingPathComponent(
                String(ProcessInfo.processInfo.processIdentifier),
                isDirectory: true
            )
            .appendingPathComponent("session.json")
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
            workspaces: workspaces.map { $0.snapshot() },
            collections: collections.isEmpty ? nil : collections
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

    /// Best-effort synchronous save used by app lifecycle hooks and explicit
    /// Workspace metadata checkpoints.
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
        guard snapshot.isValidForRestore(maxWorkspaces: Self.maxWorkspaces) else { return false }

        let reconciledSnapshot = snapshot.reconciledForRestore()
        let restoredProjects = reconciledSnapshot.projects.map(Project.init(snapshot:))
        let catchAll = restoredProjects.first(where: { $0.isCatchAll }) ?? Project.catchAll()
        let restoredWorkspaces = reconciledSnapshot.workspaces.map(Workspace.init(snapshot:))

        self.catchAllProject = catchAll
        self.projects = restoredProjects
        self.workspaces = restoredWorkspaces
        self.collections = reconciledSnapshot.collections ?? []
        self.selectedWorkspaceId = reconciledSnapshot.selectedWorkspaceId
        notifyWorkspaceContextChanged()
        return true
    }

    // MARK: - Surface Close Handling

    /// Handles a surface-closed notification by removing the corresponding
    /// panel from its workspace.
    private func handleSurfaceClosed(_ surfaceId: UUID, processAlive: Bool?) {
        guard let workspace = workspace(containingPanel: surfaceId) else { return }
        let needsConfirm = processAlive ?? workspace.terminalNeedsConfirmQuit(surfaceId)
        if needsConfirm {
            NotificationCenter.default.post(
                name: .showRunningProcessConfirmation,
                object: RunningProcessCloseRequest(
                    scope: .surface(workspaceId: workspace.id, surfaceId: surfaceId),
                    processCount: 1
                )
            )
            return
        }
        completeSurfaceClose(surfaceId)
    }

    /// Completes a Ghostty-initiated surface close after any running-process
    /// confirmation has already been accepted or is unnecessary.
    func completeSurfaceClose(_ surfaceId: UUID) {
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
        agentStatusRuntime?.removeStatus(workspaceId: workspace.id, surfaceId: surfaceId)
        workspace.closePane(surfaceId)

        if workspace.panelOrder.isEmpty && !settings.keepWorkspaceOpenAfterLastTerminalCloses {
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
        selectWorkspace(workspace.id)
        // Checkpoint Workspace identity and its Workspace Root immediately so
        // an application crash cannot discard a newly created Workspace.
        saveSession()
        return workspace
    }

    /// Removes a workspace by ID, closing all of its panels.
    ///
    /// When the last workspace is removed a fresh Standalone Workspace with
    /// one Terminal Tab is created automatically.
    func removeWorkspace(_ workspaceId: UUID) {
        removeWorkspaceFromState(workspaceId)
    }

    func setTurnCompletionRuntime(_ runtime: TurnCompletionRuntime) {
        turnCompletionRuntime = runtime
    }

    func setAgentStatusRuntime(_ runtime: AgentStatusRuntime) {
        agentStatusRuntime = runtime
    }

    func shouldConfirmWorktreeDeletionBeforeClosing(_ workspaceId: UUID) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }),
            workspace.worktreePath != nil,
            let project = project(for: workspaceId),
            !project.isCatchAll
        else { return false }
        return true
    }

    var totalRunningProcessCount: Int {
        workspaces.reduce(0) { $0 + $1.runningProcessCount }
    }

    /// Sidebar-ordered Workspaces that still have a running process, labeled
    /// with the same Project or directory context used in the titlebar.
    func runningProcessLocations() -> [RunningProcessLocation] {
        sidebarOrderedWorkspaces.compactMap { _, workspace in
            let processCount = workspace.runningProcessCount
            guard processCount > 0 else { return nil }
            return RunningProcessLocation(
                workspaceId: workspace.id,
                label: WorkspaceTitleFormatter.title(
                    workspaceTitle: workspace.displayTitle,
                    contextName: activeWorkspaceContextName(for: workspace)
                ),
                processCount: processCount
            )
        }
    }

    func shouldConfirmRunningProcessBeforeClosingWorkspace(_ workspaceId: UUID) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return false }
        return workspace.runningProcessCount > 0
    }

    func removeWorkspaceFromState(_ workspaceId: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }

        let workspace = workspaces[index]
        let previousOrder = sidebarOrderedWorkspaces.map(\.workspace.id)

        turnCompletionRuntime?.removeAttention(forWorkspace: workspaceId)
        agentStatusRuntime?.removeStatuses(forWorkspace: workspaceId)

        // Close all panels in the workspace before removal.
        for panelId in workspace.panelOrder {
            workspace.closeTab(panelId)
        }

        // Remove from parent project.
        if let project = project(for: workspaceId) {
            project.removeWorkspace(workspaceId)
        }

        workspaces.remove(at: index)

        restoreSelectionAfterRemovingWorkspaces([workspaceId], previousOrder: previousOrder)
    }

    func notifyWorkspaceContextChanged() {
        workspaceContextRevision &+= 1
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

    // swiftlint:disable:next file_length
}
