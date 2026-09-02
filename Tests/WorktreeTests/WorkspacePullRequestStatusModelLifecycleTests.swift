import Combine
import Foundation
import Testing

@testable import Argus

extension WorkspacePullRequestStatusModelTests {
    @Test(arguments: [false, true])
    func manualRefreshPublishesProgressThroughCompletionAndSuspension(hasStatus: Bool) async throws {
        let fixture = PullRequestRuntimeFixture()
        let id = fixture.targets[0].workspaceID
        if !hasStatus { await fixture.provider.setDiscovery(.success(nil), branch: "feature-0") }
        await fixture.load(selected: id)
        let previous = try #require(fixture.model.state(for: id))
        var progressStates: [Bool?] = []
        let subscription = fixture.model.$states.map { $0[id]?.isRefreshing }.removeDuplicates().sink {
            progressStates.append($0)
        }
        defer {
            subscription.cancel()
            fixture.model.stop()
        }

        fixture.model.refresh(workspaceID: id)
        var refreshing = previous
        refreshing.isRefreshing = true
        #expect(fixture.model.state(for: id) == refreshing)
        #expect(progressStates == [false, true])
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: id)?.isRefreshing == false)
        #expect(progressStates == [false, true, false])

        fixture.model.refresh(workspaceID: id)
        #expect(fixture.model.state(for: id)?.isRefreshing == true)
        fixture.update(selected: id, active: false)
        #expect(fixture.model.state(for: id) == previous)
        #expect(progressStates == [false, true, false, true, false])
        fixture.model.refresh(workspaceID: id)
        #expect(fixture.model.state(for: id)?.isRefreshing == false)

        fixture.model.stop()
        #expect(progressStates == [false, true, false, true, false, nil])
        await fixture.model.waitForIdle()
        #expect(fixture.model.states.isEmpty)
    }

    @Test
    func manualRefreshSupersedesAutomaticWorkAndDuplicatesCoalesce() async throws {
        let fixture = PullRequestRuntimeFixture()
        let id = fixture.targets[0].workspaceID
        await fixture.load(selected: id)
        let initial = await fixture.provider.calls.count
        let previous = try #require(fixture.model.state(for: id)?.status)
        let obsolete = PullRequestRuntimeFixture.status(
            branch: "feature-0", repository: previous.identity.repository, number: 9)
        let replacement = PullRequestRuntimeFixture.status(
            branch: "feature-0", repository: previous.identity.repository, number: 2)
        await fixture.provider.setRefresh(.success(obsolete), branch: "feature-0")
        await fixture.provider.setDiscovery(.success(replacement), branch: "feature-0")
        await fixture.provider.suspend([.batch, .discover])
        fixture.clock.advance(60)
        fixture.update(selected: id)
        await fixture.provider.waitForCalls(initial + 1)
        fixture.model.refresh(workspaceID: id)
        fixture.model.refresh(workspaceID: id)
        #expect(await fixture.provider.calls.count == initial + 1)
        await fixture.provider.resume(initial)
        await fixture.provider.waitForCalls(initial + 3)
        #expect(fixture.model.state(for: id)?.status == previous)
        #expect(await fixture.provider.cancelledCompletions == [initial])
        fixture.model.refresh(workspaceID: id)
        #expect(await fixture.provider.calls.count == initial + 3)
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: id)?.status == replacement)
        #expect(
            await fixture.provider.calls.map(\.method) == [
                .resolve, .discover, .batch, .batch, .resolve, .discover, .batch
            ])
    }

    @Test
    func suspensionCancelsRefreshRetainsTimestampsAndRevalidatesOnResume() async throws {
        let fixture = PullRequestRuntimeFixture()
        let id = fixture.targets[0].workspaceID
        await fixture.load(selected: id)
        let initial = await fixture.provider.calls.count
        let previous = try #require(fixture.model.state(for: id))
        await fixture.provider.suspend([.batch])
        fixture.clock.advance(60)
        fixture.update(selected: id)
        await fixture.provider.waitForCalls(initial + 1)
        fixture.update(selected: id, active: false)
        #expect(fixture.model.state(for: id) == previous)
        fixture.clock.advance(700)
        fixture.model.refresh(workspaceID: id)
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        await fixture.model.tick()
        #expect(await fixture.provider.calls.count == initial + 1)
        #expect(fixture.model.state(for: id)?.isStale(at: fixture.clock.date) == true)
        fixture.update(selected: id)
        await fixture.model.waitForIdle()
        #expect(await fixture.provider.calls.suffix(3).map(\.method) == [.resolve, .discover, .batch])
        #expect(fixture.model.state(for: id)?.lastSuccess == fixture.clock.date)
        #expect(fixture.model.state(for: id)?.isRefreshing == false)
    }

    @Test
    func immediateResumeDoesNotStrandACancelledInitialRequest() async {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.provider.suspend([.discover])
        fixture.update()
        await fixture.provider.waitForCalls(2)
        fixture.update(active: false)
        #expect(fixture.model.state(for: target.workspaceID)?.isRefreshing == false)
        await fixture.inputs.setBranch(PullRequestRuntimeFixture.branch("resumed"), path: target.worktreePath)
        fixture.update()
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: target.workspaceID)?.status?.headBranchName == "resumed")
        #expect(fixture.model.state(for: target.workspaceID)?.isRefreshing == false)
        #expect(fixture.model.state(for: target.workspaceID)?.error == nil)
        #expect(await fixture.provider.calls.filter { $0.method == .resolve }.count == 2)
    }

    @Test
    func disabledAndStoppedModelsPruneStateAndRejectLateResults() async {
        let fixture = PullRequestRuntimeFixture()
        await fixture.provider.suspend([.discover])
        fixture.update()
        await fixture.provider.waitForCalls(2)
        fixture.update(enabled: false)
        #expect(fixture.model.states.isEmpty)
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(fixture.model.states.isEmpty)
        await fixture.load()
        #expect(fixture.model.states.values.allSatisfy { $0.status != nil })
        fixture.model.stop()
        fixture.clock.advance(300)
        await fixture.model.tick()
        #expect(fixture.model.states.isEmpty)
        #expect(await fixture.provider.calls.count == 5)
    }

    @Test
    func removedAndReaddedWorkspaceDoesNotReceiveItsOldGenerationResult() async throws {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2)
        let target = fixture.targets[0]
        await fixture.load(selected: target.workspaceID)
        let initial = await fixture.provider.calls.count
        let previous = try #require(fixture.model.state(for: target.workspaceID)?.status)
        await fixture.provider.suspend([.batch])
        fixture.clock.advance(60)
        fixture.update(selected: target.workspaceID)
        await fixture.provider.waitForCalls(initial + 1)
        fixture.update(targets: [fixture.targets[1]])
        #expect(fixture.model.state(for: target.workspaceID) == nil)
        fixture.update()
        #expect(fixture.model.state(for: target.workspaceID)?.status == nil)
        let replacement = PullRequestRuntimeFixture.status(
            branch: "feature-0", repository: previous.identity.repository, number: 3)
        await fixture.provider.setDiscovery(.success(replacement), branch: "feature-0")
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: target.workspaceID)?.status == replacement)
        #expect(await fixture.provider.calls.last { $0.method == .discover }?.previous == nil)
        #expect(fixture.model.state(for: fixture.targets[1].workspaceID)?.status != nil)
    }

    @Test
    func removedProjectCannotPopulateResolutionCacheForAReaddedProject() async {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.provider.suspend([.resolve])
        fixture.update()
        await fixture.provider.waitForCalls(1)
        fixture.update(targets: [])
        #expect(fixture.model.states.isEmpty)
        let repository = RepositoryIdentity(
            provider: .github, host: "github.example", owner: "replacement", repositoryName: "repo")
        await fixture.provider.setRepository(repository, path: target.repositoryPath)
        await fixture.inputs.setRemotes(PullRequestRuntimeFixture.remotes(repository), path: target.repositoryPath)
        fixture.update()
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: target.workspaceID)?.status?.identity.repository == repository)
        #expect(await fixture.provider.calls.map(\.method) == [.resolve, .resolve, .discover, .batch])
    }

    @Test
    func inactiveInitialInventoryDoesNoWorkUntilResumed() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 3)
        fixture.update(active: false)
        await fixture.model.tick()
        #expect(await fixture.provider.calls.isEmpty)
        #expect(await fixture.inputs.projectReads.isEmpty)
        #expect(fixture.model.states.values.allSatisfy { !$0.hasLoaded && !$0.isRefreshing })
        await fixture.load()
        #expect(fixture.model.states.values.allSatisfy { $0.hasLoaded && $0.status != nil })
    }

    @Test
    func addedTargetsDuringLocalReadsAreDiscoveredRatherThanDeclaredMissing() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2)
        await fixture.inputs.suspendReads()
        fixture.update(targets: [fixture.targets[0]])
        await fixture.inputs.waitForRead()
        fixture.update()
        await fixture.inputs.resumeReads()
        await fixture.model.waitForIdle()
        #expect(fixture.model.states.values.allSatisfy { $0.status != nil && $0.error == nil })
        #expect(await fixture.inputs.projectReads.count == 2)
        #expect(await fixture.provider.calls.filter { $0.method == .batch }.map(\.identities.count) == [2])
    }
}
