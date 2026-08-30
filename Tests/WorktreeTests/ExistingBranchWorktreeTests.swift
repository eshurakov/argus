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

    @Test
    func forcedRemovalRejectsUnregisteredPathsAndTheMainCheckout() async throws {
        let temporaryDirectory = try TestTemporaryDirectory(prefix: "argus-removal-authority")
        let temp = temporaryDirectory.url
        let repo = temp.appendingPathComponent("repo", isDirectory: true)
        let unrelated = temp.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer { temporaryDirectory.remove() }
        try run("git", ["init", "-b", "main", "."], cwd: repo.path)
        try "keep".write(
            to: unrelated.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)

        let service = WorktreeService(
            worktreeBaseURL: temp.appendingPathComponent("managed-worktrees", isDirectory: true))

        await #expect(throws: WorktreeError.self) {
            try await service.removeWorktree(
                repositoryPath: repo.path,
                worktreePath: unrelated.path,
                force: true
            )
        }
        await #expect(throws: WorktreeError.self) {
            try await service.removeWorktree(
                repositoryPath: repo.path,
                worktreePath: repo.path,
                force: true
            )
        }
        assertTrue(
            FileManager.default.fileExists(atPath: unrelated.appendingPathComponent("keep.txt").path),
            "unauthorized directories remain intact"
        )
        assertTrue(FileManager.default.fileExists(atPath: repo.path), "main checkout remains intact")
    }

    /// A removal that was interrupted after Git deleted the worktree's `.git`
    /// link leaves a directory that `git worktree remove` permanently refuses.
    /// Deleting the Worktree Workspace must still succeed, and the branch must
    /// become reusable, otherwise the user is stuck with an undeletable
    /// Workspace and an unusable branch name.
    @Test
    func forcedRemovalRecoversAWorktreeGitCanNoLongerRemove() async throws {
        let temporaryDirectory = try TestTemporaryDirectory(prefix: "argus-interrupted-removal")
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
        let projectId = UUID()
        let worktreePath = try await service.createWorktree(
            projectId: projectId,
            repositoryPath: repo.path,
            branchName: "interrupted"
        )

        // Reproduce the state an interrupted removal leaves behind: Git has
        // already unlinked the worktree's `.git` file, but the files and the
        // registration remain.
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: worktreePath).appendingPathComponent(".git"))
        try "unsaved".write(
            to: URL(fileURLWithPath: worktreePath).appendingPathComponent("scratch.txt"),
            atomically: true,
            encoding: .utf8
        )

        try await service.removeWorktree(
            repositoryPath: repo.path,
            worktreePath: worktreePath,
            force: true
        )

        assertFalse(
            FileManager.default.fileExists(atPath: worktreePath),
            "forced removal deletes a worktree git can no longer remove"
        )
        let registeredWorktrees = try capture(
            "git", ["worktree", "list", "--porcelain"], cwd: repo.path)
        assertFalse(
            registeredWorktrees.contains(worktreePath),
            "forced removal prunes the stale registration"
        )
        // The branch is only genuinely reusable if the registration is gone.
        _ = try await service.createWorktree(
            projectId: projectId,
            repositoryPath: repo.path,
            branchName: "interrupted",
            createNewBranch: false
        )
    }

    /// Recovery is limited to forced removal. An ordinary removal must keep
    /// refusing a dirty worktree so uncommitted work is never discarded.
    @Test
    func unforcedRemovalPreservesADirtyWorktree() async throws {
        let temporaryDirectory = try TestTemporaryDirectory(prefix: "argus-unforced-removal")
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
            branchName: "keep-me"
        )
        let uncommittedFile = URL(fileURLWithPath: worktreePath)
            .appendingPathComponent("uncommitted.txt")
        try "unsaved work".write(to: uncommittedFile, atomically: true, encoding: .utf8)

        await #expect(throws: WorktreeError.self) {
            try await service.removeWorktree(
                repositoryPath: repo.path,
                worktreePath: worktreePath
            )
        }

        assertTrue(
            FileManager.default.fileExists(atPath: uncommittedFile.path),
            "unforced removal leaves uncommitted work in place"
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
