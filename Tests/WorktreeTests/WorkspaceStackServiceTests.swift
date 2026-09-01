import Darwin
import Foundation
import Testing

@testable import Argus

@Suite
struct WorkspaceStackServiceTests {
    @Test
    func absentMetadataPreservesInventoryWithoutWritingFiles() async throws {
        let fixture = try StackRepositoryFixture()
        let before = try fixture.files()
        let snapshot = try await fixture.service.load(repositoryPath: fixture.repository.path)
        #expect(snapshot.gitCommonDirectory == fixture.repository.appendingPathComponent(".git").path)
        #expect(snapshot.worktrees == [GitWorktreeBranch(path: fixture.repository.path, branch: "main")])
        #expect(snapshot.parents.isEmpty)
        #expect(snapshot.issue == nil)
        #expect(try fixture.files() == before)
    }

    @Test
    func decodesRecordedOrderWithoutUsingCachedHashesOrPullRequests() async throws {
        let fixture = try StackRepositoryFixture()
        try fixture.writeMetadata(
            """
            {
              "schemaVersion": 1,
              "repository": "github.com:example/project",
              "stacks": [{
                "id": "published-id", "number": 42,
                "trunk": {"branch": "release/2026", "head": "cached-trunk-sha"},
                "branches": [
                  {"branch": "api", "base": "cached-base-sha", "head": "cached-head-sha"},
                  {"branch": "deleted-parent", "pullRequest": {"number": 7, "merged": true}},
                  {"branch": "ui", "base": "not-a-parent-branch", "pullRequest": {"number": 8}}
                ]
              }]
            }
            """
        )
        let before = try fixture.files()
        let snapshot = try await fixture.service.load(repositoryPath: fixture.repository.path)
        #expect(snapshot.issue == nil)
        #expect(snapshot.parents == ["api": "release/2026", "deleted-parent": "api", "ui": "deleted-parent"])
        #expect(snapshot.trunkBranches == ["release/2026"])
        #expect(try fixture.files() == before)
    }

    @Test
    func readsMetadataFromAnUnopenedLinkedCheckoutAfterItsBranchChanges() async throws {
        let fixture = try StackRepositoryFixture()
        let source = try fixture.addWorktree(branch: "source/tracker", directory: "unrelated-admin-name")
        let first = try fixture.addWorktree(branch: "feature/one")
        let second = try fixture.addWorktree(branch: "feature/two")
        try fixture.writeStacks(
            [StackChainFixture(trunkBranch: "develop", branches: ["feature/one", "feature/two"])], checkout: source)
        try TestGit.run(["switch", "-c", "checkout-moved"], in: source)
        let snapshot = try await fixture.service.load(repositoryPath: fixture.repository.path)
        let linkedSnapshot = try await fixture.service.load(repositoryPath: source.path)
        #expect(snapshot == linkedSnapshot)
        #expect(snapshot == (try fixture.reader.read(repositoryPath: source.path)))
        #expect(snapshot.issue == nil)
        #expect(snapshot.parents == ["feature/one": "develop", "feature/two": "feature/one"])
        #expect(snapshot.worktrees.contains(GitWorktreeBranch(path: source.path, branch: "checkout-moved")))
        #expect(snapshot.worktrees.contains(GitWorktreeBranch(path: first.path, branch: "feature/one")))
        #expect(snapshot.worktrees.contains(GitWorktreeBranch(path: second.path, branch: "feature/two")))
    }

    @Test(arguments: [
        "", "{", "{\"stacks\":[]}",
        "{\"schemaVersion\":\"1\",\"stacks\":[]}",
        "{\"schemaVersion\":1,\"stacks\":null}",
        "{\"schemaVersion\":1,\"stacks\":[{\"branches\":[]}]}",
        "{\"schemaVersion\":1,\"stacks\":[{\"trunk\":{\"branch\":\"main\"},\"branches\":[{\"branch\":7}]}]}"
    ])
    func malformedMetadataIsDiagnosedAndRetainsDiscovery(_ json: String) async throws {
        let fixture = try StackRepositoryFixture()
        try fixture.writeMetadata(json)
        let snapshot = try await fixture.service.load(repositoryPath: fixture.repository.path)
        #expect(snapshot.parents.isEmpty)
        #expect(snapshot.issue == "Local gh-stack metadata is malformed.")
        #expect(snapshot.gitCommonDirectory == fixture.repository.appendingPathComponent(".git").path)
        #expect(snapshot.worktrees == [GitWorktreeBranch(path: fixture.repository.path, branch: "main")])
    }

    @Test(arguments: [-1, 0, 2])
    func acceptsOnlySchemaOneBeforeInterpretingItsFields(_ version: Int) async throws {
        let fixture = try StackRepositoryFixture()
        try fixture.writeMetadata("{\"schemaVersion\":\(version),\"stacks\":\"different-schema\"}")
        let snapshot = try await fixture.service.load(repositoryPath: fixture.repository.path)
        #expect(snapshot.parents.isEmpty)
        #expect(snapshot.issue == "Local gh-stack metadata uses an unsupported schema version.")
        #expect(snapshot.worktrees.count == 1)
    }

    @Test
    func unpublishedAndEmptyMetadataNeedNoOptionalFields() async throws {
        let fixture = try StackRepositoryFixture()
        try fixture.writeStacks([StackChainFixture(trunkBranch: "develop", branches: ["first", "second"])])
        let unpublished = try await fixture.service.load(repositoryPath: fixture.repository.path)
        #expect(unpublished.parents == ["first": "develop", "second": "first"])
        #expect(unpublished.issue == nil)
        try fixture.writeStacks([])
        let empty = try await fixture.service.load(repositoryPath: fixture.repository.path)
        #expect(empty.parents.isEmpty)
        #expect(empty.trunkBranches.isEmpty)
        #expect(empty.issue == nil)
    }

    @Test(arguments: ["directory", "symlink", "unreadable", "oversized"])
    func rejectsUnreadableNonregularAndOversizedMetadata(_ kind: String) async throws {
        let fixture = try StackRepositoryFixture()
        let url = try fixture.metadataURL()
        switch kind {
        case "directory":
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        case "symlink":
            let target = fixture.repository.appendingPathComponent("decoy")
            try Data("{\"schemaVersion\":1,\"stacks\":[]}".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        case "unreadable":
            try fixture.writeStacks([])
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        default:
            try Data(repeating: 32, count: 1_048_577).write(to: url)
        }
        defer {
            if kind == "unreadable" {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        let snapshot = try await fixture.service.load(repositoryPath: fixture.repository.path)
        #expect(snapshot.parents.isEmpty)
        #expect(snapshot.issue != nil)
        #expect(snapshot.worktrees.count == 1)
    }

    @Test
    func matchingSourcesCoalesceAndPublishingPreservesIdentity() async throws {
        let fixture = try StackRepositoryFixture()
        let linked = try fixture.addWorktree(branch: "unrelated")
        let definition = StackChainFixture(trunkBranch: "main", branches: ["first", "second"])
        try fixture.writeStacks([definition, definition])
        try fixture.writeStacks([definition], checkout: linked, published: true)
        let before = try await fixture.service.load(repositoryPath: fixture.repository.path)
        try fixture.writeStacks([definition], published: true)
        let after = try await fixture.service.load(repositoryPath: fixture.repository.path)
        #expect(before.issue == nil)
        #expect(before.parents == ["first": "main", "second": "first"])
        #expect(after == before)
    }

    @Test(arguments: ["first", "second"])
    func consistentPartialChainsAndForksCoalesce(_ parent: String) async throws {
        let fixture = try StackRepositoryFixture()
        let linked = try fixture.addWorktree(branch: "source")
        try fixture.writeStacks([StackChainFixture(trunkBranch: "main", branches: ["first", "second"])])
        try fixture.writeStacks(
            [
                StackChainFixture(trunkBranch: "main", branches: ["first", "other"]),
                StackChainFixture(trunkBranch: parent, branches: ["third", "fourth"])
            ], checkout: linked)
        let snapshot = try await fixture.service.load(repositoryPath: fixture.repository.path)
        #expect(snapshot.issue == nil)
        #expect(
            snapshot.parents == [
                "first": "main", "second": "first", "other": "first", "third": parent, "fourth": "third"
            ])
        #expect(snapshot.trunkBranches == ["main", parent])
    }

    @Test
    func conflictingParentsDoNotEraseTheirDescendantsOrUnrelatedRelations() async throws {
        let fixture = try StackRepositoryFixture()
        let linked = try fixture.addWorktree(branch: "source")
        try fixture.writeStacks([StackChainFixture(trunkBranch: "main", branches: ["first", "second"])])
        try fixture.writeStacks(
            [StackChainFixture(trunkBranch: "develop", branches: ["first", "third"])], checkout: linked)
        let snapshot = try await fixture.service.load(repositoryPath: fixture.repository.path)
        #expect(snapshot.parents == ["second": "first", "third": "first"])
        #expect(Set(snapshot.conflicts.keys) == ["first"])
        #expect(snapshot.worktrees.count == 2)
    }

    @Test(arguments: [["first", "first"], ["first", ""], [" "]])
    func invalidEdgesDoNotInventParents(_ branches: [String]) async throws {
        let fixture = try StackRepositoryFixture()
        try fixture.writeStacks([StackChainFixture(trunkBranch: "main", branches: branches)])
        let snapshot = try await fixture.service.load(repositoryPath: fixture.repository.path)
        #expect(snapshot.parents == (branches.first == "first" ? ["first": "main"] : [:]))
        #expect(snapshot.issue != nil)
    }

    @Test
    func cyclicIncomingEdgesAreExcludedWithoutErasingDescendants() async throws {
        let fixture = try StackRepositoryFixture()
        try fixture.writeStacks([StackChainFixture(trunkBranch: "main", branches: ["first", "main", "child"])])
        let snapshot = try await fixture.service.load(repositoryPath: fixture.repository.path)
        #expect(snapshot.parents == ["child": "main"])
        #expect(Set(snapshot.conflicts.keys) == ["first", "main"])
    }

    @Test
    func malformedLinkedMetadataPreservesOtherwiseValidRelations() async throws {
        let fixture = try StackRepositoryFixture()
        let linked = try fixture.addWorktree(branch: "source")
        try fixture.writeStacks([StackChainFixture(trunkBranch: "main", branches: ["first", "second"])])
        try Data("{".utf8).write(to: fixture.metadataURL(checkout: linked))
        let snapshot = try await fixture.service.load(repositoryPath: fixture.repository.path)
        #expect(snapshot.parents == ["first": "main", "second": "first"])
        #expect(snapshot.issue == "Local gh-stack metadata is malformed.")
        #expect(snapshot.worktrees.count == 2)
    }
}

extension WorkspaceStackServiceTests {
    @Test
    func resolvesASeparateCommonDirectoryWithoutTrimmingItsPath() async throws {
        let fixture = try StackRepositoryFixture()
        let directory = fixture.repository.deletingLastPathComponent().appendingPathComponent("metadata with spaces ")
        try TestGit.run(["init", "--separate-git-dir", directory.path], in: fixture.repository)
        try Data("{\"schemaVersion\":1,\"stacks\":[]}".utf8).write(to: directory.appendingPathComponent("gh-stack"))
        let snapshot = try await fixture.service.load(repositoryPath: fixture.repository.path)
        #expect(snapshot.gitCommonDirectory == directory.path)
        #expect(snapshot.issue == nil)
        #expect(snapshot.parents.isEmpty)
        #expect(snapshot.worktrees == [GitWorktreeBranch(path: fixture.repository.path, branch: "main")])
        let linked = try fixture.addWorktree(branch: "child")
        let linkedSnapshot = try await fixture.service.load(repositoryPath: linked.path)
        #expect(linkedSnapshot.gitCommonDirectory == directory.path)
        #expect(linkedSnapshot.worktrees == [GitWorktreeBranch(path: linked.path, branch: "child")])
        #expect(linkedSnapshot.parents.isEmpty)
    }

    @Test(arguments: ["main", "develop"])
    func independentStacksMayShareTheirRecordedTrunk(_ trunk: String) async throws {
        let fixture = try StackRepositoryFixture()
        try fixture.writeStacks([
            StackChainFixture(trunkBranch: trunk, branches: ["first", "second"]),
            StackChainFixture(trunkBranch: trunk, branches: ["other", "another"])
        ])
        let snapshot = try await fixture.service.load(repositoryPath: fixture.repository.path)
        #expect(snapshot.issue == nil)
        #expect(snapshot.parents == ["first": trunk, "second": "first", "other": trunk, "another": "other"])
        #expect(snapshot.trunkBranches == [trunk])
    }

    @Test
    func nulInventoryPreservesPathsAndExcludesStaleBindings() async throws {
        let fixture = try StackRepositoryFixture()
        let spaced = try fixture.addWorktree(branch: "topic/one", directory: " checkout with\nnewlines \n")
        let detached = try fixture.addWorktree(branch: "detached-source")
        try TestGit.run(["switch", "--detach"], in: detached)
        let removed = try fixture.addWorktree(branch: "removed")
        try FileManager.default.removeItem(at: removed)
        let unregistered = fixture.repository.appendingPathComponent("unregistered")
        try FileManager.default.createDirectory(at: unregistered, withIntermediateDirectories: false)
        let alias = fixture.repository.deletingLastPathComponent().appendingPathComponent("repository-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.repository)
        let snapshot = try await fixture.service.load(repositoryPath: alias.path)
        #expect(snapshot.issue == nil)
        #expect(snapshot.gitCommonDirectory == fixture.repository.appendingPathComponent(".git").path)
        #expect(snapshot.worktrees.count == 3)
        #expect(snapshot.worktrees.contains(GitWorktreeBranch(path: spaced.path, branch: "topic/one")))
        #expect(snapshot.worktrees.contains(GitWorktreeBranch(path: detached.path, branch: nil)))
        #expect(!snapshot.worktrees.contains { $0.path == removed.path || $0.path == unregistered.path })
    }

    @Test
    func aLaterRefreshRecoversFromPartialMetadata() async throws {
        let fixture = try StackRepositoryFixture()
        try fixture.writeMetadata("{\"schemaVersion\":1,\"stacks\":[")
        let partial = try await fixture.service.load(repositoryPath: fixture.repository.path)
        #expect(partial.issue != nil)
        try fixture.writeStacks([StackChainFixture(trunkBranch: "main", branches: ["first", "second"])])
        let repaired = try await fixture.service.load(repositoryPath: fixture.repository.path)
        #expect(repaired.issue == nil)
        #expect(repaired.parents == ["first": "main", "second": "first"])
        #expect(repaired.worktrees == partial.worktrees)
    }

    @Test
    func discoveryErrorsDoNotExposePathsOrGitStderr() async throws {
        let temporary = try TestTemporaryDirectory(prefix: "argus-stack-sensitive-fixture")
        defer { temporary.remove() }
        do {
            _ = try await WorkspaceStackService().load(repositoryPath: temporary.url.path)
            Issue.record("A non-repository must fail discovery")
        } catch {
            #expect(error.localizedDescription == "Could not discover local Git worktrees and recorded branch parents.")
        }
    }

    @Test
    func cancelledLoadsPropagateCancellation() async throws {
        let fixture = try StackRepositoryFixture()
        let path = fixture.repository.path
        let service = fixture.service
        let task = Task { try await service.load(repositoryPath: path) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test
    func cancellingAnActiveLoadStopsItsSynchronousGitProcess() async throws {
        let fixture = try StackRepositoryFixture()
        let pipe = fixture.repository.appendingPathComponent("blocking-include")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        try TestGit.run(["config", "include.path", pipe.path], in: fixture.repository)
        let path = fixture.repository.path
        let service = fixture.service
        let start = Date()
        let task = Task { try await service.load(repositoryPath: path) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 3)
    }
}

private struct StackChainFixture: Sendable {
    let trunkBranch: String
    let branches: [String]
}

private final class StackRepositoryFixture {
    private let temporary: TestTemporaryDirectory
    let repository: URL

    var reader: RecordedBaseBranchReader {
        RecordedBaseBranchReader(
            environment: GitCommandEnvironment.standard.merging([
                "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": "0"
            ]) { _, new in new })
    }

    var service: WorkspaceStackService { WorkspaceStackService(reader: reader) }

    init() throws {
        temporary = try TestTemporaryDirectory(prefix: "argus-workspace-stack")
        repository = temporary.url.appendingPathComponent("repository").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try TestGit.run(["init", "-b", "main", "."], in: repository)
        try TestGit.run(
            [
                "-c", "user.name=Test User", "-c", "user.email=test@example.com",
                "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                "commit", "--allow-empty", "-m", "initial"
            ], in: repository)
    }

    deinit { temporary.remove() }

    func addWorktree(branch: String, directory: String? = nil) throws -> URL {
        let name = directory ?? branch.replacingOccurrences(of: "/", with: "-")
        let checkout = temporary.url.appendingPathComponent(name).resolvingSymlinksInPath()
        try TestGit.run(["worktree", "add", "-b", branch, checkout.path, "HEAD"], in: repository)
        return checkout
    }

    func metadataURL(checkout: URL? = nil) throws -> URL {
        let path = try TestGit.run(["rev-parse", "--path-format=absolute", "--git-dir"], in: checkout ?? repository)
        return URL(fileURLWithPath: path).appendingPathComponent("gh-stack")
    }

    func writeMetadata(_ json: String) throws {
        try Data(json.utf8).write(to: metadataURL())
    }

    func writeStacks(_ definitions: [StackChainFixture], checkout: URL? = nil, published: Bool = false) throws {
        let stacks: [[String: Any]] = definitions.map { definition in
            var stack: [String: Any] = [
                "trunk": ["branch": definition.trunkBranch],
                "branches": definition.branches.map { ["branch": $0] }
            ]
            if published {
                stack["id"] = "upstream-identifier"
                stack["number"] = 42
            }
            return stack
        }
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "stacks": stacks])
        try data.write(to: metadataURL(checkout: checkout))
    }

    func files() throws -> [String: StackFixtureFile] {
        let paths = try FileManager.default.subpathsOfDirectory(atPath: repository.path)
        return try Dictionary(
            uniqueKeysWithValues: paths.map { path in
                let url = repository.appendingPathComponent(path)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let data = attributes[.type] as? FileAttributeType == .typeRegular ? try Data(contentsOf: url) : nil
                return (path, StackFixtureFile(data: data, modified: attributes[.modificationDate] as? Date))
            })
    }
}

private struct StackFixtureFile: Equatable {
    let data: Data?
    let modified: Date?
}
