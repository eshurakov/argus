import Foundation
import Testing

@testable import Argus

// The fixture-backed integration coverage intentionally stays in one test
// type so each scenario can share the same provider and Git setup.
// swiftlint:disable file_length

@Suite
// swiftlint:disable:next type_body_length
struct PullRequestWorkspaceTests {
    @Test
    func parsesNumbersAndCanonicalGitHubURLs() throws {
        #expect(try PullRequestInput.parse(" 42\n") == .number(42))

        let input = try PullRequestInput.parse(
            "https://GITHUB.example/Owner/Repository/pull/42/files?plain=1#diff"
        )
        guard case .url = input else {
            Issue.record("expected a URL Pull Request input")
            return
        }
        #expect(
            input.repositoryIdentity
                == RepositoryIdentity(
                    provider: .github,
                    host: "github.example",
                    owner: "owner",
                    repositoryName: "repository"
                )
        )
        #expect(input.number == 42)
    }

    @Test
    func rejectsUnsafePullRequestInput() {
        for value in [
            "",
            " ",
            "0",
            "-1",
            "1.5",
            "feature/branch",
            "http://github.com/owner/repo/pull/1",
            "https://user:password@github.com/owner/repo/pull/1",
            "https://github.com/owner/repo/issues/1",
            "https://github.com/owner/repo/pull/not-a-number"
        ] {
            #expect(throws: PullRequestWorkspaceError.self) {
                try PullRequestInput.parse(value)
            }
        }
    }

    @Test
    func normalizesSupportedGitHubRemoteURLShapes() {
        let expected = RepositoryIdentity(
            provider: .github,
            host: "github.com",
            owner: "owner",
            repositoryName: "repo"
        )
        for value in [
            "https://GITHUB.com/OWNER/REPO.git",
            "ssh://git@github.com/owner/repo.git",
            "git@github.com:owner/repo.git"
        ] {
            #expect(RepositoryIdentity.github(fromFetchRemoteURL: value) == expected)
        }
        #expect(RepositoryIdentity.github(fromFetchRemoteURL: "file:///tmp/repo") == nil)
    }

    @Test
    func remoteResolverPrefersOriginAndIgnoresPushOnlyURLs() async throws {
        let fixture = try PullRequestGitFixture()
        defer { fixture.remove() }
        try TestGit.run(
            [
                "config", "remote.push-only.pushurl",
                "https://github.example/owner/repo.git"
            ],
            in: fixture.repository
        )

        let remotes = try await WorktreeService().listFetchRemotes(
            repositoryPath: fixture.repository.path
        )
        #expect(remotes.first(where: { $0.name == "push-only" })?.fetchURLs.isEmpty == true)
        #expect(
            try await WorktreeService().fetchRemoteName(
                for: fixture.repositoryIdentity,
                repositoryPath: fixture.repository.path
            ) == "origin"
        )
    }

    @Test
    func providerUsesExactArgumentsEnvironmentAndDecodesForkMetadata() async throws {
        let headCommit = String(repeating: "a", count: 40)
        let json = """
            {
              "number": 42,
              "title": "Use the exact Pull Request head",
              "url": "https://github.example/owner/repo/pull/42",
              "headRefName": "feature/exact-head",
              "headRefOid": "\(headCommit)",
              "headRepository": {"name": "repo", "owner": {"login": "fork-owner"}},
              "headRepositoryOwner": {"login": "fork-owner"},
              "isCrossRepository": true
            }
            """
        let runner = RecordingGitHubCommandRunner(
            result: GitHubCommandResult(
                stdout: Data(json.utf8),
                stderr: Data(),
                exitCode: 0
            )
        )
        let service = GitHubPullRequestService(
            commandRunner: runner,
            environment: ["PATH": "/missing"],
            executableURL: URL(fileURLWithPath: "/test/gh")
        )

        let metadata = try await service.resolve(
            .number(42),
            repositoryPath: "/tmp/project"
        )
        #expect(metadata.number == 42)
        #expect(metadata.title == "Use the exact Pull Request head")
        #expect(metadata.headBranchName == "feature/exact-head")
        #expect(metadata.headRepository?.owner == "fork-owner")
        #expect(metadata.isCrossRepository)

        let invocation = runner.invocation
        #expect(
            invocation?.arguments == [
                "pr", "view", "42", "--json",
                "number,title,url,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository"
            ])
        #expect(invocation?.workingDirectory == "/tmp/project")
        #expect(invocation?.environment["GH_PROMPT_DISABLED"] == "1")
        #expect(invocation?.environment["GH_PAGER"] == "cat")
        #expect(invocation?.environment["NO_COLOR"] == "1")
        #expect(invocation?.environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(invocation?.timeout == 30)
    }

    @Test
    func missingGitHubCLIDoesNotStartACommand() async throws {
        let runner = RecordingGitHubCommandRunner(
            result: GitHubCommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
        )
        let service = GitHubPullRequestService(
            commandRunner: runner,
            environment: ["PATH": "/missing"],
            executableSearchPaths: [URL(fileURLWithPath: "/missing/gh")]
        )

        await #expect(throws: PullRequestWorkspaceError.githubCLIUnavailable) {
            try await service.resolve(.number(1), repositoryPath: "/tmp/project")
        }
        #expect(runner.invocation == nil)
    }

    @Test
    func providerErrorsRemainTypedAndDoNotExposeCredentialText() async throws {
        let authRunner = RecordingGitHubCommandRunner(
            result: GitHubCommandResult(
                stdout: Data(),
                stderr: Data("authentication failed; run gh auth login".utf8),
                exitCode: 1
            )
        )
        let authService = GitHubPullRequestService(
            commandRunner: authRunner,
            executableURL: URL(fileURLWithPath: "/test/gh")
        )
        await #expect(throws: PullRequestWorkspaceError.unauthenticated(host: nil)) {
            try await authService.resolve(.number(1), repositoryPath: "/tmp/project")
        }

        let ambiguousRunner = RecordingGitHubCommandRunner(
            result: GitHubCommandResult(
                stdout: Data(),
                stderr: Data("ambiguous default repository".utf8),
                exitCode: 1
            )
        )
        let ambiguousService = GitHubPullRequestService(
            commandRunner: ambiguousRunner,
            executableURL: URL(fileURLWithPath: "/test/gh")
        )
        await #expect(throws: PullRequestWorkspaceError.ambiguousDefaultRepository) {
            try await ambiguousService.resolve(.number(1), repositoryPath: "/tmp/project")
        }

        let secretRunner = RecordingGitHubCommandRunner(
            result: GitHubCommandResult(
                stdout: Data(),
                stderr: Data("fatal token ghp_test-secret".utf8),
                exitCode: 1
            )
        )
        let secretService = GitHubPullRequestService(
            commandRunner: secretRunner,
            executableURL: URL(fileURLWithPath: "/test/gh")
        )
        do {
            _ = try await secretService.resolve(.number(1), repositoryPath: "/tmp/project")
            Issue.record("expected provider failure")
        } catch {
            #expect(!error.localizedDescription.contains("ghp_test-secret"))
        }
    }

    @Test
    func pullRequestHeadCreatesExactBranchAndManagedWorktree() async throws {
        let fixture = try PullRequestGitFixture()
        defer { fixture.remove() }
        let service = WorktreeService(
            worktreeBaseURL: fixture.root.appendingPathComponent("managed-worktrees")
        )
        let metadata = try fixture.metadata(
            headBranchName: "feature/exact-head",
            headRepository: fixture.repositoryIdentity
        )

        let resolution = try await service.createPullRequestWorktree(
            projectId: fixture.projectID,
            repositoryPath: fixture.repository.path,
            metadata: metadata
        )

        #expect(resolution.branchName == "feature/exact-head")
        #expect(resolution.fetchedHeadObjectID == fixture.pullRequestCommit)
        #expect(!resolution.reusedExistingWorktree)
        #expect(
            try TestGit.run(
                ["rev-parse", "refs/heads/feature/exact-head"],
                in: fixture.repository
            ) == fixture.pullRequestCommit
        )
        #expect(
            try TestGit.run(["branch", "--show-current"], in: URL(fileURLWithPath: resolution.worktreePath))
                == "feature/exact-head"
        )

        let dirtyFile = URL(fileURLWithPath: resolution.worktreePath)
            .appendingPathComponent("dirty.txt")
        try "keep me".write(to: dirtyFile, atomically: true, encoding: .utf8)
        let reused = try await service.createPullRequestWorktree(
            projectId: fixture.projectID,
            repositoryPath: fixture.repository.path,
            metadata: metadata
        )
        #expect(reused.reusedExistingWorktree)
        #expect(reused.worktreePath == resolution.worktreePath)
        #expect(try String(contentsOf: dirtyFile, encoding: .utf8) == "keep me")
    }

    @Test
    func unconfiguredForkHeadDoesNotAddARemoteOrUpstream() async throws {
        let fixture = try PullRequestGitFixture()
        defer { fixture.remove() }
        let service = WorktreeService(
            worktreeBaseURL: fixture.root.appendingPathComponent("managed-worktrees")
        )
        let forkIdentity = RepositoryIdentity(
            provider: .github,
            host: "github.example",
            owner: "fork-owner",
            repositoryName: "repo"
        )
        let metadata = try fixture.metadata(
            headBranchName: "feature/fork-head",
            headRepository: forkIdentity
        )

        _ = try await service.createPullRequestWorktree(
            projectId: fixture.projectID,
            repositoryPath: fixture.repository.path,
            metadata: metadata
        )
        #expect(try TestGit.run(["remote"], in: fixture.repository) == "origin")
        #expect(throws: NSError.self) {
            _ = try TestGit.run(
                ["rev-parse", "--abbrev-ref", "feature/fork-head@{upstream}"],
                in: fixture.repository
            )
        }
    }

    @Test
    func matchingHeadRemoteProvidesUpstreamOnlyAtTheExactCommit() async throws {
        let fixture = try PullRequestGitFixture(pushHeadBranch: true)
        defer { fixture.remove() }
        let service = WorktreeService(
            worktreeBaseURL: fixture.root.appendingPathComponent("managed-worktrees")
        )
        let metadata = try fixture.metadata(
            headBranchName: "feature/exact-head",
            headRepository: fixture.repositoryIdentity
        )

        _ = try await service.createPullRequestWorktree(
            projectId: fixture.projectID,
            repositoryPath: fixture.repository.path,
            metadata: metadata
        )

        #expect(
            try TestGit.run(
                ["rev-parse", "--abbrev-ref", "feature/exact-head@{upstream}"],
                in: fixture.repository
            ) == "origin/feature/exact-head"
        )
    }

    @Test
    func conflictingLocalBranchIsNeverReset() async throws {
        let fixture = try PullRequestGitFixture()
        defer { fixture.remove() }
        try TestGit.run(["branch", "feature/exact-head", "HEAD"], in: fixture.repository)
        let service = WorktreeService(
            worktreeBaseURL: fixture.root.appendingPathComponent("managed-worktrees")
        )
        let metadata = try fixture.metadata(
            headBranchName: "feature/exact-head",
            headRepository: nil
        )

        await #expect(throws: PullRequestWorkspaceError.self) {
            try await service.createPullRequestWorktree(
                projectId: fixture.projectID,
                repositoryPath: fixture.repository.path,
                metadata: metadata
            )
        }
        #expect(
            try TestGit.run(
                ["rev-parse", "refs/heads/feature/exact-head"],
                in: fixture.repository
            ) == fixture.baseCommit
        )
    }

    @Test
    @MainActor
    func managerUsesPullRequestTitleAndReusesAnExactWorkspace() async throws {
        let fixture = try PullRequestGitFixture(pushHeadBranch: true)
        defer { fixture.remove() }
        let suiteName = "ArgusTests.PullRequestWorkspace.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshotURL = fixture.root.appendingPathComponent("session.json")
        let json = fixture.githubMetadataJSON(title: "Exact Pull Request title")
        let runner = RecordingGitHubCommandRunner(
            result: GitHubCommandResult(stdout: Data(json.utf8), stderr: Data(), exitCode: 0)
        )
        let manager = WorkspaceManager(
            settings: AppSettings(defaults: defaults),
            sessionSnapshotURL: snapshotURL,
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"],
            worktreeService: WorktreeService(
                worktreeBaseURL: fixture.root.appendingPathComponent("managed-worktrees")
            ),
            pullRequestService: GitHubPullRequestService(
                commandRunner: runner,
                executableURL: URL(fileURLWithPath: "/test/gh")
            )
        )
        let project = try #require(
            await manager.createProject(repositoryPath: fixture.repository.path)
        )
        let projectWorkspaceCount = project.workspaceIds.count

        let workspace = try await manager.createWorkspace(
            fromPullRequest: "42",
            in: project.id
        )
        #expect(workspace.workspaceType == .worktree)
        #expect(workspace.branchName == "feature/exact-head")
        #expect(workspace.title == "feature/exact-head")
        #expect(workspace.customTitle == "Exact Pull Request title")
        #expect(workspace.panelCount == 1)
        #expect(manager.selectedWorkspaceId == workspace.id)
        #expect(project.workspaceIds.count == projectWorkspaceCount + 1)
        let snapshot = try sessionSnapshot(at: snapshotURL)
        #expect(snapshot.selectedWorkspaceId == workspace.id)
        #expect(snapshot.workspaces.contains { $0.id == workspace.id })

        manager.renameWorkspace(workspace.id, title: "User title")
        let reused = try await manager.createWorkspace(
            fromPullRequest: "42",
            in: project.id
        )
        #expect(reused.id == workspace.id)
        #expect(reused.customTitle == "User title")
        #expect(project.workspaceIds.count == projectWorkspaceCount + 1)
    }

    private func sessionSnapshot(at url: URL) throws -> ArgusSessionSnapshot {
        try JSONDecoder().decode(
            ArgusSessionSnapshot.self,
            from: Data(contentsOf: url)
        )
    }
}

private final class RecordingGitHubCommandRunner: GitHubCommandRunning, @unchecked Sendable {
    struct Invocation: Sendable {
        let executableURL: URL
        let arguments: [String]
        let workingDirectory: String
        let environment: [String: String]
        let timeout: TimeInterval
    }

    private let lock = NSLock()
    private let result: GitHubCommandResult
    private var storedInvocation: Invocation?

    init(result: GitHubCommandResult) {
        self.result = result
    }

    var invocation: Invocation? {
        readInvocation()
    }

    func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: String,
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> GitHubCommandResult {
        storeInvocation(
            Invocation(
                executableURL: executableURL,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                timeout: timeout
            )
        )
        return result
    }

    private func readInvocation() -> Invocation? {
        lock.lock()
        defer { lock.unlock() }
        return storedInvocation
    }

    private func storeInvocation(_ invocation: Invocation) {
        lock.lock()
        storedInvocation = invocation
        lock.unlock()
    }
}

private final class PullRequestGitFixture {
    let temporaryDirectory: TestTemporaryDirectory
    let root: URL
    let repository: URL
    let origin: URL
    let projectID = UUID()
    let repositoryIdentity = RepositoryIdentity(
        provider: .github,
        host: "github.example",
        owner: "owner",
        repositoryName: "repo"
    )
    let baseCommit: String
    let pullRequestCommit: String

    init(pushHeadBranch: Bool = false) throws {
        temporaryDirectory = try TestTemporaryDirectory(prefix: "argus-pull-request")
        root = temporaryDirectory.url
        repository = root.appendingPathComponent("repository")
        origin = root.appendingPathComponent("origin.git")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

        try Self.run(["init", "--bare", origin.path], in: root)
        try Self.run(["init", "-b", "main", "."], in: repository)
        try Self.run(["config", "user.email", "test@example.com"], in: repository)
        try Self.run(["config", "user.name", "Test User"], in: repository)
        try "base".write(
            to: repository.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try Self.run(["add", "README.md"], in: repository)
        try Self.run(["commit", "-m", "base"], in: repository)
        baseCommit = try TestGit.run(["rev-parse", "HEAD"], in: repository)
        try Self.run(["remote", "add", "origin", "https://github.example/owner/repo.git"], in: repository)
        try Self.run(
            [
                "config",
                "url.\(origin.path).insteadOf",
                "https://github.example/owner/repo.git"
            ],
            in: repository
        )
        try Self.run(["push", "origin", "main"], in: repository)
        try Self.run(["checkout", "-b", "pr-source"], in: repository)
        try "pull-request".write(
            to: repository.appendingPathComponent("PR.md"),
            atomically: true,
            encoding: .utf8
        )
        try Self.run(["add", "PR.md"], in: repository)
        try Self.run(["commit", "-m", "pull request"], in: repository)
        pullRequestCommit = try TestGit.run(["rev-parse", "HEAD"], in: repository)
        let pushRefs =
            pushHeadBranch
            ? ["pr-source:refs/heads/feature/exact-head", "pr-source:refs/pull/42/head"]
            : ["pr-source:refs/pull/42/head"]
        for ref in pushRefs {
            try Self.run(["push", "origin", ref], in: repository)
        }
        try Self.run(["checkout", "main"], in: repository)
    }

    func metadata(
        headBranchName: String,
        headRepository: RepositoryIdentity?
    ) throws -> PullRequestWorkspaceMetadata {
        let pullRequestURL = URL(string: "https://github.example/owner/repo/pull/42")!
        return try PullRequestWorkspaceMetadata(
            pullRequest: PullRequestIdentity(repository: repositoryIdentity, number: 42),
            canonicalURL: pullRequestURL,
            title: "Pull Request title",
            baseRepository: repositoryIdentity,
            headRepository: headRepository,
            headBranchName: headBranchName,
            headCommitObjectID: pullRequestCommit,
            isCrossRepository: headRepository != repositoryIdentity
        )
    }

    func githubMetadataJSON(title: String) -> String {
        """
        {
          "number": 42,
          "title": "\(title)",
          "url": "https://github.example/owner/repo/pull/42",
          "headRefName": "feature/exact-head",
          "headRefOid": "\(pullRequestCommit)",
          "headRepository": null,
          "headRepositoryOwner": null,
          "isCrossRepository": false
        }
        """
    }

    func remove() {
        temporaryDirectory.remove()
    }

    private static func run(_ arguments: [String], in directory: URL) throws {
        _ = try TestGit.run(arguments, in: directory)
    }
}
