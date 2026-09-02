import Foundation
import Testing

@testable import Argus

extension WorkspacePullRequestStatusModelTests {
    @Test(arguments: [(1, 100, true), (1, 101, false), (150, 151, true), (150, 152, false)])
    func quotaReservesOneHundredPointsOrMoreThanTheBatchCost(cost: Int, remaining: Int, paused: Bool) async {
        let fixture = PullRequestRuntimeFixture()
        let deadline = fixture.clock.date.addingTimeInterval(90)
        await fixture.provider.setQuota(PullRequestStatusQuota(cost: cost, remaining: remaining, resetAt: deadline))
        await fixture.load()
        let state = fixture.model.state(for: fixture.targets[0].workspaceID)
        #expect(state?.status != nil)
        #expect(state?.lastSuccess == fixture.clock.date)
        #expect(state?.error == (paused ? .quotaPaused(until: deadline) : nil))
        #expect(state?.isRefreshing == false)
    }

    @Test
    func manualAndAutomaticTrafficCannotBypassLowQuotaUntilReset() async throws {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 3, projectCount: 3)
        let deadline = fixture.clock.date.addingTimeInterval(90)
        await fixture.provider.setQuota(PullRequestStatusQuota(cost: 1, remaining: 100, resetAt: deadline))
        await fixture.load(selected: fixture.targets[0].workspaceID)
        let initial = await fixture.provider.calls.count
        let previous = try #require(fixture.model.state(for: fixture.targets[0].workspaceID))
        fixture.clock.advance(89)
        for target in fixture.targets { fixture.model.refresh(workspaceID: target.workspaceID) }
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == initial)
        #expect(
            fixture.model.states.values.allSatisfy { $0.error == .quotaPaused(until: deadline) && !$0.isRefreshing })
        #expect(fixture.model.state(for: fixture.targets[0].workspaceID)?.lastSuccess == previous.lastSuccess)
        await fixture.provider.setQuota(
            PullRequestStatusQuota(cost: 1, remaining: 4_000, resetAt: deadline.addingTimeInterval(3_600)))
        fixture.clock.advance(1)
        fixture.model.refresh(workspaceID: fixture.targets[0].workspaceID)
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.calls.suffix(3).map(\.method) == [.resolve, .discover, .batch])
        #expect(fixture.model.state(for: fixture.targets[0].workspaceID)?.error == nil)
        #expect(fixture.model.state(for: fixture.targets[0].workspaceID)?.lastSuccess == fixture.clock.date)
    }

    @Test
    func aHostPauseDoesNotBlockValidatedProjectsOnOtherHosts() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 4, projectCount: 4, hostCount: 2)
        let deadline = fixture.clock.date.addingTimeInterval(600)
        await fixture.provider.setQuota(PullRequestStatusQuota(cost: 1, remaining: 0, resetAt: deadline))
        await fixture.load()
        let initial = await fixture.provider.calls.count
        fixture.model.refresh(workspaceID: fixture.targets[0].workspaceID)
        fixture.model.refresh(workspaceID: fixture.targets[1].workspaceID)
        await fixture.model.waitForIdle()
        let calls = await fixture.provider.calls.dropFirst(initial)
        #expect(calls.map(\.method) == [.resolve, .discover, .batch])
        #expect(calls.last?.identities.first?.repository.host == "github-1.example")
        for index in [0, 2] {
            #expect(
                fixture.model.state(for: fixture.targets[index].workspaceID)?.error == .quotaPaused(until: deadline))
            #expect(fixture.model.state(for: fixture.targets[index].workspaceID)?.isRefreshing == false)
        }
        for index in [1, 3] { #expect(fixture.model.state(for: fixture.targets[index].workspaceID)?.error == nil) }
    }

    @Test
    func aLowQuotaBatchStopsLaterChunksAndQueuedWorkDoesNotSpin() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 25)
        let deadline = fixture.clock.date.addingTimeInterval(90)
        await fixture.provider.setQuota(PullRequestStatusQuota(cost: 1, remaining: 50, resetAt: deadline))
        await fixture.load()
        #expect(await fixture.provider.calls.filter { $0.method == .batch }.map(\.identities.count) == [20])
        #expect(fixture.model.states.values.filter { $0.status != nil }.count == 20)
        #expect(
            fixture.model.states.values.allSatisfy { $0.error == .quotaPaused(until: deadline) && !$0.isRefreshing })
        let initial = await fixture.provider.calls.count
        for target in fixture.targets { fixture.model.refresh(workspaceID: target.workspaceID) }
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == initial)
        await fixture.provider.setQuota(
            PullRequestStatusQuota(cost: 1, remaining: 4_000, resetAt: deadline.addingTimeInterval(3_600)))
        fixture.clock.advance(90)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.filter { $0.method == .batch }.map(\.identities.count) == [20, 5])
        #expect(fixture.model.states.values.allSatisfy { $0.status != nil && !$0.isRefreshing })
        #expect(await fixture.provider.maximumBatchesPerHost == ["github.example": 1])
    }

    @Test
    func featureTogglesAndRuntimeReplacementRetainTheProcessLifetimeHostBudget() async {
        let store = PullRequestStatusHostBudgetStore()
        let fixture = PullRequestRuntimeFixture(hostBudgets: store)
        let deadline = fixture.clock.date.addingTimeInterval(600)
        await fixture.provider.setQuota(PullRequestStatusQuota(cost: 1, remaining: 5, resetAt: deadline))
        await fixture.load()
        let initial = await fixture.provider.calls.count
        fixture.update(active: false)
        fixture.update()
        fixture.update(enabled: false)
        #expect(fixture.model.states.isEmpty)
        fixture.update()
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.calls.count == initial)
        #expect(fixture.model.state(for: fixture.targets[0].workspaceID)?.error == .quotaPaused(until: deadline))
        let replacement = PullRequestRuntimeFixture(hostBudgets: store)
        await replacement.load()
        #expect(await replacement.provider.calls.isEmpty)
        #expect(
            replacement.model.state(for: replacement.targets[0].workspaceID)?.error == .quotaPaused(until: deadline))
    }

    @Test
    func unresolvedProjectsCannotProbeAroundAKnownHostPause() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2, projectCount: 2)
        let deadline = fixture.clock.date.addingTimeInterval(600)
        await fixture.provider.setQuota(PullRequestStatusQuota(cost: 1, remaining: 0, resetAt: deadline))
        fixture.update(targets: [fixture.targets[0]])
        await fixture.model.waitForIdle()
        let initial = await fixture.provider.calls.count
        fixture.update()
        for _ in 0..<3 { fixture.model.refresh(workspaceID: fixture.targets[1].workspaceID) }
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == initial)
        #expect(fixture.hostBudgets.repositories[fixture.targets[1].repositoryPath] == nil)
        #expect(fixture.model.state(for: fixture.targets[1].workspaceID)?.error == .quotaPaused(until: deadline))
        #expect(fixture.model.state(for: fixture.targets[1].workspaceID)?.isRefreshing == false)
    }

    @Test
    func rateLimitingBeforeRepositoryResolutionAlsoPreventsRepeatedUnknownHostProbes() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2, projectCount: 2)
        for target in fixture.targets {
            await fixture.provider.setResolutionError(
                .secondaryRateLimited(retryAfter: nil), path: target.repositoryPath)
        }
        await fixture.load()
        #expect(await fixture.provider.calls.count == 1)
        fixture.clock.advance(59)
        for target in fixture.targets { fixture.model.refresh(workspaceID: target.workspaceID) }
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == 1)
        #expect(fixture.model.states.values.allSatisfy { !$0.isRefreshing && $0.error?.pauseDeadline != nil })
        for target in fixture.targets {
            await fixture.provider.setResolutionError(nil, path: target.repositoryPath)
        }
        fixture.clock.advance(1)
        await fixture.model.tick()
        #expect(fixture.model.states.values.allSatisfy { $0.status != nil && $0.error == nil })
    }

    @Test
    func secondaryLimitsWithoutDeadlinesBackOffAtLeast60Then120Then240Seconds() async {
        let fixture = PullRequestRuntimeFixture()
        let id = fixture.targets[0].workspaceID
        await fixture.provider.setBatchError(.secondaryRateLimited(retryAfter: nil))
        await fixture.load(selected: id)
        var initial = await fixture.provider.calls.count
        for delay: TimeInterval in [60, 120] {
            #expect(fixture.model.state(for: id)?.error?.pauseDeadline == fixture.clock.date.addingTimeInterval(delay))
            fixture.clock.advance(delay - 1)
            fixture.model.refresh(workspaceID: id)
            await fixture.model.tick()
            #expect(await fixture.provider.calls.count == initial)
            fixture.clock.advance(1)
            await fixture.model.tick()
            #expect(await fixture.provider.calls.count > initial)
            initial = await fixture.provider.calls.count
        }
        #expect(fixture.model.state(for: id)?.error?.pauseDeadline == fixture.clock.date.addingTimeInterval(240))
        await fixture.provider.setBatchError(nil)
        fixture.clock.advance(240)
        await fixture.model.tick()
        #expect(fixture.model.state(for: id)?.status != nil)
        #expect(fixture.model.state(for: id)?.error == nil)
    }

    @Test
    func primaryLimitsWithoutDeadlinesPauseForAnHour() async {
        let fixture = PullRequestRuntimeFixture()
        let id = fixture.targets[0].workspaceID
        await fixture.provider.setBatchError(.rateLimited(retryAfter: nil))
        await fixture.load(selected: id)
        let initial = await fixture.provider.calls.count
        #expect(fixture.model.state(for: id)?.error?.pauseDeadline == fixture.clock.date.addingTimeInterval(3_600))
        fixture.clock.advance(3_599)
        fixture.model.refresh(workspaceID: id)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == initial)
        await fixture.provider.setBatchError(nil)
        fixture.clock.advance(1)
        await fixture.model.tick()
        #expect(fixture.model.state(for: id)?.error == nil)
        #expect(fixture.model.state(for: id)?.status != nil)
    }

    @Test
    func explicitRetryAfterRemainsAFloorEvenWhenQuotaResetsEarlier() async {
        let fixture = PullRequestRuntimeFixture()
        let id = fixture.targets[0].workspaceID
        let reset = fixture.clock.date.addingTimeInterval(90)
        let retry = fixture.clock.date.addingTimeInterval(120)
        await fixture.provider.setQuota(
            PullRequestStatusQuota(cost: 1, remaining: 100, resetAt: reset), retryAfter: retry)
        await fixture.load(selected: id)
        let initial = await fixture.provider.calls.count
        #expect(fixture.model.state(for: id)?.error?.pauseDeadline == retry)
        fixture.clock.advance(90)
        fixture.model.refresh(workspaceID: id)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == initial)
        await fixture.provider.setQuota(
            PullRequestStatusQuota(cost: 1, remaining: 4_000, resetAt: reset.addingTimeInterval(3_600)))
        fixture.clock.advance(30)
        await fixture.model.tick()
        #expect(fixture.model.state(for: id)?.error == nil)
    }

    @Test
    func anOlderHealthyBatchResponseCannotClearANewerHostRateLimit() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2)
        let first = fixture.targets[0]
        let second = fixture.targets[1]
        fixture.update(targets: [first], selected: first.workspaceID)
        await fixture.model.waitForIdle()
        let initial = await fixture.provider.calls.count
        await fixture.provider.suspend([.batch])
        fixture.clock.advance(60)
        fixture.update(targets: [first], selected: first.workspaceID)
        await fixture.provider.waitForCalls(initial + 1)
        let deadline = fixture.clock.date.addingTimeInterval(120)
        await fixture.provider.setDiscovery(.failure(.rateLimited(retryAfter: deadline)), branch: "feature-1")
        fixture.update(selected: first.workspaceID)
        await fixture.provider.waitForCalls(initial + 2)
        await fixture.model.running[second.workspaceID]?.task?.value
        #expect(fixture.model.state(for: first.workspaceID)?.error?.pauseDeadline == deadline)
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: first.workspaceID)?.lastSuccess == fixture.clock.date)
        #expect(fixture.model.state(for: first.workspaceID)?.error?.pauseDeadline == deadline)
        #expect(fixture.model.state(for: second.workspaceID)?.error?.pauseDeadline == deadline)
        fixture.model.refresh(workspaceID: first.workspaceID)
        #expect(await fixture.provider.calls.count == initial + 2)
    }

    @Test
    func aCancelledLateResponseStillRecordsQuotaBeforeReenable() async {
        let fixture = PullRequestRuntimeFixture()
        let id = fixture.targets[0].workspaceID
        await fixture.load(selected: id)
        let initial = await fixture.provider.calls.count
        let deadline = fixture.clock.date.addingTimeInterval(600)
        await fixture.provider.setQuota(PullRequestStatusQuota(cost: 1, remaining: 20, resetAt: deadline))
        await fixture.provider.suspend([.batch])
        fixture.clock.advance(60)
        fixture.update(selected: id)
        await fixture.provider.waitForCalls(initial + 1)
        fixture.update(enabled: false)
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(fixture.model.states.isEmpty)
        fixture.update(selected: id)
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.calls.count == initial + 1)
        #expect(fixture.model.state(for: id)?.error == .quotaPaused(until: deadline))
        #expect(fixture.model.state(for: id)?.status == nil)
    }

    @Test
    func aQuotaResponseArrivingAfterItsResetDoesNotCreateANewPause() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 25)
        await fixture.provider.setQuota(
            PullRequestStatusQuota(cost: 1, remaining: 0, resetAt: fixture.clock.date.addingTimeInterval(30)))
        await fixture.provider.suspend([.batch])
        fixture.update()
        await fixture.provider.waitForCalls(27)
        fixture.clock.advance(31)
        await fixture.provider.setQuota(
            PullRequestStatusQuota(cost: 1, remaining: 4_000, resetAt: fixture.clock.date.addingTimeInterval(3_600)))
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.calls.filter { $0.method == .batch }.map(\.identities.count) == [20, 5])
        #expect(fixture.model.states.values.allSatisfy { $0.status != nil && $0.error == nil && !$0.isRefreshing })
    }

    @Test
    func authenticationFailuresBackOffTheHostButPermitExplicitRecovery() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 3, projectCount: 3, hostCount: 2)
        await fixture.load()
        await fixture.provider.setDiscovery(.failure(.unauthenticated), branch: "feature-0")
        fixture.model.refresh(workspaceID: fixture.targets[0].workspaceID)
        await fixture.model.waitForIdle()
        let initial = await fixture.provider.calls.count
        fixture.clock.advance(10)
        fixture.model.refreshProject(projectID: fixture.targets[2].projectID)
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.calls.count == initial)
        #expect(fixture.model.state(for: fixture.targets[2].workspaceID)?.error == .unauthenticated)
        fixture.model.refresh(workspaceID: fixture.targets[1].workspaceID)
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: fixture.targets[1].workspaceID)?.error == nil)
        fixture.model.refresh(workspaceID: fixture.targets[2].workspaceID)
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: fixture.targets[2].workspaceID)?.error == nil)
    }
}
