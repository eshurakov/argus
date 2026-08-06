import AppKit
import SwiftUI

// Source membership is explicit in project.pbxproj, which this refactor must not modify.

struct GitFileTreeNode: Identifiable, Equatable {
    enum Content: Equatable {
        case directory(children: [GitFileTreeNode])
        case file(GitFileChange)
    }

    let id: String
    let name: String
    let path: String
    let content: Content

    var children: [GitFileTreeNode] {
        guard case .directory(let children) = content else { return [] }
        return children
    }

    var file: GitFileChange? {
        guard case .file(let file) = content else { return nil }
        return file
    }
}

struct GitFileTreeRow: Identifiable, Equatable {
    enum Content: Equatable {
        case directory(GitFileTreeNode)
        case file(GitFileChange)
    }

    let id: String
    let name: String
    let depth: Int
    let content: Content
}

enum GitFileTree {
    static func makeNodes(files: [GitFileChange]) -> [GitFileTreeNode] {
        var root = DirectoryBuilder()
        for file in files {
            let components = file.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            root.insert(file: file, components: components[...])
        }
        return root.nodes(prefix: "", sectionKey: files.first?.sectionKey ?? "")
    }

    static func visibleRows(
        nodes: [GitFileTreeNode],
        collapsedDirectoryIds: Set<String>
    ) -> [GitFileTreeRow] {
        rows(nodes: nodes, depth: 0, collapsedDirectoryIds: collapsedDirectoryIds)
    }

    private static func rows(
        nodes: [GitFileTreeNode],
        depth: Int,
        collapsedDirectoryIds: Set<String>
    ) -> [GitFileTreeRow] {
        nodes.flatMap { node in
            switch node.content {
            case .directory(let children):
                let directoryRow = GitFileTreeRow(
                    id: node.id,
                    name: node.name,
                    depth: depth,
                    content: .directory(node)
                )
                guard !collapsedDirectoryIds.contains(node.id) else { return [directoryRow] }
                return [directoryRow]
                    + rows(
                        nodes: children,
                        depth: depth + 1,
                        collapsedDirectoryIds: collapsedDirectoryIds
                    )
            case .file(let file):
                return [
                    GitFileTreeRow(
                        id: node.id,
                        name: node.name,
                        depth: depth,
                        content: .file(file)
                    )
                ]
            }
        }
    }

    private struct DirectoryBuilder {
        var directories: [String: DirectoryBuilder] = [:]
        var files: [GitFileChange] = []

        mutating func insert(file: GitFileChange, components: ArraySlice<String>) {
            guard let component = components.first else { return }
            guard components.count > 1 else {
                files.append(file)
                return
            }

            var directory = directories[component, default: DirectoryBuilder()]
            directory.insert(file: file, components: components.dropFirst())
            directories[component] = directory
        }

        func nodes(prefix: String, sectionKey: String) -> [GitFileTreeNode] {
            let directoryNodes = directories.keys.sorted().map { directoryName in
                compactedDirectoryNode(
                    name: directoryName,
                    builder: directories[directoryName]!,
                    prefix: prefix,
                    sectionKey: sectionKey
                )
            }
            let fileNodes = files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                .map { file in
                    GitFileTreeNode(
                        id: file.id,
                        name: file.path.split(separator: "/").last.map(String.init) ?? file.path,
                        path: file.path,
                        content: .file(file)
                    )
                }
            return directoryNodes + fileNodes
        }

        private func compactedDirectoryNode(
            name: String,
            builder: DirectoryBuilder,
            prefix: String,
            sectionKey: String
        ) -> GitFileTreeNode {
            var names = [name]
            var path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            var directory = builder

            while directory.files.isEmpty, directory.directories.count == 1,
                let nextName = directory.directories.keys.first,
                let nextDirectory = directory.directories[nextName]
            {
                names.append(nextName)
                path += "/\(nextName)"
                directory = nextDirectory
            }

            return GitFileTreeNode(
                id: "\(sectionKey):directory:\(path)",
                name: names.joined(separator: " / "),
                path: path,
                content: .directory(children: directory.nodes(prefix: path, sectionKey: sectionKey))
            )
        }
    }
}

enum GitFileRowAction: String, Identifiable {
    case stage
    case unstage
    case discard
    case delete
    case addToGitignore
    case diff
    case blame
    case copyPath

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stage:
            return "Stage File"
        case .unstage:
            return "Unstage File"
        case .discard:
            return "Discard Changes"
        case .delete:
            return "Delete File"
        case .addToGitignore:
            return "Add to .gitignore"
        case .diff:
            return "View Diff"
        case .blame:
            return "View Blame"
        case .copyPath:
            return "Copy Path"
        }
    }

    var systemImage: String {
        switch self {
        case .stage:
            return "plus.circle"
        case .unstage:
            return "minus.circle"
        case .discard:
            return "arrow.uturn.backward.circle"
        case .delete:
            return "trash"
        case .addToGitignore:
            return "line.3.horizontal.decrease.circle"
        case .diff:
            return "doc.text.magnifyingglass"
        case .blame:
            return "person.line.dotted.person"
        case .copyPath:
            return "doc.on.doc"
        }
    }

    var operation: GitStatusFileOperation? {
        switch self {
        case .stage:
            return .stage
        case .unstage:
            return .unstage
        case .discard:
            return .discard
        case .delete:
            return .delete
        case .addToGitignore:
            return .addToGitignore
        case .diff, .blame, .copyPath:
            return nil
        }
    }
}

enum GitFileSectionAction: String, Identifiable {
    case stageAll
    case unstageAll
    case discardAll
    case deleteAll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stageAll:
            return "Stage All Files"
        case .unstageAll:
            return "Unstage All Files"
        case .discardAll:
            return "Discard All Changes"
        case .deleteAll:
            return "Delete All Untracked Files"
        }
    }

    var operation: GitStatusFileOperation {
        switch self {
        case .stageAll:
            return .stage
        case .unstageAll:
            return .unstage
        case .discardAll:
            return .discard
        case .deleteAll:
            return .delete
        }
    }

    var isDestructive: Bool {
        operation.requiresConfirmation
    }
}

struct GitChangeSectionContent {
    let title: String
    let sectionKey: String
    let count: Int
    let files: [GitFileChange]
}

struct GitSidebarView: View {
    let showsHeader: Bool
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @EnvironmentObject var viewModel: GitStatusViewModel
    @EnvironmentObject var appSettings: AppSettings
    @State var autoRefreshController = GitStatusAutoRefreshController()
    @State var stagedExpanded = true
    @State var unstagedExpanded = true
    @State var untrackedExpanded = true
    @State var collapsedDirectoryIds: Set<String> = []

    init(showsHeader: Bool = true) {
        self.showsHeader = showsHeader
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            if showsHeader {
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
            }
        }
        .onChange(of: selectedSnapshotOwner, initial: true) { _, owner in
            guard let owner else {
                viewModel.clearSelection()
                autoRefreshController.stop()
                return
            }
            viewModel.activate(owner)
            startAutoRefresh(owner: owner)
            Task { await refresh(owner: owner) }
        }
        .onDisappear {
            autoRefreshController.stop()
        }
    }
}
