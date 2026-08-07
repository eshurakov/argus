import Foundation
import Testing

@testable import Argus

@Suite
struct ExistingBranchWorktreeTests {
    @Test
    func existingRemoteBranchesCreateWorktreesAndForcedRemovalCleansUp() async throws {
        let temporaryDirectory = try TestTemporaryDirectory(prefix: "argus-existing-branch")
        let temp = temporaryDirectory.url
        let repo = temp.appendingPathComponent("repo", isDirectory: true)
        let origin = temp.appendingPathComponent("origin.git", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { temporaryDirectory.remove() }

        try run("git", ["init", "--bare", origin.path], cwd: temp.path)
        try run("git", ["init", "-b", "main", "."], cwd: repo.path)
        try run("git", ["config", "user.email", "test@example.com"], cwd: repo.path)
        try run("git", ["config", "user.name", "Test User"], cwd: repo.path)
        try "hello".write(
            to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try run("git", ["add", "README.md"], cwd: repo.path)
        try run("git", ["commit", "-m", "initial"], cwd: repo.path)
        try run("git", ["checkout", "-b", "remote-only"], cwd: repo.path)
        try "remote".write(
            to: repo.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
        try run("git", ["add", "remote.txt"], cwd: repo.path)
        try run("git", ["commit", "-m", "remote branch"], cwd: repo.path)
        try run("git", ["checkout", "main"], cwd: repo.path)
        try run("git", ["remote", "add", "origin", origin.path], cwd: repo.path)
        try run("git", ["push", "-u", "origin", "main", "remote-only"], cwd: repo.path)
        try run("git", ["branch", "-D", "remote-only"], cwd: repo.path)
        try run("git", ["fetch", "origin"], cwd: repo.path)

        let service = WorktreeService(
            worktreeBaseURL: temp.appendingPathComponent("managed-worktrees", isDirectory: true))
        let available = try await service.listAvailableBranches(repositoryPath: repo.path)
        assertFalse(available.contains("origin/main"), "remote branch for checked-out main is excluded")
        assertTrue(
            available.contains("origin/remote-only"),
            "remote-only branch remains available with remote label")

        let projectId = UUID()
        let worktreePath = try await service.createWorktree(
            projectId: projectId,
            repositoryPath: repo.path,
            branchName: "origin/remote-only",
            createNewBranch: false
        )

        let checkedOutBranch = try capture("git", ["branch", "--show-current"], cwd: worktreePath)
        assertEqual(
            checkedOutBranch, "remote-only",
            "remote-only worktree is on a local tracking branch, not detached")
        try await service.removeWorktree(repositoryPath: repo.path, worktreePath: worktreePath)
    }

    @Test
    func forcedRemovalDeletesDirtyWorktreeAndRegistration() async throws {
        let temporaryDirectory = try TestTemporaryDirectory(prefix: "argus-remove-worktree")
        let temp = temporaryDirectory.url
        let repo = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { temporaryDirectory.remove() }

        try run("git", ["init", "-b", "main", "."], cwd: repo.path)
        try run("git", ["config", "user.email", "test@example.com"], cwd: repo.path)
        try run("git", ["config", "user.name", "Test User"], cwd: repo.path)
        try "initial".write(
            to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try run("git", ["add", "README.md"], cwd: repo.path)
        try run("git", ["commit", "-m", "initial"], cwd: repo.path)

        let service = WorktreeService(
            worktreeBaseURL: temp.appendingPathComponent("managed-worktrees", isDirectory: true))
        let worktreePath = try await service.createWorktree(
            projectId: UUID(),
            repositoryPath: repo.path,
            branchName: "delete-me"
        )
        try "dirty".write(
            to: URL(fileURLWithPath: worktreePath).appendingPathComponent("dirty.txt"),
            atomically: true,
            encoding: .utf8
        )
        try run("git", ["worktree", "lock", worktreePath], cwd: repo.path)

        try await service.removeWorktree(
            repositoryPath: repo.path,
            worktreePath: worktreePath,
            force: true
        )

        assertFalse(
            FileManager.default.fileExists(atPath: worktreePath),
            "forced removal deletes dirty, locked worktree directory"
        )
        let registeredWorktrees = try capture(
            "git", ["worktree", "list", "--porcelain"], cwd: repo.path)
        assertFalse(
            registeredWorktrees.contains(worktreePath),
            "forced removal deletes git worktree registration"
        )
    }

    private func run(_ executable: String, _ args: [String], cwd: String) throws {
        _ = try capture(executable, args, cwd: cwd)
    }

    private func capture(_ executable: String, _ args: [String], cwd: String) throws -> String {
        try TestGit.run(executable, args, cwd: cwd)
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
