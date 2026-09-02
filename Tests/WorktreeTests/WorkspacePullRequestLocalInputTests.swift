import Foundation
import Testing

@testable import Argus

@Suite
struct WorkspacePullRequestLocalInputTests {
    @Test
    func readsCurrentBranchHeadAndConfiguredForkUpstreamWithoutFetchingOrRewritingMetadata() async throws {
        let fixture = try PullRequestLocalGitFixture()
        defer { fixture.temporaryDirectory.remove() }
        try TestGit.run(["remote", "add", "fork", "https://github.example/fork/repo.git"], in: fixture.repository)
        try TestGit.run(["config", "branch.feature.remote", "fork"], in: fixture.repository)
        try TestGit.run(["config", "branch.feature.merge", "refs/heads/feature"], in: fixture.repository)
        let configuration = try TestGit.run(["config", "--local", "--list"], in: fixture.repository)
        let references = try TestGit.run(["show-ref"], in: fixture.repository)
        let service = WorktreePullRequestLocalInputProvider()

        let inputs = try await service.readProject(
            repositoryPath: fixture.target.repositoryPath, worktreePaths: [fixture.target.worktreePath]
        )
        let branch = try #require(inputs.worktrees[fixture.target.worktreePath]).get()
        #expect(branch.branchName == "feature")
        #expect(branch.headCommitObjectID == (try TestGit.run(["rev-parse", "HEAD"], in: fixture.worktree)))
        #expect(branch.upstreamRepository?.owner == "fork")
        #expect(try await service.readWorktree(target: fixture.target).branch == branch)
        #expect(try TestGit.run(["config", "--local", "--list"], in: fixture.repository) == configuration)
        #expect(try TestGit.run(["show-ref"], in: fixture.repository) == references)
        #expect(
            !FileManager.default.fileExists(atPath: fixture.repository.appendingPathComponent(".git/FETCH_HEAD").path))

        try TestGit.run(["switch", "-c", "renamed"], in: fixture.worktree)
        try TestGit.run(["commit", "--allow-empty", "-m", "advance"], in: fixture.worktree)
        let changed = try await service.readProject(
            repositoryPath: fixture.target.repositoryPath, worktreePaths: [fixture.target.worktreePath]
        )
        let observed = try #require(changed.worktrees[fixture.target.worktreePath]).get()
        #expect(observed.branchName == "renamed")
        #expect(observed.headCommitObjectID != branch.headCommitObjectID)
        #expect(observed.upstreamRepository == nil)
    }

    @Test
    func symbolicBranchRevalidationMatchesWorktreeListingWhenATagSharesItsName() async throws {
        let fixture = try PullRequestLocalGitFixture()
        defer { fixture.temporaryDirectory.remove() }
        try TestGit.run(["branch", "-m", "release"], in: fixture.worktree)
        try TestGit.run(["tag", "release"], in: fixture.worktree)
        let service = WorktreePullRequestLocalInputProvider()
        let inputs = try await service.readProject(
            repositoryPath: fixture.target.repositoryPath, worktreePaths: [fixture.target.worktreePath]
        )
        let listed = try #require(inputs.worktrees[fixture.target.worktreePath]).get()
        let revalidated = try await service.readWorktree(target: fixture.target)

        #expect(listed.branchName == "release")
        #expect(revalidated.branch == listed)
    }

    @Test
    func symbolicBranchRevalidationRejectsReferencesOutsideLocalBranches() async throws {
        let fixture = try PullRequestLocalGitFixture()
        defer { fixture.temporaryDirectory.remove() }
        try TestGit.run(["tag", "release"], in: fixture.worktree)
        try TestGit.run(["symbolic-ref", "HEAD", "refs/tags/release"], in: fixture.worktree)
        let service = WorktreePullRequestLocalInputProvider()

        await #expect(throws: PullRequestStatusError.self) {
            try await service.readWorktree(target: fixture.target)
        }
    }

    @Test
    func upstreamMappingHonorsWorktreeSpecificConfiguration() async throws {
        let fixture = try PullRequestLocalGitFixture()
        defer { fixture.temporaryDirectory.remove() }
        try TestGit.run(["config", "extensions.worktreeConfig", "true"], in: fixture.repository)
        try TestGit.run(["config", "--worktree", "branch.feature.remote", "worktree-fork"], in: fixture.worktree)
        try TestGit.run(["config", "--worktree", "branch.feature.merge", "refs/heads/feature"], in: fixture.worktree)
        try TestGit.run(
            ["config", "--worktree", "remote.worktree-fork.url", "https://github.example/worktree-fork/repo.git"],
            in: fixture.worktree
        )
        let configuration = try TestGit.run(["config", "--worktree", "--list"], in: fixture.worktree)
        let service = WorktreePullRequestLocalInputProvider()
        let inputs = try await service.readProject(
            repositoryPath: fixture.target.repositoryPath, worktreePaths: [fixture.target.worktreePath]
        )
        let branch = try #require(inputs.worktrees[fixture.target.worktreePath]).get()
        #expect(branch.upstreamRepository?.owner == "worktree-fork")
        #expect(inputs.fetchRemotes.map(\.name) == ["origin"])
        #expect(try await service.readWorktree(target: fixture.target).branch == branch)
        #expect(try TestGit.run(["config", "--worktree", "--list"], in: fixture.worktree) == configuration)
    }

    @Test
    func missingDetachedAndUnregisteredWorktreesHaveLocalExplanations() async throws {
        let fixture = try PullRequestLocalGitFixture()
        defer { fixture.temporaryDirectory.remove() }
        let service = WorktreePullRequestLocalInputProvider()
        try TestGit.run(["switch", "--detach"], in: fixture.worktree)
        let unregistered = fixture.repository.appendingPathComponent("unregistered")
        try FileManager.default.createDirectory(at: unregistered, withIntermediateDirectories: true)
        let missing = fixture.repository.appendingPathComponent("missing").path
        let inputs = try await service.readProject(
            repositoryPath: fixture.target.repositoryPath,
            worktreePaths: [fixture.target.worktreePath, unregistered.path, missing]
        )
        for (path, explanation) in [
            (fixture.target.worktreePath, "detached"), (unregistered.path, "registered"), (missing, "missing")
        ] {
            guard case .failure(let error) = inputs.worktrees[path] else {
                Issue.record("Expected an unavailable local worktree for \(path)")
                continue
            }
            #expect(error.localizedDescription.contains(explanation))
        }
        await #expect(throws: PullRequestStatusError.self) {
            try await service.readWorktree(target: fixture.target)
        }
    }

    @Test
    func canonicalWorktreePathsResolveSymlinksAndRejectAnotherRepository() async throws {
        let fixture = try PullRequestLocalGitFixture()
        defer { fixture.temporaryDirectory.remove() }
        let alias = fixture.temporaryDirectory.url.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.worktree)
        let target = WorkspacePullRequestTarget(
            workspaceID: UUID(), projectID: fixture.target.projectID,
            repositoryPath: fixture.repository.path, worktreePath: alias.path
        )
        #expect(target.worktreePath == fixture.target.worktreePath)
        let service = WorktreePullRequestLocalInputProvider()
        #expect(try await service.readWorktree(target: target).branch.branchName == "feature")
        let other = fixture.temporaryDirectory.url.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try TestGit.run(["init", "-b", "main"], in: other)
        let mismatched = WorkspacePullRequestTarget(
            workspaceID: UUID(), projectID: target.projectID,
            repositoryPath: other.path, worktreePath: target.worktreePath
        )
        await #expect(throws: PullRequestStatusError.self) {
            try await service.readWorktree(target: mismatched)
        }
    }
}

private struct PullRequestLocalGitFixture {
    let temporaryDirectory: TestTemporaryDirectory
    let repository: URL
    let worktree: URL
    let target: WorkspacePullRequestTarget

    init() throws {
        temporaryDirectory = try TestTemporaryDirectory(prefix: "argus-pull-request-local-inputs")
        repository = temporaryDirectory.url.appendingPathComponent("repository")
        worktree = temporaryDirectory.url.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try TestGit.run(["init", "-b", "main"], in: repository)
        try TestGit.run(["config", "user.email", "test@example.com"], in: repository)
        try TestGit.run(["config", "user.name", "Test User"], in: repository)
        try TestGit.run(["config", "commit.gpgsign", "false"], in: repository)
        try TestGit.run(["commit", "--allow-empty", "-m", "initial"], in: repository)
        try TestGit.run(["remote", "add", "origin", "https://github.example/base/repo.git"], in: repository)
        try TestGit.run(["worktree", "add", "-b", "feature", worktree.path], in: repository)
        target = WorkspacePullRequestTarget(
            workspaceID: UUID(), projectID: UUID(), repositoryPath: repository.path, worktreePath: worktree.path
        )
    }
}
