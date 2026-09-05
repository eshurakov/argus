import ArgusIPC
import Foundation

/// Renders a `workspace.list` result as the left sidebar reads it: Projects in
/// navigation order, Workspace Numbers in the gutter, and Stack Groups shown
/// as parent-before-dependent trees.
struct WorkspaceListRenderer {
    static let selectedMarker = "*"
    static let dependentMarker = "\u{21B3} "

    let homeDirectory: String

    init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.homeDirectory = homeDirectory
    }

    func lines(for result: WorkspaceListResult) -> [String] {
        result.projects.flatMap { project in projectLines(project) }
    }

    private func projectLines(_ project: ProjectListEntry) -> [String] {
        var lines = [projectHeader(project)]
        if let diagnostic = project.stackDiagnostic {
            lines.append(note(diagnostic))
        }
        guard !project.items.isEmpty else {
            return lines + [gutter(number: nil, isSelected: false) + "(no Workspaces)"]
        }
        for item in project.items {
            switch item {
            case .workspace(let workspace):
                lines.append(workspaceLine(workspace, depth: 0))
            case .stack(let group):
                lines.append(contentsOf: stackLines(group))
            }
        }
        return lines
    }

    private func projectHeader(_ project: ProjectListEntry) -> String {
        var header = project.name
        if let mainBranch = project.mainBranch, !mainBranch.isEmpty {
            header += "  \(mainBranch)"
        }
        if let repositoryPath = project.repositoryPath, !repositoryPath.isEmpty {
            header += "  \(abbreviate(repositoryPath))"
        }
        return header
    }

    private func stackLines(_ group: StackGroupListEntry) -> [String] {
        let base = group.baseBranch ?? "not recorded"
        var lines = [gutter(number: nil, isSelected: false) + "stack  base \(base)"]
        let depths = Self.depths(of: group)
        for row in group.rows {
            let depth = (depths[row.branch] ?? 0) + 1
            if let workspace = row.workspace {
                lines.append(workspaceLine(workspace, depth: depth))
            } else {
                lines.append(
                    gutter(number: nil, isSelected: false)
                        + indent(depth) + "\(row.branch)  (branch reference)"
                )
            }
            if let issue = row.issue {
                lines.append(note(issue))
            }
        }
        return lines
    }

    private func workspaceLine(_ workspace: WorkspaceListEntry, depth: Int) -> String {
        var line = gutter(number: workspace.number, isSelected: workspace.isSelected)
        line += indent(depth) + workspace.title
        if let branch = workspace.branch, branch != workspace.title {
            line += "  \(branch)"
        }
        line += "  [\(workspace.kind.rawValue)]"
        if workspace.kind == .standalone {
            line += "  \(abbreviate(workspace.root))"
        }
        return line
    }

    /// Depth of every branch inside one Stack Group, so dependents render
    /// under the parent they actually record.
    private static func depths(of group: StackGroupListEntry) -> [String: Int] {
        let parents = Dictionary(
            group.rows.map { ($0.branch, $0.parentBranch) },
            uniquingKeysWith: { first, _ in first }
        )
        var depths: [String: Int] = [:]
        for row in group.rows {
            var depth = 0
            var branch = row.branch
            var visited: Set<String> = [branch]
            while let parent = parents[branch] ?? nil, parents.keys.contains(parent),
                visited.insert(parent).inserted
            {
                depth += 1
                branch = parent
            }
            depths[row.branch] = depth
        }
        return depths
    }

    private func gutter(number: Int?, isSelected: Bool) -> String {
        let position = number.map(String.init) ?? ""
        let marker = isSelected ? Self.selectedMarker : " "
        return String(repeating: " ", count: max(0, 3 - position.count)) + position + " \(marker) "
    }

    private func indent(_ depth: Int) -> String {
        guard depth > 1 else { return "" }
        return String(repeating: "  ", count: depth - 1) + Self.dependentMarker
    }

    private func note(_ text: String) -> String {
        gutter(number: nil, isSelected: false) + "! \(text)"
    }

    private func abbreviate(_ path: String) -> String {
        guard !homeDirectory.isEmpty else { return path }
        if path == homeDirectory { return "~" }
        guard path.hasPrefix(homeDirectory + "/") else { return path }
        return "~" + path.dropFirst(homeDirectory.count)
    }
}
