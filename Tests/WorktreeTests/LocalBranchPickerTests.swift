import Foundation
import Testing

@testable import Argus

@Suite
struct LocalBranchPickerTests {
    @Test
    func localBranchesCheckedOutElsewhereAreUnavailable() async throws {
        let temporaryDirectory = try TestTemporaryDirectory(prefix: "argus-local-branch-picker")
        let temp = temporaryDirectory.url
        let repo = temp.appendingPathComponent("repo", isDirectory: true)
        let checkedOutWorktree = temp.appendingPathComponent("checked-out-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { temporaryDirectory.remove() }

        try run("git", ["init", "-b", "main", "."], cwd: repo.path)
        try run("git", ["config", "user.email", "test@example.com"], cwd: repo.path)
        try run("git", ["config", "user.name", "Test User"], cwd: repo.path)
        try "hello".write(
            to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try run("git", ["add", "README.md"], cwd: repo.path)
        try run("git", ["commit", "-m", "initial"], cwd: repo.path)
        try run("git", ["branch", "local-only"], cwd: repo.path)
        try run("git", ["branch", "checked-out-local"], cwd: repo.path)
        try run(
            "git", ["worktree", "add", checkedOutWorktree.path, "checked-out-local"], cwd: repo.path)

        let service = WorktreeService()
        let available = try await service.listAvailableBranches(repositoryPath: repo.path)

        assertTrue(
            available.contains("local-only"),
            "local branch that is not checked out in another worktree is available")
        assertFalse(
            available.contains("checked-out-local"),
            "local branch checked out in another worktree remains unavailable")
    }

    private func run(_ executable: String, _ args: [String], cwd: String) throws {
        _ = try TestGit.run(executable, args, cwd: cwd)
    }

    private func assertTrue(_ condition: Bool, _ message: String) {
        #expect(condition, Comment(rawValue: message))
    }

    private func assertFalse(_ condition: Bool, _ message: String) {
        assertTrue(!condition, message)
    }
}
