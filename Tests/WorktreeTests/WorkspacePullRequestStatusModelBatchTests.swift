import Foundation
import Testing

@testable import Argus

extension WorkspacePullRequestStatusModelTests {
    @Test
    func dueKnownPullRequestsAcrossProjectsCollapseIntoOneHostBatch() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 12, projectCount: 4)
        await fixture.load()
        let initial = await fixture.provider.calls.count
        #expect(await fixture.provider.calls.filter { $0.method == .batch }.map(\.identities.count) == [12])
        fixture.clock.advance(60)
        for target in fixture.targets.prefix(4) { fixture.model.refreshProject(projectID: target.projectID) }
        await fixture.model.waitForIdle()
        let calls = await fixture.provider.calls.dropFirst(initial)
        #expect(calls.map(\.method) == [.batch])
        #expect(calls.first?.identities.count == 12)
        #expect(Set(calls.first?.identities.map(\.repository) ?? []).count == 4)
        #expect(fixture.model.states.values.allSatisfy { $0.lastSuccess == fixture.clock.date && !$0.isRefreshing })
    }

    @Test
    func backgroundDiscoverySettlesBeforeItsSingleDetailedBatch() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 12, projectCount: 4)
        await fixture.load()
        let initial = await fixture.provider.calls.count
        fixture.clock.advance(600)
        await fixture.model.tick()
        let calls = await fixture.provider.calls.dropFirst(initial)
        #expect(calls.filter { $0.method == .resolve }.count == 4)
        #expect(calls.filter { $0.method == .discover }.count == 12)
        #expect(calls.filter { $0.method == .batch }.map(\.identities.count) == [12])
        #expect(calls.last?.method == .batch)
    }

    @Test
    func statusBatchesSeparateGitHubHostsAndCountRequestsRatherThanMembers() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 12, projectCount: 6, hostCount: 3)
        await fixture.load()
        let calls = await fixture.provider.calls.filter { $0.method == .batch }
        #expect(calls.count == 3)
        #expect(calls.allSatisfy { Set($0.identities.map(\.repository.host)).count == 1 && $0.identities.count == 4 })
        #expect(Set(calls.compactMap { $0.identities.first?.repository.host }).count == 3)
        #expect(await fixture.provider.maximumActiveCount <= 3)
        #expect(await fixture.provider.maximumBatchesPerHost.values.allSatisfy { $0 == 1 })
    }

    @Test
    func largeReadySetsSplitAtTwentyAndOnlyOneBatchPerHostRunsAtOnce() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 45, projectCount: 3)
        await fixture.provider.suspend([.batch])
        fixture.update()
        await fixture.provider.waitForCalls(49)
        #expect(await fixture.provider.calls.filter { $0.method == .batch }.map(\.identities.count) == [20])
        #expect(await fixture.provider.activeCount == 1)
        fixture.update()
        #expect(await fixture.provider.calls.count == 49)
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        let batches = await fixture.provider.calls.filter { $0.method == .batch }
        #expect(batches.map(\.identities.count) == [20, 20, 5])
        #expect(Set(batches.flatMap(\.identities)).count == 45)
        #expect(await fixture.provider.maximumActiveCount <= 3)
        #expect(await fixture.provider.maximumBatchesPerHost == ["github.example": 1])
        #expect(fixture.model.states.values.allSatisfy { $0.status != nil && !$0.isRefreshing })
    }

    @Test
    func duplicatePullRequestIdentitiesRetainSeparateWorkspaceOwnership() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2)
        await fixture.inputs.setBranch(
            PullRequestRuntimeFixture.branch("feature-0"), path: fixture.targets[1].worktreePath)
        await fixture.load()
        #expect(await fixture.provider.calls.filter { $0.method == .batch }.map(\.identities.count) == [1])
        #expect(fixture.model.states.count == 2)
        #expect(
            fixture.model.state(for: fixture.targets[0].workspaceID)?.status
                == fixture.model.state(for: fixture.targets[1].workspaceID)?.status)
        fixture.update(targets: [fixture.targets[1]])
        #expect(fixture.model.state(for: fixture.targets[0].workspaceID) == nil)
        #expect(fixture.model.state(for: fixture.targets[1].workspaceID)?.status != nil)
    }

    @Test
    func pendingDiscoveryJoinsTheAlreadyDueKnownPullRequestBatch() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 4)
        fixture.update(targets: Array(fixture.targets.prefix(3)))
        await fixture.model.waitForIdle()
        let initial = await fixture.provider.calls.count
        await fixture.provider.suspend([.discover])
        fixture.clock.advance(60)
        fixture.update(selected: fixture.targets[0].workspaceID)
        await fixture.provider.waitForCalls(initial + 1)
        #expect(await fixture.provider.calls.dropFirst(initial).map(\.method) == [.discover])
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        let calls = await fixture.provider.calls.dropFirst(initial)
        #expect(calls.map(\.method) == [.discover, .batch])
        #expect(calls.last?.identities.map(\.number) == [1, 4])
    }

    @Test
    func simultaneousManualRefreshesUseTheSameDiscoveryAndBatchPath() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 4, projectCount: 4)
        await fixture.load()
        let initial = await fixture.provider.calls.count
        fixture.clock.advance(1)
        for target in fixture.targets {
            fixture.model.refresh(workspaceID: target.workspaceID)
            fixture.model.refresh(workspaceID: target.workspaceID)
        }
        await fixture.model.waitForIdle()
        let calls = await fixture.provider.calls.dropFirst(initial)
        #expect(calls.filter { $0.method == .resolve }.count == 4)
        #expect(calls.filter { $0.method == .discover }.count == 4)
        #expect(calls.filter { $0.method == .batch }.map(\.identities.count) == [4])
        #expect(fixture.model.states.values.allSatisfy { $0.lastSuccess == fixture.clock.date && !$0.isRefreshing })
    }

    @Test
    func removingOneBatchMemberDoesNotCancelOrLoseItsHealthySibling() async throws {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2)
        await fixture.load()
        let first = fixture.targets[0]
        let second = fixture.targets[1]
        let previous = try #require(fixture.model.state(for: second.workspaceID)?.status)
        let merged = PullRequestRuntimeFixture.status(
            branch: previous.headBranchName, repository: previous.identity.repository, number: previous.identity.number,
            lifecycle: .merged)
        await fixture.provider.setRefresh(.success(merged), branch: previous.headBranchName)
        let initial = await fixture.provider.calls.count
        await fixture.provider.suspend([.batch])
        fixture.clock.advance(60)
        fixture.model.refreshProject(projectID: first.projectID)
        await fixture.provider.waitForCalls(initial + 1)
        #expect(await fixture.provider.calls.last?.identities.count == 2)
        fixture.update(targets: [second])
        fixture.clock.advance(10)
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: first.workspaceID) == nil)
        #expect(fixture.model.state(for: second.workspaceID)?.status == merged)
        #expect(fixture.model.state(for: second.workspaceID)?.lastSuccess == fixture.clock.date)
        #expect(await fixture.provider.cancelledCompletions.isEmpty)
        #expect(await fixture.provider.calls.count == initial + 1)
    }

    @Test
    func aBranchChangeDuringABatchPreservesOtherMembersResults() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2)
        await fixture.load()
        let first = fixture.targets[0]
        let second = fixture.targets[1]
        let initial = await fixture.provider.calls.count
        await fixture.provider.suspend([.batch, .discover])
        fixture.clock.advance(60)
        fixture.model.refreshProject(projectID: first.projectID)
        await fixture.provider.waitForCalls(initial + 1)
        await fixture.inputs.setBranch(PullRequestRuntimeFixture.branch("changed"), path: first.worktreePath)
        fixture.clock.advance(10)
        await fixture.provider.resume(initial)
        await fixture.provider.waitForCalls(initial + 2)
        #expect(fixture.model.state(for: first.workspaceID)?.status == nil)
        #expect(fixture.model.state(for: first.workspaceID)?.branchName == "changed")
        #expect(fixture.model.state(for: second.workspaceID)?.lastSuccess == fixture.clock.date)
        #expect(fixture.model.state(for: second.workspaceID)?.status?.headBranchName == "feature-1")
        #expect(await fixture.provider.cancelledCompletions.isEmpty)
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: first.workspaceID)?.status?.headBranchName == "changed")
    }

    @Test
    func unavailableBatchMembersDoNotDiscardOtherMembersStatus() async throws {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2)
        await fixture.load()
        let previous = try #require(fixture.model.state(for: fixture.targets[0].workspaceID))
        await fixture.provider.setRefresh(
            .failure(.invalidMetadata("Required fields unavailable")), branch: "feature-0")
        fixture.clock.advance(60)
        fixture.model.refreshProject(projectID: fixture.targets[0].projectID)
        await fixture.model.waitForIdle()
        let failed = fixture.model.state(for: fixture.targets[0].workspaceID)
        #expect(failed?.status == previous.status)
        #expect(failed?.lastSuccess == previous.lastSuccess)
        #expect(failed?.error == .invalidMetadata("Required fields unavailable"))
        #expect(fixture.model.state(for: fixture.targets[1].workspaceID)?.error == nil)
        #expect(fixture.model.state(for: fixture.targets[1].workspaceID)?.lastSuccess == fixture.clock.date)
    }
}
