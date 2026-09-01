import Foundation
import Testing

@testable import Argus

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

    func workspace(_ checkout: String?) -> WorkspaceStackWorkspace {
        WorkspaceStackWorkspace(id: UUID(), path: checkout.map { "/checkouts/\($0)" })
    }

    func snapshot(_ parents: [String: String], branches: [String], trunks: Set<String> = [])
        -> WorkspaceStackSnapshot
    {
        WorkspaceStackSnapshot(
            gitCommonDirectory: "/repository/.git",
            worktrees: branches.map { WorkspaceStackWorktree(path: "/checkouts/\($0)", branch: $0) },
            parents: parents, trunkBranches: trunks
        )
    }

    func groups(_ items: [WorkspaceSidebarItem]) -> [WorkspaceStackGroup] {
        items.compactMap { item in
            guard case .stack(let group) = item else { return nil }
            return group
        }
    }
}
