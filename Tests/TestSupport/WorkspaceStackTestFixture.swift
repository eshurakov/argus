import Foundation
import Testing

@testable import Argus

enum WorkspaceStackRevealInterruption: CaseIterable, Sendable {
    case selection
    case stackDisclosure
    case projectDisclosure
    case collapsedProject
}

@MainActor
final class WorkspaceStackTestFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("argus-stack-tests-\(UUID().uuidString)", isDirectory: true)
        .resolvingSymlinksInPath()
    let defaultsName = "ArgusTests.WorkspaceStacks.\(UUID().uuidString)"
    let defaults: UserDefaults
    let manager: WorkspaceManager
    let project: Project
    let parent: Workspace
    let child: Workspace
    let ordinary: Workspace
    let snapshot: WorkspaceStackSnapshot
    let stackId = "gh-stack:4:main:14:feature/parent"

    var orderedIds: [UUID] { manager.sidebarOrderedWorkspaces.map(\.workspace.id) }

    var snapshotIncludingGap: WorkspaceStackSnapshot {
        WorkspaceStackSnapshot(
            gitCommonDirectory: snapshot.gitCommonDirectory,
            worktrees: snapshot.worktrees + [
                WorkspaceStackWorktree(path: root.appendingPathComponent("gap").path, branch: "feature/gap")
            ],
            parents: snapshot.parents
        )
    }

    func adoptGapWorkspace() throws -> Workspace {
        project.isExpanded = false
        project.collapsedStackIds = [stackId]
        return try #require(
            manager.adoptOrphanedWorktree(
                OrphanedWorktreeInfo(
                    path: root.appendingPathComponent("gap").path,
                    branchName: "outdated-branch-label", projectId: project.id
                )
            ))
    }

    init(reader: any WorkspaceStackReading = WorkspaceStackService()) throws {
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        manager = WorkspaceManager(
            settings: AppSettings(defaults: defaults),
            sessionSnapshotURL: root.appendingPathComponent("session.json"),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"],
            workspaceStackReader: reader
        )
        project = Project(repositoryPath: root.appendingPathComponent("repository").path, mainBranch: "main")
        parent = Self.workspace(
            project: project, branch: "stored-parent", path: project.repositoryPath, type: .mainCheckout)
        child = Self.workspace(
            project: project, branch: "stored-child", path: root.appendingPathComponent("child").path)
        ordinary = Self.workspace(
            project: project, branch: "unrelated", path: root.appendingPathComponent("ordinary").path)
        snapshot = WorkspaceStackSnapshot(
            gitCommonDirectory: root.appendingPathComponent("common.git").path,
            worktrees: [
                WorkspaceStackWorktree(path: project.repositoryPath, branch: "feature/parent"),
                WorkspaceStackWorktree(path: child.currentDirectory, branch: "feature/child"),
                WorkspaceStackWorktree(path: ordinary.currentDirectory, branch: "unrelated")
            ],
            parents: ["feature/parent": "main", "feature/gap": "feature/parent", "feature/child": "feature/gap"]
        )
        manager.catchAllProject.workspaceIds = []
        manager.workspaces = [child, ordinary, parent]
        project.workspaceIds = manager.workspaces.map(\.id)
        manager.projects.insert(project, at: 0)
        manager.selectedWorkspaceId = child.id
        manager.workspaceStackSnapshots[project.id] = snapshot
    }

    func makeWorkspace(branch: String) -> Workspace {
        Self.workspace(project: project, branch: branch, path: root.appendingPathComponent(branch).path)
    }

    func cleanup() {
        manager.stopWorkspaceStackObservations()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }

    private static func workspace(
        project: Project,
        branch: String,
        path: String,
        type: WorkspaceType = .worktree
    ) -> Workspace {
        Workspace(
            snapshot: WorkspaceSnapshot(
                id: UUID(), projectId: project.id, branchName: branch, workspaceType: type,
                worktreePath: type == .worktree ? path : nil, title: branch, customTitle: nil,
                currentDirectory: path, panelCount: 0
            ))
    }
}
