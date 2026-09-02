import Foundation
import Testing

@testable import Argus

extension WorkspacePullRequestStatusModelTests {
    @Test
    func normalizedPathsDoNotChurnStateButChangedPathsRebindTheWorkspace() async {
        let fixture = PullRequestRuntimeFixture()
        let original = fixture.targets[0]
        await fixture.load()
        let initial = await fixture.provider.calls.count
        let normalized = WorkspacePullRequestTarget(
            workspaceID: original.workspaceID, projectID: original.projectID,
            repositoryPath: "/projects/./project-0/", worktreePath: "/worktrees/./feature-0/"
        )
        #expect(normalized == original)
        fixture.update(targets: [normalized])
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.calls.count == initial)
        let changed = WorkspacePullRequestTarget(
            workspaceID: original.workspaceID, projectID: original.projectID,
            repositoryPath: original.repositoryPath, worktreePath: "/worktrees/rebound"
        )
        await fixture.inputs.setBranch(PullRequestRuntimeFixture.branch("rebound"), path: changed.worktreePath)
        fixture.update(targets: [changed])
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: original.workspaceID)?.status?.headBranchName == "rebound")
        #expect(await fixture.provider.calls.last { $0.method == .discover }?.previous == nil)
    }

    @Test
    func manualRefreshRechecksTheDefaultRepositoryAndKeepsOtherProjectsIsolated() async throws {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 3, projectCount: 2)
        let first = fixture.targets[0]
        let other = fixture.targets[1]
        let repository = RepositoryIdentity(
            provider: .github, host: "github.example", owner: "alternate", repositoryName: "repo")
        let originalRemotes = await fixture.inputs.fetchRemotes[first.repositoryPath] ?? []
        await fixture.inputs.setRemotes(
            originalRemotes + [
                GitFetchRemote(name: "alternate", fetchURLs: PullRequestRuntimeFixture.remotes(repository)[0].fetchURLs)
            ],
            path: first.repositoryPath
        )
        await fixture.load()
        let untouched = try #require(fixture.model.state(for: other.workspaceID))
        await fixture.provider.setRepository(repository, path: first.repositoryPath)
        fixture.model.refresh(workspaceID: first.workspaceID)
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: first.workspaceID)?.status?.identity.repository == repository)
        #expect(fixture.model.state(for: fixture.targets[2].workspaceID)?.status?.identity.repository == repository)
        #expect(fixture.model.state(for: other.workspaceID) == untouched)
        let calls = await fixture.provider.calls
        #expect(calls.filter { $0.repositoryPath == other.repositoryPath && $0.method == .resolve }.count == 1)
        #expect(
            calls.filter { $0.repository == repository && $0.method == .discover }.allSatisfy { $0.previous == nil })
    }

    @Test
    func changedFetchURLsDuringARequestInvalidateItsRepositoryAndAssociation() async {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.load(selected: target.workspaceID)
        let initial = await fixture.provider.calls.count
        await fixture.provider.suspend([.batch, .discover])
        fixture.clock.advance(60)
        fixture.update(selected: target.workspaceID)
        await fixture.provider.waitForCalls(initial + 1)
        let repository = RepositoryIdentity(
            provider: .github, host: "github.example", owner: "moved", repositoryName: "repo")
        await fixture.inputs.setRemotes(PullRequestRuntimeFixture.remotes(repository), path: target.repositoryPath)
        await fixture.provider.setRepository(repository, path: target.repositoryPath)
        await fixture.provider.resume(initial)
        await fixture.provider.waitForCalls(initial + 3)
        #expect(fixture.model.state(for: target.workspaceID)?.status == nil)
        #expect(await fixture.provider.calls.last?.previous == nil)
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: target.workspaceID)?.status?.identity.repository == repository)
    }

    @Test
    func unrelatedRemoteChangeRetainsLocallyAdvancedForkAssociationWhileRevalidating() async throws {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        let repository = try #require(await fixture.provider.repositories[target.repositoryPath])
        let fork = RepositoryIdentity(provider: .github, host: repository.host, owner: "fork", repositoryName: "repo")
        let status = PullRequestStatus(
            identity: PullRequestIdentity(repository: repository, number: 1),
            url: URL(string: "https://github.example/owner-0/repo/pull/1")!, title: "Fork Pull Request",
            headBranchName: "feature-0", headCommitObjectID: String(repeating: "a", count: 40),
            headRepository: fork, baseBranchName: "main", lifecycle: .open, review: .required,
            checks: PullRequestChecks(pending: 1)
        )
        await fixture.provider.setDiscovery(.success(status), branch: "feature-0")
        await fixture.load(selected: target.workspaceID)
        let initial = await fixture.provider.calls.count
        let lastSuccess = fixture.clock.date
        await fixture.inputs.setBranch(
            PullRequestRuntimeFixture.branch("feature-0", head: String(repeating: "b", count: 40)),
            path: target.worktreePath)
        await fixture.inputs.setRemotes(
            PullRequestRuntimeFixture.remotes(repository)
                + [GitFetchRemote(name: "unrelated", fetchURLs: ["https://github.example/unrelated/repo.git"])],
            path: target.repositoryPath)
        await fixture.provider.suspend([.resolve])
        fixture.clock.advance(60)
        fixture.update(selected: target.workspaceID)
        await fixture.provider.waitForCalls(initial + 1)
        let revalidating = fixture.model.state(for: target.workspaceID)
        #expect(revalidating?.status == status)
        #expect(revalidating?.lastSuccess == lastSuccess)
        #expect(revalidating?.isStale(at: fixture.clock.date) == true)
        #expect(revalidating?.isRefreshing == true)
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.calls.last { $0.method == .discover }?.previous == status)
        #expect(fixture.model.state(for: target.workspaceID)?.status == status)
        #expect(fixture.model.state(for: target.workspaceID)?.error == nil)
    }

    @Test
    func failedRepositoryRevalidationPreservesThePreviousAssociationAsStale() async throws {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.load(selected: target.workspaceID)
        let previous = try #require(fixture.model.state(for: target.workspaceID)?.status)
        await fixture.inputs.setRemotes(
            PullRequestRuntimeFixture.remotes(previous.identity.repository)
                + [GitFetchRemote(name: "unrelated", fetchURLs: ["https://github.example/unrelated/repo.git"])],
            path: target.repositoryPath)
        await fixture.provider.setResolutionError(.unauthenticated, path: target.repositoryPath)
        fixture.clock.advance(60)
        await fixture.model.tick()
        #expect(fixture.model.state(for: target.workspaceID)?.status == previous)
        #expect(fixture.model.state(for: target.workspaceID)?.error == .unauthenticated)
        #expect(fixture.model.state(for: target.workspaceID)?.isStale(at: fixture.clock.date) == true)
        await fixture.provider.setResolutionError(nil, path: target.repositoryPath)
        fixture.model.refresh(workspaceID: target.workspaceID)
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.calls.last { $0.method == .discover }?.previous == previous)
        #expect(fixture.model.state(for: target.workspaceID)?.error == nil)
    }

    @Test
    func upstreamRepositoryChangeDoesNotRetainAnUnverifiedOldAssociation() async {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.load()
        let upstream = RepositoryIdentity(
            provider: .github, host: "github.example", owner: "fork", repositoryName: "repo")
        await fixture.inputs.setBranch(
            PullRequestRuntimeFixture.branch("feature-0", upstream: upstream), path: target.worktreePath)
        await fixture.provider.setDiscovery(.failure(.unverifiedAssociation), branch: "feature-0")
        fixture.model.refreshProject(projectID: target.projectID)
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: target.workspaceID)?.status == nil)
        #expect(fixture.model.state(for: target.workspaceID)?.error == .unverifiedAssociation)
        #expect(await fixture.provider.calls.last?.branch?.upstreamRepository == upstream)
        #expect(await fixture.provider.calls.last?.previous == nil)
    }

    @Test
    func localReadCompletionAlsoValidatesWorkspaceGeneration() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2)
        await fixture.inputs.suspendReads()
        fixture.update()
        await fixture.inputs.waitForRead()
        fixture.update(targets: [fixture.targets[1]])
        let target = fixture.targets[0]
        await fixture.inputs.setBranch(PullRequestRuntimeFixture.branch("readded"), path: target.worktreePath)
        fixture.update()
        await fixture.inputs.resumeReads()
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: target.workspaceID)?.status?.headBranchName == "readded")
        #expect(await fixture.provider.calls.filter { $0.branch?.branchName == "feature-0" }.isEmpty)
    }

    @Test
    func foregroundInvalidatesRepositoryCacheEvenWhenTheCachedStatusIsRecent() async {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.load(selected: target.workspaceID)
        let initial = await fixture.provider.calls.count
        fixture.update(selected: target.workspaceID, active: false)
        fixture.clock.advance(1)
        fixture.update(selected: target.workspaceID)
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.calls.count == initial)
        fixture.clock.advance(59)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.suffix(2).map(\.method) == [.resolve, .batch])
    }
}
