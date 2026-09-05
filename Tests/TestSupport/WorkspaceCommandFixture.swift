import Foundation
import Testing

@testable import Argus

/// A real Git repository, a Named Project pointing at it, and a Workspace
/// Command runtime bound to an isolated `WorkspaceManager`.
///
/// Workspace creation spawns real `git` processes, so these tests use a real
/// repository rather than a double.
@MainActor
final class WorkspaceCommandFixture {
    let temporary: TestTemporaryDirectory
    let repository: URL
    let managedWorktreeRoot: URL
    let defaultsName: String
    let defaults: UserDefaults
    let manager: WorkspaceManager
    let project: Project
    let mainCheckout: Workspace
    let runtime: WorkspaceCommandRuntime

    init() throws {
        temporary = try TestTemporaryDirectory(prefix: "argus-workspace-command")
        let root = temporary.url.resolvingSymlinksInPath()
        repository = root.appendingPathComponent("repository", isDirectory: true)
        managedWorktreeRoot = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try TestGit.run(["init", "-b", "main", "."], in: repository)
        try TestGit.run(["config", "user.name", "Test User"], in: repository)
        try TestGit.run(["config", "user.email", "test@example.com"], in: repository)
        try Self.commit(message: "initial", in: repository)

        defaultsName = "ArgusTests.WorkspaceCommands.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        manager = WorkspaceManager(
            settings: AppSettings(defaults: defaults),
            sessionSnapshotURL: root.appendingPathComponent("session.json"),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"],
            worktreeService: WorktreeService(worktreeBaseURL: managedWorktreeRoot)
        )
        project = Project(repositoryPath: repository.path, mainBranch: "main")
        mainCheckout = Self.workspace(
            project: project, branch: "main", path: repository.path, type: .mainCheckout)
        manager.catchAllProject.workspaceIds = []
        manager.workspaces = [mainCheckout]
        project.workspaceIds = [mainCheckout.id]
        manager.projects.insert(project, at: 0)
        manager.selectedWorkspaceId = mainCheckout.id
        runtime = WorkspaceCommandRuntime(workspaceManager: manager)
    }

    func cleanup() {
        manager.stopWorkspaceStackObservations()
        defaults.removePersistentDomain(forName: defaultsName)
        temporary.remove()
    }

    /// Reads the repository's recorded branch parents the same way Stack
    /// discovery does, then installs the result as this Project's snapshot.
    @discardableResult
    func loadRecordedStackSnapshot() throws -> WorkspaceStackSnapshot {
        let snapshot = try RecordedBaseBranchReader(
            environment: GitCommandEnvironment.standard.merging([
                "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": "0"
            ]) { _, new in new }
        ).read(repositoryPath: repository.path)
        manager.workspaceStackSnapshots[project.id] = snapshot
        return snapshot
    }

    func createParameters(
        project projectReference: String? = nil,
        base: String? = nil,
        branch: String? = nil,
        name: String? = nil,
        contextWorkspaceId: UUID? = nil,
        contextDirectory: String? = nil
    ) -> WorkspaceCreateParameters {
        WorkspaceCreateParameters(
            project: projectReference,
            base: base,
            branch: branch,
            name: name,
            contextWorkspaceId: contextWorkspaceId?.uuidString,
            contextDirectory: contextDirectory
        )
    }

    func standaloneWorkspace(title: String) -> Workspace {
        let workspace = Self.workspace(
            project: manager.catchAllProject,
            branch: nil,
            path: temporary.url.appendingPathComponent(title).path,
            type: .external
        )
        workspace.customTitle = title
        manager.workspaces.append(workspace)
        manager.catchAllProject.addWorkspace(workspace.id)
        return workspace
    }

    func workspace(branch: String) -> Workspace? {
        manager.workspaces.first { $0.branchName == branch }
    }

    func gitOutput(_ arguments: [String], in directory: URL? = nil) throws -> String {
        try TestGit.run(arguments, in: directory ?? repository)
    }

    /// Adds a commit to a branch's worktree so a stacked branch can be shown
    /// to start from that branch's tip rather than the repository's `HEAD`.
    func commit(message: String, in directory: URL) throws {
        try Self.commit(message: message, in: directory)
    }

    private static func commit(message: String, in directory: URL) throws {
        try TestGit.run(
            [
                "-c", "user.name=Test User", "-c", "user.email=test@example.com",
                "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                "commit", "--allow-empty", "-m", message
            ], in: directory)
    }

    private static func workspace(
        project: Project,
        branch: String?,
        path: String,
        type: WorkspaceType
    ) -> Workspace {
        Workspace(
            snapshot: WorkspaceSnapshot(
                id: UUID(), projectId: project.id, branchName: branch, workspaceType: type,
                worktreePath: type == .worktree ? path : nil, title: branch ?? "Terminal",
                customTitle: nil, currentDirectory: path, panelCount: 0
            ))
    }
}
