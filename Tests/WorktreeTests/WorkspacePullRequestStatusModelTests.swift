import Combine
import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct WorkspacePullRequestStatusModelTests {
    @Test
    func batchesWorktreeInputsAndRepositoryResolutionByProject() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 4)
        await fixture.load()
        #expect(await fixture.inputs.projectReads.count == 1)
        let calls = await fixture.provider.calls
        #expect(calls.filter { $0.method == .resolve }.count == 1)
        #expect(calls.filter { $0.method == .discover }.count == 4)
        #expect(calls.filter { $0.method == .batch }.map(\.identities.count) == [4])
        for (index, target) in fixture.targets.enumerated() {
            let state = fixture.model.state(for: target.workspaceID)
            #expect(state?.branchName == "feature-\(index)")
            #expect(state?.status?.headBranchName == "feature-\(index)")
            #expect(state?.lastSuccess == fixture.clock.date)
            #expect(state?.hasLoaded == true)
            #expect(state?.isRefreshing == false)
        }
    }

    @Test
    func freshSelectionStillObservesAnUnselectedBranchSwitch() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2)
        let target = fixture.targets[1]
        await fixture.load(selected: fixture.targets[0].workspaceID)
        fixture.clock.advance(2)
        await fixture.inputs.setBranch(PullRequestRuntimeFixture.branch("switched"), path: target.worktreePath)
        fixture.update(selected: target.workspaceID)
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: target.workspaceID)?.status?.headBranchName == "switched")
        let call = await fixture.provider.calls.last { $0.method == .discover }
        #expect(call?.branch?.branchName == "switched")
        #expect(call?.previous == nil)
        #expect(await fixture.inputs.projectReads.last?.worktreePaths == [target.worktreePath])
        #expect(fixture.model.state(for: fixture.targets[0].workspaceID)?.branchName == "feature-0")
    }

    @Test
    func backgroundRediscoveryUsesTheCurrentBranchOfUnselectedWorkspaces() async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2)
        await fixture.load()
        let target = fixture.targets[1]
        await fixture.inputs.setBranch(PullRequestRuntimeFixture.branch("background-switch"), path: target.worktreePath)
        fixture.clock.advance(600)
        await fixture.model.tick()
        #expect(fixture.model.state(for: target.workspaceID)?.branchName == "background-switch")
        #expect(fixture.model.state(for: target.workspaceID)?.status?.headBranchName == "background-switch")
        #expect(await fixture.inputs.projectReads.count == 2)
    }

    @Test
    func discardsAnInFlightResultAfterBranchSwitchAndClearsTheOldAssociation() async {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.load(selected: target.workspaceID)
        let initial = await fixture.provider.calls.count
        await fixture.provider.suspend([.batch, .discover])
        fixture.clock.advance(60)
        fixture.update(selected: target.workspaceID)
        await fixture.provider.waitForCalls(initial + 1)
        await fixture.inputs.setBranch(PullRequestRuntimeFixture.branch("new-branch"), path: target.worktreePath)
        await fixture.provider.resume(initial)
        await fixture.provider.waitForCalls(initial + 2)
        #expect(fixture.model.state(for: target.workspaceID)?.status == nil)
        #expect(fixture.model.state(for: target.workspaceID)?.branchName == "new-branch")
        #expect(fixture.model.state(for: target.workspaceID)?.isRefreshing == true)
        let calls = await fixture.provider.calls
        #expect(calls.last?.branch?.branchName == "new-branch")
        #expect(calls.last?.previous == nil)
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: target.workspaceID)?.status?.headBranchName == "new-branch")
    }

    @Test
    func headChangesRejectInFlightResultsWithoutLosingSameBranchAssociation() async throws {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.load(selected: target.workspaceID)
        let previous = try #require(fixture.model.state(for: target.workspaceID)?.status)
        let initial = await fixture.provider.calls.count
        await fixture.provider.suspend([.batch, .discover])
        fixture.clock.advance(60)
        fixture.update(selected: target.workspaceID)
        await fixture.provider.waitForCalls(initial + 1)
        let branch = PullRequestRuntimeFixture.branch("feature-0", head: String(repeating: "b", count: 40))
        await fixture.inputs.setBranch(branch, path: target.worktreePath)
        await fixture.provider.resume(initial)
        await fixture.provider.waitForCalls(initial + 2)
        #expect(fixture.model.state(for: target.workspaceID)?.status == previous)
        let calls = await fixture.provider.calls
        #expect(calls.last?.branch == branch)
        #expect(calls.last?.previous == previous)
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        #expect(fixture.model.state(for: target.workspaceID)?.status?.identity == previous.identity)
    }

    @Test
    func providerErrorsRetainStaleStatusButCompleteNoMatchClearsIt() async throws {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.load()
        let previous = try #require(fixture.model.state(for: target.workspaceID)?.status)
        let successfulAt = fixture.clock.date
        fixture.clock.advance(1)
        await fixture.provider.setDiscovery(.failure(.ambiguous), branch: "feature-0")
        fixture.model.refresh(workspaceID: target.workspaceID)
        await fixture.model.waitForIdle()
        let failed = try #require(fixture.model.state(for: target.workspaceID))
        #expect(failed.status == previous)
        #expect(failed.error == .ambiguous)
        #expect(failed.lastSuccess == successfulAt)
        #expect(failed.isStale(at: fixture.clock.date))
        await fixture.provider.setDiscovery(.success(nil), branch: "feature-0")
        fixture.model.refresh(workspaceID: target.workspaceID)
        await fixture.model.waitForIdle()
        let empty = fixture.model.state(for: target.workspaceID)
        #expect(empty?.status == nil)
        #expect(empty?.error == nil)
        #expect(empty?.hasLoaded == true)
        #expect(empty?.lastSuccess == fixture.clock.date)
    }

    @Test(arguments: ["The worktree is missing.", "The worktree is unregistered.", "The worktree has a detached HEAD."])
    func invalidLocalWorktreesClearAssociationsWithoutProviderCalls(detail: String) async {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2)
        await fixture.load()
        let target = fixture.targets[0]
        let callCount = await fixture.provider.calls.count
        let error = PullRequestStatusError.repositoryUnavailable(detail)
        await fixture.inputs.setUnavailable(error, path: target.worktreePath)
        fixture.model.refresh(workspaceID: target.workspaceID)
        await fixture.model.waitForIdle()
        let state = fixture.model.state(for: target.workspaceID)
        #expect(state?.status == nil)
        #expect(state?.branchName == nil)
        #expect(state?.error == error)
        #expect(state?.hasLoaded == true)
        #expect(state?.isRefreshing == false)
        #expect(await fixture.provider.calls.count == callCount)
        #expect(fixture.model.state(for: fixture.targets[1].workspaceID)?.status != nil)
    }

    @Test
    func selectedRefreshReadsOnlyItsContextUntilTheFullDiscoverySweep() async throws {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 4)
        let selected = fixture.targets[0]
        let unselected = fixture.targets[1]
        await fixture.load(selected: selected.workspaceID)
        let original = try #require(fixture.model.state(for: unselected.workspaceID))
        await fixture.inputs.setBranch(PullRequestRuntimeFixture.branch("later"), path: unselected.worktreePath)
        fixture.clock.advance(60)
        await fixture.model.tick()
        let selectedReads = await fixture.inputs.projectReads
        #expect(selectedReads.count == 2)
        #expect(selectedReads.last?.repositoryPath == selected.repositoryPath)
        #expect(selectedReads.last?.worktreePaths == [selected.worktreePath])
        #expect(fixture.model.state(for: unselected.workspaceID) == original)
        fixture.clock.advance(540)
        await fixture.model.tick()
        let fullReads = await fixture.inputs.projectReads
        #expect(fullReads.count == 3)
        #expect(fullReads.last?.worktreePaths == fixture.targets.map(\.worktreePath))
        #expect(fixture.model.state(for: unselected.workspaceID)?.branchName == "later")
        #expect(fixture.model.state(for: unselected.workspaceID)?.status?.headBranchName == "later")
    }

    @Test
    func equalStatePublicationAndUnchangedUpdatesDoNotEmitDuplicateValues() async throws {
        let fixture = PullRequestRuntimeFixture()
        let id = fixture.targets[0].workspaceID
        await fixture.load(selected: id)
        let state = try #require(fixture.model.state(for: id))
        var emissions = 0
        let subscription = fixture.model.$states.dropFirst().sink { _ in emissions += 1 }
        defer { subscription.cancel() }
        fixture.model.publish(state, for: id)
        fixture.model.publish(state, for: id)
        fixture.update(selected: id)
        await fixture.model.tick()
        #expect(emissions == 0)
        var changed = state
        changed.isRefreshing = true
        fixture.model.publish(changed, for: id)
        fixture.model.publish(changed, for: id)
        #expect(emissions == 1)
    }

    @Test
    func freshnessExpiresAfter660SecondsOrImmediatelyOnError() async throws {
        let fixture = PullRequestRuntimeFixture()
        await fixture.load()
        var state = try #require(fixture.model.state(for: fixture.targets[0].workspaceID))
        #expect(!state.isStale(at: fixture.clock.date.addingTimeInterval(600)))
        #expect(!state.isStale(at: fixture.clock.date.addingTimeInterval(660)))
        #expect(state.isStale(at: fixture.clock.date.addingTimeInterval(660.1)))
        state.error = .providerTimedOut
        #expect(state.isStale(at: fixture.clock.date))
        state.status = nil
        #expect(!state.isStale(at: fixture.clock.date))
    }
}
