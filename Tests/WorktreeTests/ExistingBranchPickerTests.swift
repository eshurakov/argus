import Foundation
import Testing

@testable import Argus

@Suite
struct ExistingBranchPickerTests {
    @Test(.timeLimit(.minutes(1)))
    func returnsWhenParentExitsEvenIfADescendantKeepsPipesOpen() async throws {
        let service = WorktreeService(gitCommandTimeout: 2)
        let start = Date()

        let output = try await service.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "printf ready; sleep 1 &"],
            commandDescription: "pipe-holding fixture"
        )

        #expect(output == "ready")
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    @Test(.timeLimit(.minutes(1)))
    func timesOutWhileTheLaunchedProcessIsStillRunning() async throws {
        let service = WorktreeService(gitCommandTimeout: 0.2)
        let start = Date()

        do {
            _ = try await service.runProcess(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                args: ["2"],
                commandDescription: "long-running fixture"
            )
            Issue.record("long-running subprocess should time out")
        } catch let error as WorktreeError {
            guard case .gitCommandTimedOut = error else {
                Issue.record("unexpected timeout error: \(error)")
                return
            }
        }

        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func largeBranchListDoesNotBlockOnAFullOutputPipe() async throws {
        let temporaryDirectory = try TestTemporaryDirectory(prefix: "argus-large-branch-picker")
        let temp = temporaryDirectory.url
        let repo = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { temporaryDirectory.remove() }

        try run("git", ["init", "-b", "main", "."], cwd: repo.path)
        try run("git", ["config", "user.email", "test@example.com"], cwd: repo.path)
        try run("git", ["config", "user.name", "Test User"], cwd: repo.path)
        try "fixture".write(
            to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try run("git", ["add", "README.md"], cwd: repo.path)
        try run("git", ["commit", "-m", "initial"], cwd: repo.path)

        let head = try capture("git", ["rev-parse", "HEAD"], cwd: repo.path)
        let refsDirectory = repo.appendingPathComponent(".git/refs/heads", isDirectory: true)
        let branchPrefix = "branch-\(String(repeating: "x", count: 100))-"
        for index in 0..<700 {
            try "\(head)\n".write(
                to: refsDirectory.appendingPathComponent("\(branchPrefix)\(index)"),
                atomically: false,
                encoding: .utf8
            )
        }

        let available = try await WorktreeService().listWorkspaceBranchChoices(repositoryPath: repo.path)

        assertTrue(available.count == 700, "all available branches are returned")
        assertTrue(available.contains("\(branchPrefix)699"), "last generated branch is returned")
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentCompletedProcessesDoNotStarveOutputReaders() async throws {
        let service = WorktreeService(gitCommandTimeout: 5)
        let processCount = 8

        let outputs = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<processCount {
                group.addTask {
                    try await service.runProcess(
                        executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                        args: [],
                        commandDescription: "completed fixture \(index)"
                    )
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(outputs.count == processCount)
        #expect(outputs.allSatisfy { $0.isEmpty })
    }

    @Test
    func unfetchedRemoteBranchesCanBeSelectedAndOpenedInAWorktree() async throws {
        let temporaryDirectory = try TestTemporaryDirectory(prefix: "argus-existing-picker")
        let temp = temporaryDirectory.url
        let origin = temp.appendingPathComponent("origin.git", isDirectory: true)
        let seed = temp.appendingPathComponent("seed", isDirectory: true)
        let repo = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { temporaryDirectory.remove() }

        try createRemoteFixture(origin: origin, seed: seed, temp: temp)

        try run(
            "git", ["clone", "--single-branch", "--branch", "main", origin.path, repo.path],
            cwd: temp.path)
        try run("git", ["config", "user.email", "test@example.com"], cwd: repo.path)
        try run("git", ["config", "user.name", "Test User"], cwd: repo.path)

        let localBranches = try capture(
            "git", ["branch", "--all", "--format=%(refname:short)"], cwd: repo.path)
        assertFalse(
            localBranches.contains("origin/feature/unfetched"),
            "test branch starts as an unfetched remote branch")

        let service = WorktreeService(
            worktreeBaseURL: temp.appendingPathComponent("managed-worktrees", isDirectory: true))
        let available = try await service.listAvailableBranches(repositoryPath: repo.path)
        assertTrue(
            available.contains("origin/feature/unfetched"),
            "available branches include remote heads not present in local remote-tracking refs")
        assertFalse(available.contains("origin/main"), "checked-out main remains unavailable")

        let worktreePath = try await service.createWorktree(
            projectId: UUID(),
            repositoryPath: repo.path,
            branchName: "origin/feature/unfetched",
            createNewBranch: false
        )
        let checkedOutBranch = try capture("git", ["branch", "--show-current"], cwd: worktreePath)
        assertTrue(
            checkedOutBranch == "feature/unfetched",
            "unfetched remote head opens as a local tracking branch")
        try await service.removeWorktree(repositoryPath: repo.path, worktreePath: worktreePath)
    }

    private func createRemoteFixture(origin: URL, seed: URL, temp: URL) throws {
        try run("git", ["init", "--bare", origin.path], cwd: temp.path)
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try run("git", ["init", "-b", "main", "."], cwd: seed.path)
        try run("git", ["config", "user.email", "test@example.com"], cwd: seed.path)
        try run("git", ["config", "user.name", "Test User"], cwd: seed.path)
        try "hello".write(
            to: seed.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try run("git", ["add", "README.md"], cwd: seed.path)
        try run("git", ["commit", "-m", "initial"], cwd: seed.path)
        try run("git", ["remote", "add", "origin", origin.path], cwd: seed.path)
        try run("git", ["push", "-u", "origin", "main"], cwd: seed.path)
        try run("git", ["checkout", "-b", "feature/unfetched"], cwd: seed.path)
        try "feature".write(
            to: seed.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try run("git", ["add", "feature.txt"], cwd: seed.path)
        try run("git", ["commit", "-m", "feature"], cwd: seed.path)
        try run("git", ["push", "origin", "feature/unfetched"], cwd: seed.path)
    }

    private func run(_ executable: String, _ args: [String], cwd: String) throws {
        _ = try capture(executable, args, cwd: cwd)
    }

    private func capture(_ executable: String, _ args: [String], cwd: String) throws -> String {
        try TestGit.run(executable, args, cwd: cwd)
    }

    private func assertTrue(_ condition: Bool, _ message: String) {
        #expect(condition, Comment(rawValue: message))
    }

    private func assertFalse(_ condition: Bool, _ message: String) {
        assertTrue(!condition, message)
    }
}
