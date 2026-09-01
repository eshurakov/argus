import Foundation
import Testing

@testable import Argus

@Suite
struct WorkspaceStackLayoutTests {
    @Test
    func groupsAtEarliestMemberPositionInRecordedOrder() throws {
        let workspaces = ["before", "c", "between", "a", "after", "b"].map { workspace($0) }
        let items = WorkspaceStackLayout.items(
            workspaces: workspaces,
            snapshot: snapshot(["a": "main", "b": "a", "c": "b"], branches: ["a", "b", "c"]),
            mainBranch: "main"
        )
        let group = try #require(groups(items).first)
        #expect(
            items == [
                .workspace(workspaces[0].id), .stack(group), .workspace(workspaces[2].id), .workspace(workspaces[4].id)
            ])
        #expect(group.id == "gh-stack:4:main:1:a")
        #expect(group.baseBranch == "main")
        #expect(group.rows.map(\.branch) == ["a", "b", "c"])
        #expect(group.rows.map(\.parentBranch) == ["main", "a", "b"])
        #expect(group.rows.map(\.dependentBranches) == [["b"], ["c"], []])
        #expect(group.workspaceIds == [workspaces[3].id, workspaces[5].id, workspaces[1].id])
        #expect(group.laneCount == 1)
    }

    @Test
    func missingIntermediatesAndOmittedTailKeepFullRelationships() throws {
        let workspaces = ["e", "a", "c"].map { workspace($0) }
        let items = WorkspaceStackLayout.items(
            workspaces: workspaces,
            snapshot: snapshot(
                ["a": "develop", "b": "a", "c": "b", "d": "c", "e": "d", "f": "e"], branches: ["a", "c", "e"]),
            mainBranch: "develop"
        )
        let group = try #require(groups(items).first)
        #expect(group.baseBranch == "develop")
        #expect(group.rows.map(\.branch) == ["a", "b", "c", "d", "e"])
        #expect(group.rows.map(\.workspaceId) == [workspaces[1].id, nil, workspaces[2].id, nil, workspaces[0].id])
        #expect(group.rows.map(\.parentBranch) == ["develop", "a", "b", "c", "d"])
        #expect(group.rows.map(\.dependentBranches) == [["b"], ["c"], ["d"], ["e"], ["f"]])
    }

    @Test
    func trimsLeadingReferencesToTheImmediateParentWithoutChangingIdentity() throws {
        let workspaces = ["e", "d"].map { workspace($0) }
        let items = WorkspaceStackLayout.items(
            workspaces: workspaces,
            snapshot: snapshot(
                ["a": "release", "b": "a", "c": "b", "d": "c", "e": "d", "f": "e"], branches: ["d", "e"]),
            mainBranch: "release"
        )
        let group = try #require(groups(items).first)
        #expect(group.id == "gh-stack:7:release:1:a")
        #expect(group.baseBranch == "b")
        #expect(
            group.rows == [
                WorkspaceStackRow(branch: "c", parentBranch: "b", dependentBranches: ["d"], workspaceId: nil),
                WorkspaceStackRow(
                    branch: "d", parentBranch: "c", dependentBranches: ["e"], workspaceId: workspaces[1].id),
                WorkspaceStackRow(
                    branch: "e", parentBranch: "d", dependentBranches: ["f"], workspaceId: workspaces[0].id)
            ])
    }

    @Test(arguments: [[], ["a"], ["main"], ["main", "a"], ["a", "x"]])
    func fewerThanTwoBoundWorkspacesPerComponentStayFlat(_ branches: [String]) {
        let workspaces = branches.map { workspace($0) }
        let items = WorkspaceStackLayout.items(
            workspaces: workspaces,
            snapshot: snapshot(["a": "main", "b": "a", "x": "main", "y": "x"], branches: branches),
            mainBranch: "main"
        )
        #expect(items == workspaces.map { .workspace($0.id) })
    }

    @Test
    func siblingsShareTheirActualParentAndSubtreesFollowEarliestManualDescendants() throws {
        let workspaces = ["right/tip", "outside", "left", "root", "right", "left/tip"].map { workspace($0) }
        let items = WorkspaceStackLayout.items(
            workspaces: workspaces,
            snapshot: snapshot(
                [
                    "root": "main", "left": "root", "right": "root", "left/tip": "left", "right/tip": "right",
                    "unused/z": "root", "unused/a": "root"
                ], branches: ["right/tip", "outside", "left", "root", "right", "left/tip"]),
            mainBranch: "main"
        )
        let group = try #require(groups(items).first)
        #expect(items == [.stack(group), .workspace(workspaces[1].id)])
        #expect(group.rows.map(\.branch) == ["root", "right", "right/tip", "left", "left/tip"])
        #expect(group.rows.map(\.parentBranch) == ["main", "root", "right", "root", "left"])
        #expect(group.rows[0].dependentBranches == ["right", "left", "unused/a", "unused/z"])
        #expect(group.rows.map(\.lane) == [0, 1, 1, 1, 1])
        #expect(group.laneCount == 2)
    }

    @Test(arguments: [false, true])
    func unrecordedSharedParentAppearsOnceWithoutInventingMain(_ parentIsOpen: Bool) throws {
        let branches = parentIsOpen ? ["b", "feature", "a"] : ["b", "a"]
        let workspaces = branches.map { workspace($0) }
        let group = try #require(
            groups(
                WorkspaceStackLayout.items(
                    workspaces: workspaces, snapshot: snapshot(["a": "feature", "b": "feature"], branches: branches),
                    mainBranch: "main"
                )
            ).first)
        #expect(group.rows.map(\.branch) == ["feature", "b", "a"])
        #expect(group.rows.map(\.parentBranch) == [nil, "feature", "feature"])
        #expect(group.rows.first?.dependentBranches == ["b", "a"])
        #expect(group.baseBranch == nil)
        #expect(group.rows.first?.workspaceId == (parentIsOpen ? workspaces[1].id : nil))
        #expect(group.rows.map(\.lane) == [0, 1, 1])
    }

    @Test
    func sharedMissingIntermediatesAndNestedForksAreRetainedOnce() throws {
        let branches = ["right", "left/b", "left/a"]
        let group = try #require(
            groups(
                WorkspaceStackLayout.items(
                    workspaces: branches.map { workspace($0) },
                    snapshot: snapshot(
                        [
                            "prefix": "main", "shared": "prefix", "left": "shared", "right": "shared",
                            "left/a": "left", "left/b": "left", "unused": "shared", "tail": "right"
                        ], branches: branches), mainBranch: "main"
                )
            ).first)
        #expect(group.rows.map(\.branch) == ["shared", "right", "left", "left/b", "left/a"])
        #expect(group.rows.map(\.lane) == [0, 1, 1, 2, 2])
        #expect(group.laneCount == 3)
        #expect(group.baseBranch == "prefix")
        #expect(group.rows[1].dependentBranches == ["tail"])
        #expect(group.rows[0].dependentBranches == ["right", "left", "unused"])
    }

    @Test(arguments: ["main", "develop"])
    func independentStacksKeepAnchorsWithoutGroupingAnUnparentedTrunk(_ trunk: String) {
        let workspaces = ["y", trunk, "b", "outside", "x", "a"].map { workspace($0) }
        let items = WorkspaceStackLayout.items(
            workspaces: workspaces,
            snapshot: snapshot(
                ["a": trunk, "b": "a", "x": trunk, "y": "x"], branches: [trunk, "a", "b", "x", "y"], trunks: [trunk])
        )
        #expect(groups(items).count == 2)
        #expect(groups(items).map(\.baseBranch) == [trunk, trunk])
        #expect(
            items.flatMap(\.workspaceIds) == [
                workspaces[4].id, workspaces[0].id, workspaces[1].id, workspaces[5].id, workspaces[2].id,
                workspaces[3].id
            ])
    }

    @Test(arguments: ["a", "b", "main"])
    func explicitlyParentedTrunksJoinThroughRealEdges(_ trunk: String) throws {
        let branches = ["b", "d", "a", "c", "main"]
        let parents = ["main": "develop", "a": "main", "b": "a", "c": trunk, "d": "c"]
        let workspaces = branches.map { workspace($0) }
        let items = WorkspaceStackLayout.items(
            workspaces: workspaces, snapshot: snapshot(parents, branches: branches, trunks: ["develop", "main", trunk]),
            mainBranch: "main"
        )
        let group = try #require(groups(items).first)
        #expect(groups(items).count == 1)
        #expect(group.rows.map(\.branch) == ["main", "a", "b", "c", "d"])
        #expect(group.rows.first { $0.branch == "c" }?.parentBranch == trunk)
        #expect(group.workspaceIds.count == workspaces.count)
        #expect(group.id == "gh-stack:7:develop:4:main")
    }
}

extension WorkspaceStackLayoutTests {
    @Test
    func partialLinearParentsHaveProviderIndependentIdentityAndStableExtensions() throws {
        let workspaces = ["c", "a", "b"].map { workspace($0) }
        let parents = ["a": "main", "b": "a", "c": "b"]
        let original = try #require(
            groups(
                WorkspaceStackLayout.items(
                    workspaces: workspaces, snapshot: snapshot(parents, branches: ["a", "b", "c"], trunks: ["main"])
                )
            ).first)
        let extended = parents.merging(["d": "c"], uniquingKeysWith: { _, new in new })
        let updated = try #require(
            groups(
                WorkspaceStackLayout.items(
                    workspaces: [workspaces[0], workspaces[2]], snapshot: snapshot(extended, branches: ["a", "b", "c"]),
                    mainBranch: "main"
                )
            ).first)
        #expect(original.id == updated.id)
        #expect(updated.id == "gh-stack:4:main:1:a")
        #expect(updated.rows.first?.workspaceId == nil)
        #expect(updated.workspaceIds == [workspaces[2].id, workspaces[0].id])
        #expect(updated.rows.last?.dependentBranches == ["d"])
    }

    @Test
    func forkIdentitySurvivesManualSiblingReorderingAndClosedRoots() throws {
        let workspaces = ["a", "b", "root"].map { workspace($0) }
        let metadata = snapshot(["root": "main", "a": "root", "b": "root"], branches: ["root", "a", "b"])
        let original = try #require(
            groups(WorkspaceStackLayout.items(workspaces: workspaces, snapshot: metadata, mainBranch: "main")).first)
        let updated = try #require(
            groups(
                WorkspaceStackLayout.items(
                    workspaces: [workspaces[1], workspaces[0]], snapshot: metadata, mainBranch: "main")
            ).first)
        #expect(original.rows.map(\.branch) == ["root", "a", "b"])
        #expect(updated.rows.map(\.branch) == ["root", "b", "a"])
        #expect(original.id == updated.id)
        #expect(updated.rows.first?.workspaceId == nil)
    }

    @Test
    func diagnosticsAndConflictedRootsDoNotEraseTrustedDescendants() throws {
        let branches = ["b", "a", "x", "y"]
        let workspaces = branches.map { workspace($0) }
        let metadata = WorkspaceStackSnapshot(
            gitCommonDirectory: "/repository/.git",
            worktrees: branches.map { WorkspaceStackWorktree(path: "/checkouts/\($0)", branch: $0) },
            parents: ["a": "unknown", "b": "unknown", "x": "main", "y": "x"],
            conflicts: ["unknown": "Conflicting recorded parents"], diagnostics: ["Another provider is unreadable"]
        )
        let items = WorkspaceStackLayout.items(workspaces: workspaces, snapshot: metadata, mainBranch: "main")
        let group = try #require(groups(items).first)
        #expect(metadata.issue != nil)
        #expect(groups(items).count == 2)
        #expect(group.baseBranch == nil)
        #expect(group.rows.first?.parentBranch == nil)
        #expect(group.rows.first?.issue == "Conflicting recorded parents")
        #expect(group.rows.first?.dependentBranches == ["b", "a"])
        #expect(groups(items).last?.workspaceIds == [workspaces[2].id, workspaces[3].id])
    }

    @Test
    func nilAndEmptySnapshotsPreserveOriginalOrder() {
        let workspaces = [workspace("c"), workspace(nil), workspace("a")]
        for metadata in [nil, snapshot([:], branches: ["a", "c"])] {
            #expect(
                WorkspaceStackLayout.items(workspaces: workspaces, snapshot: metadata)
                    == workspaces.map { .workspace($0.id) })
        }
    }

    @Test
    func bindsOnlyExactLiveCheckoutPathsAndCurrentBranches() throws {
        let workspaces = ["a", "c", "b"].map { workspace($0) }
        let metadata = WorkspaceStackSnapshot(
            gitCommonDirectory: "/repository/.git",
            worktrees: [
                WorkspaceStackWorktree(path: "/checkouts/a", branch: "replacement"),
                WorkspaceStackWorktree(path: "/checkouts/closed", branch: "a"),
                WorkspaceStackWorktree(path: "/checkouts/b", branch: "b"),
                WorkspaceStackWorktree(path: "/checkouts/c", branch: "c")
            ], parents: ["a": "main", "b": "a", "c": "b"]
        )
        let items = WorkspaceStackLayout.items(workspaces: workspaces, snapshot: metadata, mainBranch: "main")
        let group = try #require(groups(items).first)
        #expect(items == [.workspace(workspaces[0].id), .stack(group)])
        #expect(group.workspaceIds == [workspaces[2].id, workspaces[1].id])
        #expect(group.rows.first?.branch == "a")
        #expect(group.rows.first?.workspaceId == nil)
    }

    @Test
    func detachedUnregisteredAndUnrootedWorkspacesDoNotBind() {
        let workspaces = [workspace("a"), workspace("b"), workspace("c"), workspace(nil)]
        let metadata = WorkspaceStackSnapshot(
            gitCommonDirectory: "/repository/.git",
            worktrees: [
                WorkspaceStackWorktree(path: "/checkouts/a", branch: nil),
                WorkspaceStackWorktree(path: "/checkouts/b", branch: "b")
            ],
            parents: ["a": "main", "b": "a", "c": "b"]
        )
        #expect(
            WorkspaceStackLayout.items(workspaces: workspaces, snapshot: metadata, mainBranch: "main")
                == workspaces.map { .workspace($0.id) })
    }

    @Test
    func ambiguousWorkspacePathsDoNotBlockAnIndependentStack() throws {
        let workspaces = ["a", "b", "y", "a", "x"].map { workspace($0) }
        let items = WorkspaceStackLayout.items(
            workspaces: workspaces,
            snapshot: snapshot(["a": "main", "b": "a", "x": "main", "y": "x"], branches: ["a", "b", "x", "y"]),
            mainBranch: "main"
        )
        let group = try #require(groups(items).first)
        #expect(group.workspaceIds == [workspaces[4].id, workspaces[2].id])
        #expect(
            items == [
                .workspace(workspaces[0].id), .workspace(workspaces[1].id), .stack(group), .workspace(workspaces[3].id)
            ])
    }

    @Test(arguments: [true, false])
    func ambiguousInventoryPathsOrBranchesStayFlatEvenForUnopenedCheckouts(_ samePath: Bool) {
        let workspaces = [workspace("a"), workspace("b")]
        let metadata = WorkspaceStackSnapshot(
            gitCommonDirectory: "/repository/.git",
            worktrees: [
                WorkspaceStackWorktree(path: "/checkouts/a", branch: "a"),
                WorkspaceStackWorktree(path: samePath ? "/checkouts/a" : "/checkouts/closed", branch: "a"),
                WorkspaceStackWorktree(path: "/checkouts/b", branch: "b")
            ], parents: ["a": "main", "b": "a"]
        )
        #expect(
            WorkspaceStackLayout.items(workspaces: workspaces, snapshot: metadata, mainBranch: "main")
                == workspaces.map { .workspace($0.id) })
    }
}

extension WorkspaceStackLayoutTests {
    @Test(arguments: [1, 2, 3])
    func unsafeCyclesNeverTraverseOrBlockIndependentRelationships(_ length: Int) throws {
        let cycle = Array(["a", "b", "c"].prefix(length))
        var parents = ["x": "main", "y": "x"]
        for index in cycle.indices { parents[cycle[index]] = cycle[(index + 1) % length] }
        let branches = cycle + ["y", "x"]
        let workspaces = branches.map { workspace($0) }
        let items = WorkspaceStackLayout.items(
            workspaces: workspaces, snapshot: snapshot(parents, branches: branches), mainBranch: "main")
        #expect(groups(items).count == 1)
        #expect(groups(items).first?.rows.map(\.branch) == ["x", "y"])
        #expect(Array(items.prefix(length)) == workspaces.prefix(length).map { .workspace($0.id) })
        #expect(Set(items.flatMap(\.workspaceIds)).count == workspaces.count)
    }

    @Test(arguments: Array(0..<32))
    func everyOpenWorkspaceOccursExactlyOnceAcrossPartialForks(_ mask: Int) {
        let branches = ["a", "b", "c", "d", "e"]
        let open = branches.enumerated().filter { mask & (1 << $0.offset) != 0 }.map { workspace($0.element) }
        let outside = [workspace(nil), workspace("unrelated"), workspace("main")]
        let workspaces = Array(open.reversed()) + outside
        let items = WorkspaceStackLayout.items(
            workspaces: workspaces,
            snapshot: snapshot(
                ["a": "main", "b": "a", "c": "a", "d": "b", "e": "c"], branches: branches + ["main", "unrelated"]),
            mainBranch: "main"
        )
        let ids = items.flatMap(\.workspaceIds)
        #expect(ids.count == workspaces.count)
        #expect(Set(ids) == Set(workspaces.map(\.id)))
        #expect(groups(items).count == (open.count >= 2 ? 1 : 0))
        #expect(Array(ids.suffix(outside.count)) == outside.map(\.id))
        for group in groups(items) { #expect(Set(group.rows.map(\.branch)).count == group.rows.count) }
    }

    @Test
    func duplicateWorkspaceIDsNeverCreateDuplicateMembership() {
        let first = workspace("a")
        let repeated = WorkspaceStackWorkspace(id: first.id, path: "/checkouts/c")
        let second = workspace("b")
        let items = WorkspaceStackLayout.items(
            workspaces: [first, repeated, second],
            snapshot: snapshot(["a": "main", "b": "a", "c": "b"], branches: ["a", "b", "c"]), mainBranch: "main"
        )
        #expect(items == [.workspace(first.id), .workspace(second.id)])
    }

    @Test
    func longChainsDoNotRequireRecursiveTraversalOrExtraLanes() throws {
        let branches = (0..<4_096).map { "branch-\($0)" }
        let parents = Dictionary(uniqueKeysWithValues: zip(branches, ["main"] + branches.dropLast()))
        let group = try #require(
            groups(
                WorkspaceStackLayout.items(
                    workspaces: [workspace(branches.last), workspace(branches.first)],
                    snapshot: snapshot(parents, branches: branches), mainBranch: "main"
                )
            ).first)
        #expect(group.rows.map(\.branch) == branches)
        #expect(group.workspaceIds.count == 2)
        #expect(group.laneCount == 1)
    }

    @Test
    func encodedRootParentAndTypedItemIdentitiesDoNotCollide() throws {
        let metadata = snapshot(
            ["topic": "release/root", "next": "topic", "root/topic": "release", "other": "root/topic"],
            branches: ["topic", "next", "root/topic", "other"], trunks: ["release/root", "release"])
        let items = WorkspaceStackLayout.items(
            workspaces: ["topic", "next", "root/topic", "other"].map { workspace($0) }, snapshot: metadata)
        #expect(Set(groups(items).map(\.id)).count == 2)
        let workspaceId = UUID()
        let ordinary = WorkspaceSidebarItem.workspace(workspaceId)
        let stack = WorkspaceSidebarItem.stack(
            WorkspaceStackGroup(id: workspaceId.uuidString, baseBranch: nil, rows: []))
        #expect(Set([ordinary.id, stack.id]).count == 2)
        #expect(ordinary.workspaceIds == [workspaceId])
        #expect(stack.workspaceIds.isEmpty)
    }

    private func workspace(_ checkout: String?) -> WorkspaceStackWorkspace {
        WorkspaceStackWorkspace(id: UUID(), path: checkout.map { "/checkouts/\($0)" })
    }

    private func snapshot(_ parents: [String: String], branches: [String], trunks: Set<String> = [])
        -> WorkspaceStackSnapshot
    {
        WorkspaceStackSnapshot(
            gitCommonDirectory: "/repository/.git",
            worktrees: branches.map { WorkspaceStackWorktree(path: "/checkouts/\($0)", branch: $0) },
            parents: parents, trunkBranches: trunks
        )
    }

    private func groups(_ items: [WorkspaceSidebarItem]) -> [WorkspaceStackGroup] {
        items.compactMap { item in
            guard case .stack(let group) = item else { return nil }
            return group
        }
    }
}
