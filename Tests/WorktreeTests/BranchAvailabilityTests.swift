import Foundation
import Testing

@testable import Argus

@Suite
struct BranchAvailabilityTests {
    @Test
    func duplicateLocalAndRemoteBranchesAreRejected() async throws {
        let temporaryDirectory = try TestTemporaryDirectory(prefix: "argus-branch-availability")
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
        try run("git", ["update-ref", "refs/remotes/origin/remote-only", "HEAD"], cwd: root.path)

        let service = WorktreeService()
        try await service.ensureBranchNameAvailable("new-feature", repositoryPath: root.path)

        do {
            try await service.ensureBranchNameAvailable("feature", repositoryPath: root.path)
            fail("local duplicate branch should throw")
        } catch WorktreeError.branchAlreadyExists(let branch) {
            assertEqual(branch, "feature", "local duplicate branch is reported")
        }

        do {
            try await service.ensureBranchNameAvailable("remote-only", repositoryPath: root.path)
            fail("remote duplicate branch should throw")
        } catch WorktreeError.branchAlreadyExists(let branch) {
            assertEqual(branch, "remote-only", "remote duplicate branch is reported")
        }
    }

    private func run(_ executable: String, _ args: [String], cwd: String) throws {
        _ = try TestGit.run(executable, args, cwd: cwd)
    }

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }

    private func fail(_ message: String) -> Never {
        Issue.record(Comment(rawValue: message))
        fatalError(message)
    }
}
