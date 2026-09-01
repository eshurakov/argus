import Foundation

typealias WorkspaceStackWorktree = GitWorktreeBranch
typealias WorkspaceStackSnapshot = RecordedBaseBranchSnapshot

struct WorkspaceStackWorkspace: Equatable, Sendable {
    let id: UUID
    let path: String?
}

struct WorkspaceStackRow: Equatable, Identifiable, Sendable {
    let branch: String
    let parentBranch: String?
    let dependentBranches: [String]
    let workspaceId: UUID?
    var lane: Int = 0
    var issue: String? = nil

    var id: String { branch }
}

struct WorkspaceStackGroup: Equatable, Identifiable, Sendable {
    let id: String
    let baseBranch: String?
    let rows: [WorkspaceStackRow]

    var workspaceIds: [UUID] { rows.compactMap(\.workspaceId) }
    var laneCount: Int { (rows.map(\.lane).max() ?? 0) + 1 }
}

enum WorkspaceSidebarItem: Equatable, Identifiable, Sendable {
    enum Identifier: Hashable, Sendable {
        case workspace(UUID)
        case stack(String)
    }

    case workspace(UUID)
    case stack(WorkspaceStackGroup)

    var id: Identifier {
        switch self {
        case .workspace(let workspaceId): .workspace(workspaceId)
        case .stack(let group): .stack(group.id)
        }
    }

    var workspaceIds: [UUID] {
        switch self {
        case .workspace(let workspaceId): [workspaceId]
        case .stack(let group): group.workspaceIds
        }
    }
}

enum WorkspaceStackLayout {
    static func items(
        workspaces: [WorkspaceStackWorkspace],
        snapshot: WorkspaceStackSnapshot?,
        mainBranch: String? = nil
    ) -> [WorkspaceSidebarItem] {
        var seen = Set<UUID>()
        let ordered = workspaces.filter { seen.insert($0.id).inserted }
        guard let snapshot else { return ordered.map { .workspace($0.id) } }
        let bindings = branchBindings(workspaces: workspaces, worktrees: snapshot.worktrees)
        let positions = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset) })
        let parents = snapshot.parents
        var dependents: [String: [String]] = [:]
        for (branch, parent) in parents {
            dependents[parent, default: []].append(branch)
        }
        let boundaries = snapshot.trunkBranches.union(mainBranch.map { [$0] } ?? [])
            .filter { parents[$0] == nil }
        let roots = Set(parents.keys).union(parents.values).filter { branch in
            !boundaries.contains(branch) && (parents[branch] == nil || boundaries.contains(parents[branch] ?? ""))
        }
        var groupsByPosition: [Int: WorkspaceStackGroup] = [:]
        var groupedWorkspaceIds = Set<UUID>()
        for root in roots {
            guard
                let group = group(
                    root: root, snapshot: snapshot, dependents: dependents,
                    bindings: bindings, positions: positions
                ), let position = group.workspaceIds.compactMap({ positions[$0] }).min()
            else { continue }
            groupsByPosition[position] = group
            groupedWorkspaceIds.formUnion(group.workspaceIds)
        }
        var result: [WorkspaceSidebarItem] = []
        for (position, workspace) in ordered.enumerated() {
            if let group = groupsByPosition[position] {
                result.append(.stack(group))
            } else if !groupedWorkspaceIds.contains(workspace.id) {
                result.append(.workspace(workspace.id))
            }
        }
        return result
    }

    private static func branchBindings(
        workspaces: [WorkspaceStackWorkspace],
        worktrees: [WorkspaceStackWorktree]
    ) -> [String: UUID] {
        let idCounts = Dictionary(workspaces.map { ($0.id, 1) }, uniquingKeysWith: +)
        let pathCounts = Dictionary(workspaces.compactMap(\.path).map { ($0, 1) }, uniquingKeysWith: +)
        let worktreesByPath = Dictionary(grouping: worktrees, by: \.path)
        let branchCounts = Dictionary(worktrees.compactMap(\.branch).map { ($0, 1) }, uniquingKeysWith: +)
        var candidates: [String: [UUID]] = [:]
        for workspace in workspaces {
            guard idCounts[workspace.id] == 1,
                let path = workspace.path, pathCounts[path] == 1,
                let matches = worktreesByPath[path], matches.count == 1,
                let branch = matches.first?.branch, !branch.isEmpty, branchCounts[branch] == 1
            else { continue }
            candidates[branch, default: []].append(workspace.id)
        }
        return candidates.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    private static func group(
        root: String,
        snapshot: WorkspaceStackSnapshot,
        dependents: [String: [String]],
        bindings: [String: UUID],
        positions: [UUID: Int]
    ) -> WorkspaceStackGroup? {
        let parents = snapshot.parents
        let subtreePositions = subtreePositions(
            root: root, parents: parents, dependents: dependents, bindings: bindings, positions: positions
        )
        guard subtreePositions.keys.filter({ bindings[$0] != nil }).count >= 2 else { return nil }
        var orderedDependents: [String: [String]] = [:]
        for branch in subtreePositions.keys {
            orderedDependents[branch] = (dependents[branch] ?? []).sorted {
                let first = subtreePositions[$0] ?? Int.max
                let second = subtreePositions[$1] ?? Int.max
                return first == second ? $0 < $1 : first < second
            }
        }
        func visibleDependents(of branch: String) -> [String] {
            (orderedDependents[branch] ?? []).filter { subtreePositions[$0] != nil }
        }
        var start = root
        while bindings[start] == nil {
            let children = visibleDependents(of: start)
            guard children.count == 1, let child = children.first, bindings[child] == nil else { break }
            start = child
        }

        var rows: [WorkspaceStackRow] = []
        var pendingRows = [(branch: start, lane: 0)]
        while let (branch, lane) = pendingRows.popLast() {
            rows.append(
                WorkspaceStackRow(
                    branch: branch, parentBranch: parents[branch],
                    dependentBranches: orderedDependents[branch] ?? [],
                    workspaceId: bindings[branch], lane: lane, issue: snapshot.conflicts[branch]
                ))
            let children = visibleDependents(of: branch)
            let childLane = lane + (children.count > 1 ? 1 : 0)
            pendingRows.append(contentsOf: children.reversed().map { (branch: $0, lane: childLane) })
        }
        let parent = parents[root] ?? ""
        return WorkspaceStackGroup(
            id: "gh-stack:\(parent.utf8.count):\(parent):\(root.utf8.count):\(root)",
            baseBranch: parents[start], rows: rows
        )
    }

    private static func subtreePositions(
        root: String,
        parents: [String: String],
        dependents: [String: [String]],
        bindings: [String: UUID],
        positions: [UUID: Int]
    ) -> [String: Int] {
        var branches: [String] = []
        var pending = [root]
        var visited = Set<String>()
        while let branch = pending.popLast() {
            guard visited.insert(branch).inserted else { continue }
            branches.append(branch)
            pending.append(contentsOf: dependents[branch] ?? [])
        }
        var result: [String: Int] = [:]
        for branch in branches.reversed() {
            if let workspaceId = bindings[branch], let position = positions[workspaceId] {
                result[branch] = min(result[branch] ?? Int.max, position)
            }
            if branch != root, let position = result[branch], let parent = parents[branch] {
                result[parent] = min(result[parent] ?? Int.max, position)
            }
        }
        return result
    }
}
