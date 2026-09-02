import Combine
import Foundation

struct WorkspacePullRequestTarget: Hashable, Sendable {
    let workspaceID: UUID
    let projectID: UUID
    let repositoryPath: String
    let worktreePath: String

    init(workspaceID: UUID, projectID: UUID, repositoryPath: String, worktreePath: String) {
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.repositoryPath = Self.normalizedPath(repositoryPath)
        self.worktreePath = Self.normalizedPath(worktreePath)
    }

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }
}

struct WorkspacePullRequestState: Equatable, Sendable {
    var status: PullRequestStatus?
    var branchName: String?
    var isRefreshing = false
    var lastSuccess: Date?
    var error: PullRequestStatusError?
    var hasLoaded = false

    func isStale(at date: Date) -> Bool {
        guard status != nil else { return false }
        return error != nil || lastSuccess.map { date.timeIntervalSince($0) > 660 } ?? true
    }
}

@MainActor
final class WorkspacePullRequestStatusModel: ObservableObject {
    @Published private(set) var states: [UUID: WorkspacePullRequestState] = [:]

    let provider: any PullRequestStatusProviding
    let localInputs: any WorkspacePullRequestLocalInputProviding
    let now: @MainActor () -> Date
    let automaticallySchedules: Bool
    let hostBudgets: PullRequestStatusHostBudgetStore
    var entries: [UUID: Entry] = [:]
    var projects: [UUID: ProjectRuntime] = [:]
    var targetOrder: [UUID] = []
    var pending: [UUID: RequestKind] = [:]
    var prepared: [UUID: Request] = [:]
    var running: [UUID: RunningRequest] = [:]
    var batches: [String: RunningBatch] = [:]
    var providerTasks: [UUID: Task<Void, Never>] = [:]
    var localTasks: [UUID: Task<Void, Never>] = [:]
    var schedulerTask: Task<Void, Never>?
    var selectedWorkspaceID: UUID?
    var isEnabled = false
    var isActive = false
    var providerIsAvailable = false
    var missingCLIUntil: Date?

    init(
        provider: any PullRequestStatusProviding = GitHubPullRequestService(),
        localInputs: any WorkspacePullRequestLocalInputProviding = WorktreePullRequestLocalInputProvider(),
        now: @escaping @MainActor () -> Date = Date.init,
        automaticallySchedules: Bool = true,
        hostBudgets: PullRequestStatusHostBudgetStore = .shared
    ) {
        self.provider = provider
        self.localInputs = localInputs
        self.now = now
        self.automaticallySchedules = automaticallySchedules
        self.hostBudgets = hostBudgets
    }

    deinit {
        schedulerTask?.cancel()
        for task in providerTasks.values { task.cancel() }
        for task in localTasks.values { task.cancel() }
    }

    func state(for workspaceID: UUID) -> WorkspacePullRequestState? {
        states[workspaceID]
    }

    func update(
        targets: [WorkspacePullRequestTarget],
        selectedWorkspaceID: UUID?,
        isEnabled: Bool,
        isActive: Bool
    ) {
        let wasRunning = self.isEnabled && self.isActive
        let selectionChanged = self.selectedWorkspaceID != selectedWorkspaceID
        self.isEnabled = isEnabled
        self.isActive = isActive
        self.selectedWorkspaceID = selectedWorkspaceID
        guard isEnabled else {
            clear()
            return
        }
        reconcile(targets)
        if entries.isEmpty {
            schedulerTask?.cancel()
            schedulerTask = nil
        }
        guard isActive else {
            suspend()
            return
        }
        if !wasRunning {
            for project in projects.values { invalidateRepository(project) }
            for id in targetOrder { enqueue(id, kind: .observe) }
        } else if selectionChanged, let selectedWorkspaceID {
            enqueue(selectedWorkspaceID, kind: .selection)
        }
        runDueWork()
        startScheduler()
    }

    func refresh(workspaceID: UUID) {
        guard isEnabled, isActive, let entry = entries[workspaceID],
            let project = projects[entry.target.projectID],
            pending[workspaceID] != .manual,
            prepared[workspaceID]?.kind != .manual,
            running[workspaceID].map({ !$0.invalidated && $0.request.kind == .manual }) != true
        else { return }
        guard hostPause(project) == nil else {
            publishBlocked(workspaceID, project: project)
            return
        }
        invalidateRepository(project)
        invalidateRequest(workspaceID)
        enqueue(workspaceID, kind: .manual)
        drainQueue()
    }

    func refreshProject(projectID: UUID) {
        guard isEnabled, isActive else { return }
        for id in targetOrder where entries[id]?.target.projectID == projectID {
            enqueue(id, kind: .selection)
        }
        drainQueue()
    }

    func stop() {
        isEnabled = false
        isActive = false
        clear()
    }

    func tick() async {
        runDueWork()
        await waitForIdle()
    }

    func waitForIdle() async {
        while true {
            let tasks = Array(localTasks.values) + Array(providerTasks.values)
            guard !tasks.isEmpty else { return }
            for task in tasks { await task.value }
        }
    }

    func publish(_ state: WorkspacePullRequestState, for workspaceID: UUID) {
        guard entries[workspaceID] != nil, states[workspaceID] != state else { return }
        states[workspaceID] = state
    }

    private func reconcile(_ targets: [WorkspacePullRequestTarget]) {
        var inventory: [UUID: WorkspacePullRequestTarget] = [:]
        for target in targets { inventory[target.workspaceID] = target }
        for (id, entry) in entries where inventory[id] != entry.target {
            invalidateRequest(id)
            entries[id] = nil
            states[id] = nil
            pending[id] = nil
            prepared[id] = nil
        }
        let projectPaths = Dictionary(
            targets.map { ($0.projectID, $0.repositoryPath) }, uniquingKeysWith: { first, _ in first })
        for (id, project) in projects where projectPaths[id] != project.repositoryPath {
            project.resolutionTask?.cancel()
            if let localID = project.localReadID { localTasks[localID]?.cancel() }
            projects[id] = nil
        }
        for target in targets {
            if projects[target.projectID] == nil {
                projects[target.projectID] = ProjectRuntime(repositoryPath: target.repositoryPath)
            }
            if entries[target.workspaceID] == nil {
                entries[target.workspaceID] = Entry(target: target)
                states[target.workspaceID] = WorkspacePullRequestState()
                enqueue(target.workspaceID, kind: .discover)
            }
        }
        var seen = Set<UUID>()
        targetOrder = targets.map(\.workspaceID).filter { seen.insert($0).inserted }
    }

    private func clear() {
        suspend()
        entries.removeAll()
        projects.removeAll()
        targetOrder.removeAll()
        states.removeAll()
        missingCLIUntil = nil
        providerIsAvailable = false
    }

    private func suspend() {
        schedulerTask?.cancel()
        schedulerTask = nil
        pending.removeAll()
        prepared.removeAll()
        for task in localTasks.values { task.cancel() }
        for project in projects.values {
            project.localReadID = nil
            invalidateRepository(project)
        }
        for (id, request) in running {
            request.invalidated = true
            request.task?.cancel()
            if request.task == nil && request.batchID == nil { running[id] = nil }
        }
        for task in providerTasks.values { task.cancel() }
        for id in states.keys { states[id]?.isRefreshing = false }
    }

    private func startScheduler() {
        guard automaticallySchedules, schedulerTask == nil, !entries.isEmpty else { return }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.runDueWork()
            }
        }
    }
}
