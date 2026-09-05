import Foundation
import Testing

@testable import Argus

@MainActor
@Suite(.serialized)
struct WorkspaceCommandCreateTests {
    @Test
    func createsAWorktreeWorkspaceWithoutMovingTheSelectedWorkspace() async throws {
        let fixture = try WorkspaceCommandFixture()
        defer { fixture.cleanup() }

        let result = try await Self.created(
            fixture.runtime.receive(.create(fixture.createParameters(project: fixture.project.displayName)))
        )

        #expect(result.projectId == fixture.project.id.uuidString)
        #expect(result.projectName == fixture.project.displayName)
        #expect(result.baseBranch == nil)
        #expect(!result.recordedBaseBranch)
        #expect(result.workspace.kind == .worktree)
        #expect(result.workspace.number == 2)
        #expect(!result.workspace.isSelected)
        #expect(fixture.manager.selectedWorkspaceId == fixture.mainCheckout.id)

        let worktreePath = try #require(result.workspace.worktreePath)
        #expect(worktreePath.hasPrefix(fixture.managedWorktreeRoot.path + "/"))
        let checkedOut = try fixture.gitOutput(
            ["branch", "--show-current"], in: URL(fileURLWithPath: worktreePath))
        #expect(checkedOut == result.branch)
        #expect(fixture.project.containsWorkspace(try #require(UUID(uuidString: result.workspace.id))))
        // Without a base, the branch starts from the repository's current HEAD.
        let head = try fixture.gitOutput(["rev-parse", "main"])
        let branchTip = try fixture.gitOutput(["rev-parse", result.branch])
        #expect(head == branchTip)
    }

    @Test
    func namedBranchAndWorkspaceNameAreUsedAsGiven() async throws {
        let fixture = try WorkspaceCommandFixture()
        defer { fixture.cleanup() }

        let result = try await Self.created(
            fixture.runtime.receive(
                .create(
                    fixture.createParameters(
                        project: fixture.project.id.uuidString,
                        branch: "feature/api",
                        name: "API work"
                    )))
        )

        #expect(result.branch == "feature/api")
        #expect(result.workspace.title == "API work")
        #expect(result.workspace.branch == "feature/api")
    }

    /// The sheet and the Companion CLI must generate the same kind of name:
    /// the Settings prefix plus a two-word suggestion, verified available.
    @Test
    func anOmittedBranchNameIsGeneratedWithTheConfiguredPrefix() async throws {
        let fixture = try WorkspaceCommandFixture()
        defer { fixture.cleanup() }
        fixture.manager.settings.newBranchPrefix = "eshurakov"

        let result = try await Self.created(
            fixture.runtime.receive(.create(fixture.createParameters(project: fixture.project.displayName)))
        )

        #expect(result.branch.hasPrefix("eshurakov/"))
        let words = result.branch.dropFirst("eshurakov/".count).split(separator: "-")
        #expect(words.count == 2)
        #expect(words.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isLowercase) })
        // With no name given, the Workspace title is the branch, as in the sheet.
        #expect(result.workspace.title == result.branch)
        // The generated name was available: the Managed Worktree checked it out.
        let worktreePath = try #require(result.workspace.worktreePath)
        let checkedOut = try fixture.gitOutput(
            ["branch", "--show-current"], in: URL(fileURLWithPath: worktreePath))
        #expect(checkedOut == result.branch)
    }

    @Test
    func stacksOntoTheBaseWorkspaceAndRecordsItsParent() async throws {
        let fixture = try WorkspaceCommandFixture()
        defer { fixture.cleanup() }

        let parent = try await Self.created(
            fixture.runtime.receive(
                .create(fixture.createParameters(project: fixture.project.displayName, branch: "feature/parent")))
        )
        // A commit only on the parent branch proves the child starts from the
        // parent's tip rather than the repository's HEAD.
        try fixture.commit(
            message: "parent work", in: URL(fileURLWithPath: try #require(parent.workspace.worktreePath)))
        let parentTip = try fixture.gitOutput(["rev-parse", "feature/parent"])

        let child = try await Self.created(
            fixture.runtime.receive(
                .create(fixture.createParameters(base: "feature/parent", branch: "feature/child")))
        )

        #expect(child.baseBranch == "feature/parent")
        #expect(child.recordedBaseBranch)
        #expect(child.projectId == fixture.project.id.uuidString)
        #expect(try fixture.gitOutput(["rev-parse", "feature/child"]) == parentTip)
        #expect(try fixture.gitOutput(["config", "--get", "branch.feature/child.base"]) == "feature/parent")

        let snapshot = try fixture.loadRecordedStackSnapshot()
        #expect(snapshot.parents["feature/child"] == "feature/parent")

        let items = fixture.manager.sidebarItems(for: fixture.project)
        let group = try #require(items.compactMap(Self.stack).first)
        #expect(group.rows.map(\.branch) == ["feature/parent", "feature/child"])
        #expect(group.baseBranch == nil)
        #expect(
            group.workspaceIds.map(\.uuidString).sorted()
                == [parent.workspace.id, child.workspace.id].sorted()
        )
    }

    @Test
    func theBaseWorkspaceImpliesTheProjectAndTheContextWorkspaceResolvesADot() async throws {
        let fixture = try WorkspaceCommandFixture()
        defer { fixture.cleanup() }

        let base = try await Self.created(
            fixture.runtime.receive(
                .create(fixture.createParameters(project: fixture.project.displayName, branch: "feature/base")))
        )
        let baseWorkspaceId = try #require(UUID(uuidString: base.workspace.id))

        let stacked = try await Self.created(
            fixture.runtime.receive(
                .create(
                    fixture.createParameters(
                        base: WorkspaceCommandRuntime.contextReference,
                        branch: "feature/stacked",
                        contextWorkspaceId: baseWorkspaceId
                    )))
        )

        #expect(stacked.baseBranch == "feature/base")
        #expect(stacked.projectId == fixture.project.id.uuidString)
    }

    @Test
    func theWorkingDirectoryImpliesTheProjectWhenNoReferenceIsGiven() async throws {
        let fixture = try WorkspaceCommandFixture()
        defer { fixture.cleanup() }

        let result = try await Self.created(
            fixture.runtime.receive(
                .create(
                    fixture.createParameters(
                        branch: "feature/from-cwd",
                        contextDirectory: fixture.repository.appendingPathComponent("nested").path
                    )))
        )

        #expect(result.projectId == fixture.project.id.uuidString)
        #expect(result.branch == "feature/from-cwd")
    }

    static func created(_ outcome: WorkspaceCommandOutcome) throws -> WorkspaceCreateResult {
        if case .rejected(let code, let message) = outcome {
            Issue.record("Workspace creation was rejected: \(code.rawValue) \(message)")
        }
        guard case .created(let result) = outcome else {
            throw WorkspaceCommandTestFailure.unexpectedOutcome
        }
        return result
    }

    private static func stack(_ item: WorkspaceSidebarItem) -> WorkspaceStackGroup? {
        guard case .stack(let group) = item else { return nil }
        return group
    }
}

enum WorkspaceCommandTestFailure: Error {
    case unexpectedOutcome
}
