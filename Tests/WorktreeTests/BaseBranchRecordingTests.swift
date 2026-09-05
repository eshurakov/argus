import Foundation
import Testing

@testable import Argus

@Suite
struct BaseBranchRecordingTests {
    @Test
    func recordedParentUsesTheSharedConfigurationKeyStackDiscoveryReads() async throws {
        let temporary = try TestTemporaryDirectory(prefix: "argus-base-branch-recording")
        defer { temporary.remove() }
        let repository = temporary.url.resolvingSymlinksInPath()
            .appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try TestGit.run(["init", "-b", "main", "."], in: repository)
        try TestGit.run(
            [
                "-c", "user.name=Test User", "-c", "user.email=test@example.com",
                "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                "commit", "--allow-empty", "-m", "initial"
            ], in: repository)
        let service = WorktreeService(
            worktreeBaseURL: temporary.url.appendingPathComponent("managed", isDirectory: true))

        try await service.recordBaseBranch("main", forBranch: "feature/api", repositoryPath: repository.path)

        let recorded = try TestGit.run(
            ["config", "--get", RecordedBaseBranchConfiguration.key(for: "feature/api")], in: repository)
        #expect(recorded == "main")
        #expect(RecordedBaseBranchConfiguration.key(for: "feature/api") == "branch.feature/api.base")
        #expect(RecordedBaseBranchConfiguration.branchName(forKey: "branch.feature/api.base") == "feature/api")
        #expect(RecordedBaseBranchConfiguration.branchName(forKey: "branch..base") == nil)
        #expect(RecordedBaseBranchConfiguration.branchName(forKey: "remote.origin.url") == nil)
    }

    @Test
    func invalidRecordingRequestsAreRejectedBeforeTouchingGit() async throws {
        let temporary = try TestTemporaryDirectory(prefix: "argus-base-branch-rejection")
        defer { temporary.remove() }
        let service = WorktreeService(
            worktreeBaseURL: temporary.url.appendingPathComponent("managed", isDirectory: true))

        for (branch, base) in [("feature/api", "feature/api"), ("feature api", "main"), ("feature/api", "-main")] {
            await #expect(throws: WorktreeError.self) {
                try await service.recordBaseBranch(base, forBranch: branch, repositoryPath: temporary.url.path)
            }
        }
    }

    @Test
    func aNewBranchStartsFromItsRequestedStartPoint() async throws {
        let temporary = try TestTemporaryDirectory(prefix: "argus-worktree-start-point")
        defer { temporary.remove() }
        let repository = temporary.url.resolvingSymlinksInPath()
            .appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try TestGit.run(["init", "-b", "main", "."], in: repository)
        let commit = [
            "-c", "user.name=Test User", "-c", "user.email=test@example.com",
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty"
        ]
        try TestGit.run(commit + ["-m", "initial"], in: repository)
        try TestGit.run(["branch", "feature/parent"], in: repository)
        try TestGit.run(["checkout", "feature/parent"], in: repository)
        try TestGit.run(commit + ["-m", "parent work"], in: repository)
        try TestGit.run(["checkout", "main"], in: repository)
        let parentTip = try TestGit.run(["rev-parse", "feature/parent"], in: repository)
        let service = WorktreeService(
            worktreeBaseURL: temporary.url.appendingPathComponent("managed", isDirectory: true))

        let path = try await service.createWorktree(
            projectId: UUID(),
            repositoryPath: repository.path,
            branchName: "feature/child",
            createNewBranch: true,
            startPoint: "feature/parent"
        )

        #expect(try TestGit.run(["rev-parse", "HEAD"], in: URL(fileURLWithPath: path)) == parentTip)
        #expect(try TestGit.run(["rev-parse", "main"], in: repository) != parentTip)
    }
}
