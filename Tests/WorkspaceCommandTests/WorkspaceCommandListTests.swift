import Foundation
import Testing

@testable import Argus

@MainActor
@Suite
struct WorkspaceCommandListTests {
    @Test
    func listProjectsWorkspaceNumbersAndStackGroups() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let result = WorkspaceCommandRuntime(workspaceManager: fixture.manager).listResult()

        #expect(result.selectedWorkspaceId == fixture.child.id.uuidString)
        #expect(result.projects.map(\.isCatchAll) == [false, true])

        let project = try #require(result.projects.first)
        #expect(project.id == fixture.project.id.uuidString)
        #expect(project.name == fixture.project.displayName)
        #expect(project.mainBranch == "main")
        #expect(project.repositoryPath == fixture.project.repositoryPath)
        #expect(project.items.count == 2)

        let group = try #require(project.items.first.flatMap(Self.stack))
        #expect(group.id == fixture.stackId)
        #expect(group.baseBranch == "main")
        #expect(group.rows.map(\.branch) == ["feature/parent", "feature/gap", "feature/child"])
        #expect(group.rows.map(\.parentBranch) == ["main", "feature/parent", "feature/gap"])
        #expect(group.rows.map { $0.workspace?.number } == [1, nil, 2])
        #expect(group.rows.first?.workspace?.kind == .mainCheckout)
        #expect(group.rows.first?.workspace?.isSelected == false)
        #expect(group.rows.last?.workspace?.isSelected == true)
        #expect(group.rows.last?.workspace?.id == fixture.child.id.uuidString)

        let ordinary = try #require(project.items.last.flatMap(Self.workspace))
        #expect(ordinary.number == 3)
        #expect(ordinary.kind == .worktree)
        #expect(ordinary.branch == "unrelated")
        #expect(ordinary.worktreePath == fixture.ordinary.currentDirectory)
    }

    @Test
    func standaloneWorkspacesAndStackDiagnosticsAreReported() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let standalone = try #require(fixture.manager.addWorkspace(title: "notes"))
        fixture.manager.workspaceStackErrors[fixture.project.id] = "Conflicting recorded parents"
        let result = WorkspaceCommandRuntime(workspaceManager: fixture.manager).listResult()

        #expect(result.projects.first?.stackDiagnostic == "Conflicting recorded parents")
        let catchAll = try #require(result.projects.last)
        #expect(catchAll.isCatchAll)
        #expect(catchAll.repositoryPath == nil)
        #expect(catchAll.mainBranch == nil)
        let entry = try #require(catchAll.items.first.flatMap(Self.workspace))
        #expect(entry.id == standalone.id.uuidString)
        #expect(entry.kind == .standalone)
        #expect(entry.branch == nil)
        #expect(entry.worktreePath == nil)
        #expect(entry.root == standalone.currentDirectory)
        #expect(entry.isSelected)
        #expect(entry.number == 4)
    }

    private static func stack(_ item: WorkspaceListItem) -> StackGroupListEntry? {
        guard case .stack(let group) = item else { return nil }
        return group
    }

    private static func workspace(_ item: WorkspaceListItem) -> WorkspaceListEntry? {
        guard case .workspace(let entry) = item else { return nil }
        return entry
    }
}
