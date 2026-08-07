import Foundation
import Testing

@testable import Argus

@Suite
struct CurrentBranchDetectionTests {
    @Test
    func detectsMainCurrentAndDetachedBranches() async throws {
        let temporaryDirectory = try TestTemporaryDirectory(prefix: "argus-current-branch")
        let root = temporaryDirectory.url
        defer { temporaryDirectory.remove() }

        try run("git", ["init", "-b", "main", "."], cwd: root.path)
        try run("git", ["config", "user.email", "test@example.com"], cwd: root.path)
        try run("git", ["config", "user.name", "Test User"], cwd: root.path)
        try "hello".write(
            to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try run("git", ["add", "README.md"], cwd: root.path)
        try run("git", ["commit", "-m", "initial"], cwd: root.path)
        try run("git", ["checkout", "-b", "feature/current"], cwd: root.path)

        let service = WorktreeService()
        let mainBranch = try await service.detectMainBranch(repositoryPath: root.path)
        let currentBranch = try await service.currentBranchName(repositoryPath: root.path)

        assertEqual(mainBranch, "main", "main branch detection remains independent")
        assertEqual(currentBranch, "feature/current", "current branch reflects checked-out branch")

        let commit = try capture("git", ["rev-parse", "HEAD"], cwd: root.path)
        try run("git", ["checkout", "--detach", commit], cwd: root.path)
        let detachedBranch = try await service.currentBranchName(repositoryPath: root.path)
        assertEqual(detachedBranch, "(detached)", "detached HEAD has explicit fallback")
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
}
