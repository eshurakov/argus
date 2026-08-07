import Foundation
import Testing

@testable import Argus

@Suite
struct WorktreeBranchUniquenessTests {
    @Test
    func uniqueBranchNamesSkipLocalAndRemoteCollisions() async throws {
        let temporaryDirectory = try TestTemporaryDirectory(prefix: "argus-branch-uniqueness")
        let root = temporaryDirectory.url
        defer { temporaryDirectory.remove() }

        try run("git", ["init", "."], cwd: root.path)
        try run("git", ["config", "user.email", "test@example.com"], cwd: root.path)
        try run("git", ["config", "user.name", "Test User"], cwd: root.path)
        try "hello".write(
            to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try run("git", ["add", "README.md"], cwd: root.path)
        try run("git", ["commit", "-m", "initial"], cwd: root.path)
        try run("git", ["branch", "feature"], cwd: root.path)
        try run("git", ["update-ref", "refs/remotes/origin/feature-1", "HEAD"], cwd: root.path)

        let service = WorktreeService()
        let unique = try await service.uniqueBranchName("feature", repositoryPath: root.path)
        assertEqual(unique, "feature-2", "unique branch name skips local and remote collisions")
    }

    private func run(_ executable: String, _ args: [String], cwd: String) throws {
        _ = try TestGit.run(executable, args, cwd: cwd)
    }

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }
}
