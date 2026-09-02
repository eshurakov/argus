import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct WorkspacePullRequestStatusBatchTests {
    @Test
    func combinesReadyPullRequestsAcrossRepositoriesOnOneHost() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 6, projectCount: 3)
        await fixture.load(selected: fixture.targets[0].workspaceID)
        let batches = await fixture.provider.calls.filter { $0.method == .batch }
        #expect(batches.count == 1)
        #expect(batches.first?.identities.count == 6)
        #expect(Set(batches.flatMap(\.identities).map(\.repository)).count == 3)
        #expect(fixture.model.states.values.allSatisfy { $0.status != nil && $0.error == nil && !$0.isRefreshing })
        #expect(await fixture.provider.maximumActiveCount <= 3)
    }

    @Test
    func splitsLargeSetsWithoutOverlappingBatchesOnTheSameHost() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 45, projectCount: 3)
        await fixture.load()
        let batches = await fixture.provider.calls.filter { $0.method == .batch }
        #expect(batches.map(\.identities.count) == [20, 20, 5])
        #expect(Set(batches.flatMap(\.identities)).count == 45)
        #expect(await fixture.provider.maximumBatchesPerHost["github.example"] == 1)
        #expect(await fixture.provider.maximumActiveCount <= 3)
        #expect(fixture.model.states.values.allSatisfy { $0.status != nil && !$0.isRefreshing })
    }

    @Test
    func sendsSeparateBatchesToDifferentHosts() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 4, projectCount: 2, hostCount: 2)
        await fixture.load()
        let batches = await fixture.provider.calls.filter { $0.method == .batch }
        #expect(batches.count == 2)
        #expect(batches.allSatisfy { $0.identities.count == 2 })
        #expect(batches.allSatisfy { Set($0.identities.map(\.repository.host)).count == 1 })
        #expect(Set(batches.flatMap(\.identities).map(\.repository.host)).count == 2)
    }

    @Test
    func duplicateAssociationsShareOneProviderReadAndKeepBothOwners() async throws {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2)
        let repository = try #require(await fixture.provider.repositories[fixture.targets[0].repositoryPath])
        let status = PullRequestRuntimeFixture.status(branch: "shared", repository: repository, number: 42)
        for target in fixture.targets {
            await fixture.inputs.setBranch(PullRequestRuntimeFixture.branch("shared"), path: target.worktreePath)
        }
        await fixture.provider.setDiscovery(.success(status), branch: "shared")
        await fixture.load()
        let batches = await fixture.provider.calls.filter { $0.method == .batch }
        #expect(batches.map(\.identities) == [[status.identity]])
        #expect(fixture.model.states.count == 2)
        #expect(fixture.model.states.values.allSatisfy { $0.status == status && $0.error == nil })
    }

    @Test(arguments: [(1, 100, true), (1, 101, false), (120, 120, true), (120, 122, false)])
    func reservesQuotaForTheUserAndAtLeastAnotherBatch(cost: Int, remaining: Int, paused: Bool) async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 3)
        let reset = fixture.clock.date.addingTimeInterval(3_600)
        await fixture.provider.setQuota(PullRequestStatusQuota(cost: cost, remaining: remaining, resetAt: reset))
        await fixture.load()
        #expect(fixture.model.states.values.allSatisfy { $0.status != nil && !$0.isRefreshing })
        for state in fixture.model.states.values {
            #expect(state.error == (paused ? .quotaPaused(until: reset) : nil))
        }
    }

    @Test
    func hostPauseBlocksManualAndAutomaticRefreshAcrossLifecycleTransitionsUntilReset() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 4, projectCount: 2)
        let reset = fixture.clock.date.addingTimeInterval(120)
        await fixture.provider.setQuota(PullRequestStatusQuota(cost: 1, remaining: 90, resetAt: reset))
        await fixture.load()
        let count = await fixture.provider.calls.count
        for target in fixture.targets {
            fixture.model.refresh(workspaceID: target.workspaceID)
            fixture.model.refreshProject(projectID: target.projectID)
        }
        fixture.update(active: false)
        fixture.update()
        fixture.update(enabled: false)
        fixture.update()
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.calls.count == count)
        #expect(fixture.model.states.values.allSatisfy { $0.error == .quotaPaused(until: reset) && !$0.isRefreshing })
        fixture.clock.advance(119)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == count)
        await fixture.provider.setQuota(
            PullRequestStatusQuota(cost: 1, remaining: 4_999, resetAt: reset.addingTimeInterval(3_600)))
        fixture.clock.advance(1)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count > count)
        #expect(fixture.model.states.values.allSatisfy { $0.status != nil && $0.error == nil && !$0.isRefreshing })
    }

    @Test
    func quotaPauseSurvivesReplacingTheRuntimeModel() async {
        let budgets = PullRequestStatusHostBudgetStore()
        let first = PullRequestRuntimeFixture(hostBudgets: budgets)
        let reset = first.clock.date.addingTimeInterval(600)
        await first.provider.setQuota(PullRequestStatusQuota(cost: 1, remaining: 50, resetAt: reset))
        await first.load()
        first.model.stop()
        let second = PullRequestRuntimeFixture(hostBudgets: budgets)
        await second.load()
        #expect(await second.provider.calls.isEmpty)
        #expect(second.model.states.values.allSatisfy { $0.error == .quotaPaused(until: reset) && !$0.isRefreshing })
    }

    @Test
    func oneHostsQuotaPauseDoesNotBlockAnotherVerifiedHost() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 4, projectCount: 2, hostCount: 2)
        let reset = fixture.clock.date.addingTimeInterval(600)
        await fixture.provider.setQuota(PullRequestStatusQuota(cost: 1, remaining: 50, resetAt: reset))
        await fixture.load()
        let before = await fixture.provider.calls.filter { $0.method == .batch }
        fixture.model.refresh(workspaceID: fixture.targets[1].workspaceID)
        await fixture.model.waitForIdle()
        let after = await fixture.provider.calls.filter { $0.method == .batch }
        #expect(after.count == before.count + 1)
        #expect(after.last?.identities.first?.repository.host == "github-1.example")
        for index in [0, 2] {
            #expect(fixture.model.state(for: fixture.targets[index].workspaceID)?.error == .quotaPaused(until: reset))
        }
        for index in [1, 3] {
            #expect(fixture.model.state(for: fixture.targets[index].workspaceID)?.error == nil)
        }
    }

    @Test
    func partialResultFailureKeepsUnrelatedPullRequestsFresh() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2)
        await fixture.load()
        let error = PullRequestStatusError.invalidMetadata("This Pull Request is inaccessible.")
        await fixture.provider.setRefresh(.failure(error), branch: "feature-0")
        fixture.clock.advance(60)
        fixture.model.refreshProject(projectID: fixture.targets[0].projectID)
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: fixture.targets[0].workspaceID)?.error == error)
        let healthy = fixture.model.state(for: fixture.targets[1].workspaceID)
        #expect(healthy?.error == nil)
        #expect(healthy?.lastSuccess == fixture.clock.date)
        #expect(healthy?.isRefreshing == false)
        #expect(await fixture.provider.calls.last?.identities.count == 2)
    }

    @Test
    func removingOneMemberDoesNotCancelOtherMembersOfTheBatch() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 3)
        await fixture.load()
        let initial = await fixture.provider.calls.count
        await fixture.provider.suspend([.batch])
        fixture.clock.advance(60)
        fixture.model.refreshProject(projectID: fixture.targets[0].projectID)
        await fixture.provider.waitForCalls(initial + 1)
        fixture.update(targets: Array(fixture.targets.dropFirst()))
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: fixture.targets[0].workspaceID) == nil)
        for target in fixture.targets.dropFirst() {
            #expect(fixture.model.state(for: target.workspaceID)?.lastSuccess == fixture.clock.date)
            #expect(fixture.model.state(for: target.workspaceID)?.error == nil)
        }
        #expect(await fixture.provider.cancelledCompletions.isEmpty)
    }

    @Test
    func aBranchChangeDuringTheBatchDoesNotDiscardAHealthySibling() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2)
        await fixture.load()
        let sibling = fixture.model.state(for: fixture.targets[1].workspaceID)?.status
        let initial = await fixture.provider.calls.count
        await fixture.provider.suspend([.batch])
        fixture.clock.advance(60)
        fixture.model.refreshProject(projectID: fixture.targets[0].projectID)
        await fixture.provider.waitForCalls(initial + 1)
        await fixture.inputs.setBranch(
            PullRequestRuntimeFixture.branch("changed"), path: fixture.targets[0].worktreePath)
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: fixture.targets[0].workspaceID)?.status?.headBranchName == "changed")
        #expect(fixture.model.state(for: fixture.targets[1].workspaceID)?.status == sibling)
        #expect(fixture.model.state(for: fixture.targets[1].workspaceID)?.lastSuccess == fixture.clock.date)
        #expect(fixture.model.states.values.allSatisfy { $0.error == nil && !$0.isRefreshing })
    }

    @Test
    func secondaryLimitsBackOffFromOneMinuteAndManualCannotBypassThem() async {
        let fixture = PullRequestRuntimeFixture()
        await fixture.provider.setBatchError(.secondaryRateLimited(retryAfter: nil))
        await fixture.load()
        let firstDeadline = fixture.clock.date.addingTimeInterval(60)
        #expect(fixture.model.states.values.first?.error == .secondaryRateLimited(retryAfter: firstDeadline))
        let count = await fixture.provider.calls.count
        fixture.clock.advance(59)
        fixture.model.refresh(workspaceID: fixture.targets[0].workspaceID)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == count)
        fixture.clock.advance(1)
        await fixture.model.tick()
        #expect(
            fixture.model.states.values.first?.error
                == .secondaryRateLimited(retryAfter: fixture.clock.date.addingTimeInterval(120)))
        await fixture.provider.setBatchError(nil)
        fixture.clock.advance(120)
        await fixture.model.tick()
        #expect(fixture.model.states.values.first?.error == nil)
        #expect(fixture.model.states.values.first?.status != nil)
    }

    @Test
    func primaryLimitWithoutResetUsesAConservativeHourPause() async {
        let fixture = PullRequestRuntimeFixture()
        await fixture.provider.setBatchError(.rateLimited(retryAfter: nil))
        await fixture.load()
        #expect(
            fixture.model.states.values.first?.error
                == .rateLimited(retryAfter: fixture.clock.date.addingTimeInterval(3_600)))
        let count = await fixture.provider.calls.count
        fixture.clock.advance(3_599)
        fixture.model.refresh(workspaceID: fixture.targets[0].workspaceID)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == count)
    }
}
