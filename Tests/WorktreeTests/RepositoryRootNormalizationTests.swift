import Foundation
import Testing

@testable import Argus

@Suite
struct RepositoryRootNormalizationTests {
    @Test
    func canonicalizesRepositorySubdirectoriesAndRejectsNonRepositories() async throws {
        let rootDirectory = try TestTemporaryDirectory(prefix: "argus-repo-root")
        let root = rootDirectory.url
        let subdir = root.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        defer { rootDirectory.remove() }

        try run("git", ["init", "."], cwd: root.path)
        let service = WorktreeService()
        let canonicalRoot = try await service.canonicalRepositoryRoot(for: subdir.path)
        assertEqual(
            canonicalRoot, root.resolvingSymlinksInPath().path,
            "subdirectory resolves to canonical repo root")

        let outsideDirectory = try TestTemporaryDirectory(prefix: "argus-not-repo")
        let outside = outsideDirectory.url
        defer { outsideDirectory.remove() }
        do {
            _ = try await service.canonicalRepositoryRoot(for: outside.path)
            Issue.record("non-repository path should throw")
        } catch WorktreeError.notAGitRepository(let path) {
            assertEqual(path, outside.path, "invalid path is reported as not a git repository")
        }
    }

    private func run(_ executable: String, _ args: [String], cwd: String) throws {
        _ = try TestGit.run(executable, args, cwd: cwd)
    }

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }
}
