import Foundation
import Testing

@testable import Argus

@Suite
struct ExistingWorktreeBranchChoiceTests {
    @Test
    func existingExternalWorktreeBranchesRemainSelectable() async throws {
        let temporaryDirectory = try TestTemporaryDirectory(prefix: "argus-existing-worktree-choice")
        let temp = temporaryDirectory.url
        let repo = temp.appendingPathComponent("repo", isDirectory: true)
        let existingWorktree = temp.appendingPathComponent("existing-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { temporaryDirectory.remove() }

        try run("git", ["init", "-b", "main", "."], cwd: repo.path)
        try run("git", ["config", "user.email", "test@example.com"], cwd: repo.path)
        try run("git", ["config", "user.name", "Test User"], cwd: repo.path)
        try "hello".write(
            to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try run("git", ["add", "README.md"], cwd: repo.path)
        try run("git", ["commit", "-m", "initial"], cwd: repo.path)
        try run("git", ["branch", "external-worktree"], cwd: repo.path)
        try run("git", ["worktree", "add", existingWorktree.path, "external-worktree"], cwd: repo.path)

        let service = WorktreeService()
        let availableForNewWorktree = try await service.listAvailableBranches(repositoryPath: repo.path)
        assertFalse(
            availableForNewWorktree.contains("external-worktree"),
            "checked-out worktree branch remains unavailable for creating another worktree")

        let pickerChoices = try await service.listWorkspaceBranchChoices(repositoryPath: repo.path)
        assertTrue(
            pickerChoices.contains("external-worktree"),
            "workspace branch picker includes local branches checked out in external worktrees")

        let resolvedPath = try await service.createWorktree(
            projectId: UUID(),
            repositoryPath: repo.path,
            branchName: "external-worktree",
            createNewBranch: false
        )
        assertEqual(
            URL(fileURLWithPath: resolvedPath).resolvingSymlinksInPath().path,
            existingWorktree.resolvingSymlinksInPath().path,
            "selecting a checked-out worktree branch reuses the existing worktree path"
        )
    }

    private func run(_ executable: String, _ args: [String], cwd: String) throws {
        _ = try TestGit.run(executable, args, cwd: cwd)
    }

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }

    private func assertTrue(_ condition: Bool, _ message: String) {
        #expect(condition, Comment(rawValue: message))
    }

    private func assertFalse(_ condition: Bool, _ message: String) {
        assertTrue(!condition, message)
    }
}
