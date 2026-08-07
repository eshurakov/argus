import Foundation
import Testing

@testable import Argus

@Suite
struct BranchNameSuggestionTests {
    @Test
    func availableBranchSuggestionsPreserveFreeCandidatesAndAvoidCollisions() async throws {
        let temporaryDirectory = try TestTemporaryDirectory(prefix: "argus-branch-suggestion")
        let root = temporaryDirectory.url
        defer { temporaryDirectory.remove() }

        try run("git", ["init", "."], cwd: root.path)
        try run("git", ["config", "user.email", "test@example.com"], cwd: root.path)
        try run("git", ["config", "user.name", "Test User"], cwd: root.path)
        try "hello".write(
            to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try run("git", ["add", "README.md"], cwd: root.path)
        try run("git", ["commit", "-m", "initial"], cwd: root.path)
        try run("git", ["branch", "taken-branch"], cwd: root.path)
        try run("git", ["update-ref", "refs/remotes/origin/also-taken", "HEAD"], cwd: root.path)

        let service = WorktreeService()

        let untouched = try await service.suggestAvailableBranchName(
            preferring: "totally-free-name",
            prefix: "",
            repositoryPath: root.path
        )
        assertEqual(untouched, "totally-free-name", "an available candidate is returned unchanged")

        let replaced = try await service.suggestAvailableBranchName(
            preferring: "taken-branch",
            prefix: "",
            repositoryPath: root.path
        )
        assertFalse(replaced == "taken-branch", "a locally colliding candidate is replaced")
        assertFalse(replaced.isEmpty, "a replacement suggestion is always produced")

        let replacedRemote = try await service.suggestAvailableBranchName(
            preferring: "also-taken",
            prefix: "",
            repositoryPath: root.path
        )
        assertFalse(replacedRemote == "also-taken", "a remote-tracking collision is also replaced")

        let prefixed = try await service.suggestAvailableBranchName(
            preferring: "taken-branch",
            prefix: "eshurakov",
            repositoryPath: root.path
        )
        assertTrue(
            prefixed == "taken-branch" || prefixed.hasPrefix("eshurakov/"),
            "replacement suggestions honor the configured prefix"
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
