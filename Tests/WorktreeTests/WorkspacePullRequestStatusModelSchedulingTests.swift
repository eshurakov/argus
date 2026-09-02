import Foundation
import Testing

@testable import Argus

extension WorkspacePullRequestStatusModelTests {
    @Test
    func selectedRefreshCadenceStartsAfterCompletion() async {
        let fixture = PullRequestRuntimeFixture()
        let id = fixture.targets[0].workspaceID
        await fixture.load(selected: id)
        let initial = await fixture.provider.calls.count
        await fixture.provider.suspend([.batch])
        fixture.clock.advance(60)
        fixture.update(selected: id)
        await fixture.provider.waitForCalls(initial + 1)
        fixture.clock.advance(20)
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: id)?.lastSuccess == fixture.clock.date)
        fixture.clock.advance(59)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == initial + 1)
        fixture.clock.advance(1)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == initial + 2)
        #expect(await fixture.provider.calls.last?.method == .batch)
    }

    @Test
    func selectionAndProjectExpansionCoalesceFreshPositiveResults() async {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.load()
        let initial = await fixture.provider.calls.count
        fixture.clock.advance(59)
        fixture.update(selected: target.workspaceID)
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.calls.count == initial)
        fixture.clock.advance(1)
        fixture.model.refreshProject(projectID: target.projectID)
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.calls.count == initial + 1)
        fixture.model.refreshProject(projectID: target.projectID)
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.calls.count == initial + 1)
    }

    @Test
    func confirmedNoMatchHasA600SecondCacheButManualRefreshBypassesIt() async {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.provider.setDiscovery(.success(nil), branch: "feature-0")
        await fixture.load(selected: target.workspaceID)
        fixture.clock.advance(599)
        fixture.model.refreshProject(projectID: target.projectID)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == 2)
        fixture.clock.advance(1)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == 4)
        fixture.model.refresh(workspaceID: target.workspaceID)
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.calls.count == 6)
        #expect(await fixture.provider.calls.suffix(2).map(\.method) == [.resolve, .discover])
        #expect(await fixture.provider.calls.allSatisfy { $0.method != .batch })
    }

    @Test
    func backgroundSweepRediscoveryCanReplaceAKnownPullRequest() async throws {
        let fixture = PullRequestRuntimeFixture()
        let id = fixture.targets[0].workspaceID
        await fixture.load()
        let initial = await fixture.provider.calls.count
        let previous = try #require(fixture.model.state(for: id)?.status)
        let replacement = PullRequestRuntimeFixture.status(
            branch: "feature-0", repository: previous.identity.repository, number: 2)
        await fixture.provider.setDiscovery(.success(replacement), branch: "feature-0")
        fixture.clock.advance(599)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == initial)
        fixture.clock.advance(1)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.suffix(3).map(\.method) == [.resolve, .discover, .batch])
        #expect(fixture.model.state(for: id)?.status == replacement)
    }

    @Test
    func projectFailuresBackOff30Then60Then120SecondsAndSuccessResetsThem() async {
        let fixture = PullRequestRuntimeFixture()
        let id = fixture.targets[0].workspaceID
        await fixture.provider.setDiscovery(.failure(.providerTimedOut), branch: "feature-0")
        await fixture.load(selected: id)
        var calls = await fixture.provider.calls.count
        for interval: TimeInterval in [30, 60, 120] {
            fixture.clock.advance(interval - 1)
            await fixture.model.tick()
            #expect(await fixture.provider.calls.count == calls)
            fixture.clock.advance(1)
            await fixture.model.tick()
            #expect(await fixture.provider.calls.count > calls)
            calls = await fixture.provider.calls.count
        }
        await fixture.provider.setDiscovery(.success(nil), branch: "feature-0")
        fixture.model.refresh(workspaceID: id)
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: id)?.error == nil)
        await fixture.provider.setDiscovery(.failure(.providerTimedOut), branch: "feature-0")
        fixture.model.refresh(workspaceID: id)
        await fixture.model.waitForIdle()
        calls = await fixture.provider.calls.count
        fixture.clock.advance(29)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == calls)
        fixture.clock.advance(1)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count > calls)
    }

    @Test
    func knownRateLimitDeadlineBlocksEvenManualRefresh() async {
        let fixture = PullRequestRuntimeFixture()
        let id = fixture.targets[0].workspaceID
        let deadline = fixture.clock.date.addingTimeInterval(90)
        await fixture.provider.setDiscovery(.failure(.rateLimited(retryAfter: deadline)), branch: "feature-0")
        await fixture.load(selected: id)
        fixture.clock.advance(89)
        fixture.model.refresh(workspaceID: id)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == 2)
        await fixture.provider.setDiscovery(.success(nil), branch: "feature-0")
        fixture.clock.advance(1)
        fixture.model.refresh(workspaceID: id)
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.calls.count == 4)
        #expect(fixture.model.state(for: id)?.error == nil)
    }

    @Test
    func missingCLIIsProbedOnceGloballyAndCachedFor30Seconds() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 5, projectCount: 5)
        for target in fixture.targets {
            await fixture.provider.setResolutionError(.githubCLIUnavailable, path: target.repositoryPath)
        }
        await fixture.load()
        #expect(await fixture.provider.calls.count == 1)
        #expect(fixture.model.states.values.allSatisfy { $0.error == .githubCLIUnavailable && !$0.isRefreshing })
        fixture.clock.advance(29)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == 1)
        fixture.clock.advance(1)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == 2)
        fixture.model.refresh(workspaceID: fixture.targets[0].workspaceID)
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.calls.count == 3)
    }

    @Test
    func globalConcurrencyIncludesRepositoryResolutionAndOutOfOrderCompletions() async throws {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 6, projectCount: 6)
        await fixture.provider.suspend([.resolve, .discover])
        fixture.update(selected: fixture.targets[0].workspaceID)
        await fixture.provider.waitForCalls(1)
        #expect(await fixture.provider.activeCount == 1)
        await fixture.provider.resume(0)
        await fixture.provider.waitForCalls(4)
        #expect(await fixture.provider.activeCount == 3)
        let calls = await fixture.provider.calls
        let resolution = try #require(calls.indices.dropFirst().first { calls[$0].method == .resolve })
        await fixture.provider.resume(resolution)
        await fixture.provider.waitForCalls(5)
        #expect(await fixture.provider.activeCount == 3)
        #expect(await fixture.provider.maximumActiveCount == 3)
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.maximumActiveCount == 3)
        #expect(fixture.model.states.values.allSatisfy { $0.status != nil && !$0.isRefreshing })
    }

    @Test
    func cancelledProviderWorkKeepsItsConcurrencySlotsUntilItActuallyCompletes() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 6, projectCount: 6)
        await fixture.provider.suspend([.resolve, .discover])
        fixture.update()
        await fixture.provider.waitForCalls(1)
        await fixture.provider.resume(0)
        await fixture.provider.waitForCalls(4)
        fixture.update(active: false)
        #expect(fixture.model.states.values.allSatisfy { !$0.isRefreshing })
        fixture.update()
        #expect(await fixture.provider.calls.count == 4)
        #expect(await fixture.provider.activeCount == 3)
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.maximumActiveCount == 3)
        #expect(fixture.model.states.values.allSatisfy { $0.status != nil && !$0.isRefreshing })
    }

    @Test
    func concurrentFailuresInOneProjectShareTheFirstRetryFloor() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 3)
        for index in 0..<3 {
            await fixture.provider.setDiscovery(.failure(.providerTimedOut), branch: "feature-\(index)")
        }
        await fixture.provider.suspend([.discover])
        fixture.update()
        await fixture.provider.waitForCalls(4)
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(fixture.model.states.values.allSatisfy { $0.error == .providerTimedOut && !$0.isRefreshing })
        fixture.clock.advance(29)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == 4)
        fixture.clock.advance(1)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count > 4)
    }

    @Test
    func deferredRetryPublishesRefreshingWhileRecoveringFromMissingCLI() async throws {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2, projectCount: 2)
        for target in fixture.targets {
            await fixture.provider.setResolutionError(.githubCLIUnavailable, path: target.repositoryPath)
        }
        await fixture.load()
        for target in fixture.targets { await fixture.provider.setResolutionError(nil, path: target.repositoryPath) }
        await fixture.provider.suspend([.resolve])
        fixture.clock.advance(30)
        fixture.update()
        await fixture.provider.waitForCalls(2)
        let path = await fixture.provider.calls[1].repositoryPath
        let target = try #require(fixture.targets.first { $0.repositoryPath == path })
        #expect(fixture.model.state(for: target.workspaceID)?.isRefreshing == true)
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(fixture.model.states.values.allSatisfy { $0.status != nil && $0.error == nil && !$0.isRefreshing })
    }

    @Test(arguments: [
        PullRequestStatusError.ambiguous, .unverifiedAssociation, .lookupLimit,
        .invalidMetadata("Invalid target metadata")
    ])
    func workspaceAssociationErrorsDoNotBlockOrMarkHealthySiblingsStale(error: PullRequestStatusError) async throws {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2)
        let first = fixture.targets[0]
        let second = fixture.targets[1]
        await fixture.load(selected: second.workspaceID)
        let identity = try #require(fixture.model.state(for: second.workspaceID)?.status?.identity)
        let initial = await fixture.provider.calls.count
        await fixture.provider.setDiscovery(.failure(error), branch: "feature-0")
        fixture.model.refresh(workspaceID: first.workspaceID)
        await fixture.model.waitForIdle()
        fixture.clock.advance(60)
        await fixture.model.tick()
        #expect(fixture.model.state(for: first.workspaceID)?.error == error)
        #expect(fixture.model.state(for: second.workspaceID)?.error == nil)
        #expect(fixture.model.state(for: second.workspaceID)?.lastSuccess == fixture.clock.date)
        #expect(fixture.model.state(for: second.workspaceID)?.isStale(at: fixture.clock.date) == false)
        let calls = await fixture.provider.calls.dropFirst(initial)
        #expect(calls.filter { $0.method == .batch }.map(\.identities) == [[identity]])
    }

    @Test
    func workspaceAssociationErrorRetriesWait60SecondsEvenOnSelectionOrExpansion() async {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.provider.setDiscovery(.failure(.ambiguous), branch: "feature-0")
        await fixture.load()
        fixture.clock.advance(10)
        fixture.update(selected: target.workspaceID)
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.calls.count == 2)
        fixture.clock.advance(49)
        fixture.model.refreshProject(projectID: target.projectID)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == 2)
        fixture.clock.advance(1)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == 3)
        #expect(fixture.model.state(for: target.workspaceID)?.error == .ambiguous)
        #expect(fixture.model.state(for: target.workspaceID)?.isRefreshing == false)
        #expect(fixture.model.state(for: target.workspaceID)?.lastSuccess == nil)
    }

    @Test(arguments: [false, true])
    func selectionRevalidatesChangedBranchDuringNoMatchOrAssociationErrorDelay(hasError: Bool) async {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.provider.setDiscovery(hasError ? .failure(.ambiguous) : .success(nil), branch: "feature-0")
        await fixture.load()
        fixture.clock.advance(5)
        await fixture.inputs.setBranch(PullRequestRuntimeFixture.branch("corrected"), path: target.worktreePath)
        fixture.update(selected: target.workspaceID)
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: target.workspaceID)?.status?.headBranchName == "corrected")
        #expect(fixture.model.state(for: target.workspaceID)?.error == nil)
        #expect(await fixture.provider.calls.last { $0.method == .discover }?.branch?.branchName == "corrected")
        #expect(await fixture.provider.calls.last { $0.method == .discover }?.previous == nil)
    }

    @Test
    func failureBackoffDoesNotDelayOtherProjects() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2, projectCount: 2)
        let first = fixture.targets[0]
        let second = fixture.targets[1]
        await fixture.load(selected: second.workspaceID)
        await fixture.provider.setDiscovery(.failure(.providerTimedOut), branch: "feature-0")
        fixture.model.refresh(workspaceID: first.workspaceID)
        await fixture.model.waitForIdle()
        fixture.clock.advance(60)
        await fixture.model.tick()
        #expect(fixture.model.state(for: first.workspaceID)?.error == .providerTimedOut)
        #expect(fixture.model.state(for: second.workspaceID)?.error == nil)
        #expect(fixture.model.state(for: second.workspaceID)?.lastSuccess == fixture.clock.date)
        #expect(await fixture.provider.calls.last?.identities.first?.repository.owner == "owner-1")
    }
}
