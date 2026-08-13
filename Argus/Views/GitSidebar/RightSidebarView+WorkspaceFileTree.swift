import Foundation

enum WorkspaceFileTree {
    static func makeNodes(entries: [WorkspaceFileTreeEntry]) -> [WorkspaceFileTreeNode] {
        var root = DirectoryBuilder()
        for entry in entries {
            let components = entry.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            if entry.isDirectory {
                root.insertDirectory(components: components[...])
            } else {
                root.insertFile(components: components[...])
            }
        }
        return root.nodes(prefix: "")
    }

    static func makeImmediateNodes(entries: [WorkspaceFileTreeEntry]) -> [WorkspaceFileTreeNode] {
        let directoryNodes =
            entries
            .filter(\.isDirectory)
            .sorted { localizedLessThan($0.path, $1.path) }
            .map { entry in
                WorkspaceFileTreeNode(
                    id: "directory:\(entry.path)",
                    name: displayName(for: entry.path),
                    path: entry.path,
                    content: .directory(children: [])
                )
            }
        let fileNodes =
            entries
            .filter { !$0.isDirectory }
            .sorted { localizedLessThan($0.path, $1.path) }
            .map { entry in
                WorkspaceFileTreeNode(
                    id: "file:\(entry.path)",
                    name: displayName(for: entry.path),
                    path: entry.path,
                    content: .file
                )
            }

        return directoryNodes + fileNodes
    }

    static func visibleRows(
        nodes: [WorkspaceFileTreeNode],
        expandedDirectoryIds: Set<String>
    ) -> [WorkspaceFileTreeRow] {
        rows(nodes: nodes, depth: 0, expandedDirectoryIds: expandedDirectoryIds)
    }

    static func replacingChildren(
        in nodes: [WorkspaceFileTreeNode],
        directoryPath: String,
        with children: [WorkspaceFileTreeNode]
    ) -> [WorkspaceFileTreeNode] {
        nodes.map { node in
            guard case .directory(let existingChildren) = node.content else { return node }
            if node.path == directoryPath {
                return node.replacingChildren(children)
            }
            return node.replacingChildren(
                replacingChildren(in: existingChildren, directoryPath: directoryPath, with: children)
            )
        }
    }

    static func countEntries(nodes: [WorkspaceFileTreeNode]) -> (files: Int, directories: Int) {
        nodes.reduce(into: (files: 0, directories: 0)) { partial, node in
            switch node.content {
            case .directory(let children):
                partial.directories += 1
                let childCounts = countEntries(nodes: children)
                partial.files += childCounts.files
                partial.directories += childCounts.directories
            case .file:
                partial.files += 1
            }
        }
    }

    static func directoryPaths(fromExpandedIds ids: Set<String>) -> [String] {
        ids.compactMap { id in
            guard id.hasPrefix("directory:") else { return nil }
            let path = String(id.dropFirst("directory:".count))
            return path.isEmpty ? nil : path
        }
        .sorted { lhs, rhs in
            let lhsDepth = lhs.split(separator: "/").count
            let rhsDepth = rhs.split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    static func containsDirectory(path: String, in nodes: [WorkspaceFileTreeNode]) -> Bool {
        nodes.contains { node in
            guard case .directory(let children) = node.content else { return false }
            return node.path == path || containsDirectory(path: path, in: children)
        }
    }

    private static func rows(
        nodes: [WorkspaceFileTreeNode],
        depth: Int,
        expandedDirectoryIds: Set<String>
    ) -> [WorkspaceFileTreeRow] {
        nodes.flatMap { node in
            switch node.content {
            case .directory(let children):
                let directoryRow = WorkspaceFileTreeRow(
                    id: node.id,
                    name: node.name,
                    depth: depth,
                    content: .directory(node)
                )
                guard expandedDirectoryIds.contains(node.id) else { return [directoryRow] }
                return [directoryRow]
                    + rows(
                        nodes: children,
                        depth: depth + 1,
                        expandedDirectoryIds: expandedDirectoryIds
                    )
            case .file:
                return [
                    WorkspaceFileTreeRow(
                        id: node.id,
                        name: node.name,
                        depth: depth,
                        content: .file(node)
                    )
                ]
            }
        }
    }

    private static func displayName(for path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func localizedLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private struct DirectoryBuilder {
        var directories: [String: DirectoryBuilder] = [:]
        var files: Set<String> = []

        mutating func insertDirectory(components: ArraySlice<String>) {
            guard let component = components.first else { return }
            guard components.count > 1 else {
                if directories[component] == nil {
                    directories[component] = DirectoryBuilder()
                }
                return
            }

            var directory = directories[component, default: DirectoryBuilder()]
            directory.insertDirectory(components: components.dropFirst())
            directories[component] = directory
        }

        mutating func insertFile(components: ArraySlice<String>) {
            guard let component = components.first else { return }
            guard components.count > 1 else {
                files.insert(component)
                return
            }

            var directory = directories[component, default: DirectoryBuilder()]
            directory.insertFile(components: components.dropFirst())
            directories[component] = directory
        }

        func nodes(prefix: String) -> [WorkspaceFileTreeNode] {
            let directoryNodes = directories.keys.sorted(by: localizedLessThan).map { directoryName in
                let path = prefix.isEmpty ? directoryName : "\(prefix)/\(directoryName)"
                return WorkspaceFileTreeNode(
                    id: "directory:\(path)",
                    name: directoryName,
                    path: path,
                    content: .directory(
                        children: directories[directoryName]!.nodes(prefix: path)
                    )
                )
            }

            let fileNodes = files.sorted(by: localizedLessThan).map { fileName in
                let path = prefix.isEmpty ? fileName : "\(prefix)/\(fileName)"
                return WorkspaceFileTreeNode(
                    id: "file:\(path)",
                    name: fileName,
                    path: path,
                    content: .file
                )
            }

            return directoryNodes + fileNodes
        }

        private func localizedLessThan(_ lhs: String, _ rhs: String) -> Bool {
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}

protocol WorkspaceFileTreeProviding: Sendable {
    func loadTree(request: WorkspaceFileTreeRequest) async -> WorkspaceFileTreeLoadState
    func loadChildren(
        request: WorkspaceFileTreeRequest,
        directoryPath: String
    ) async -> WorkspaceFileTreeDirectoryLoadState
}

struct FileManagerWorkspaceFileTreeProvider: WorkspaceFileTreeProviding {
    func loadTree(request: WorkspaceFileTreeRequest) async -> WorkspaceFileTreeLoadState {
        let task = Task.detached(priority: .userInitiated) {
            WorkspaceFileTreeLoader.load(request: request)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func loadChildren(
        request: WorkspaceFileTreeRequest,
        directoryPath: String
    ) async -> WorkspaceFileTreeDirectoryLoadState {
        let task = Task.detached(priority: .userInitiated) {
            WorkspaceFileTreeLoader.loadChildren(request: request, directoryPath: directoryPath)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

private enum WorkspaceFileTreeLoader {
    static func load(request: WorkspaceFileTreeRequest) -> WorkspaceFileTreeLoadState {
        switch loadDirectory(request: request, directoryPath: "") {
        case .loaded(let directory):
            let counts = WorkspaceFileTree.countEntries(nodes: directory.nodes)
            return .loaded(
                WorkspaceFileTreeSnapshot(
                    rootPath: directory.rootPath,
                    nodes: directory.nodes,
                    fileCount: counts.files,
                    directoryCount: counts.directories,
                    totalEntryCount: directory.totalEntryCount,
                    omittedEntryCount: directory.omittedEntryCount,
                    isCapped: directory.isCapped,
                    loadedDirectoryPaths: [""]
                ))
        case .missingDirectory(let path):
            return .missingDirectory(path: path)
        case .error(let path, let message):
            return .error(path: path, message: message)
        }
    }

    static func loadChildren(
        request: WorkspaceFileTreeRequest,
        directoryPath: String
    ) -> WorkspaceFileTreeDirectoryLoadState {
        loadDirectory(request: request, directoryPath: directoryPath)
    }

    private static func loadDirectory(
        request: WorkspaceFileTreeRequest,
        directoryPath: String
    ) -> WorkspaceFileTreeDirectoryLoadState {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: request.rootPath).standardizedFileURL
        let directoryURL =
            directoryPath.isEmpty
            ? rootURL
            : rootURL.appendingPathComponent(directoryPath, isDirectory: true).standardizedFileURL
        var isDirectory = ObjCBool(false)

        if Task.isCancelled {
            return .error(path: directoryURL.path, message: "Loading cancelled")
        }

        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return .missingDirectory(path: rootURL.path)
        }

        let rootPathWithSlash = rootURL.path.hasSuffix("/") ? rootURL.path : "\(rootURL.path)/"
        guard directoryURL.path == rootURL.path || directoryURL.path.hasPrefix(rootPathWithSlash) else {
            return .error(path: directoryURL.path, message: "Refusing to read outside the workspace root")
        }

        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return .missingDirectory(path: directoryURL.path)
        }

        return loadDirectorySnapshot(
            rootURL: rootURL,
            rootPathWithSlash: rootPathWithSlash,
            directoryURL: directoryURL,
            directoryPath: directoryPath,
            showHiddenFiles: request.showHiddenFiles
        )
    }

    private static func loadDirectorySnapshot(
        rootURL: URL,
        rootPathWithSlash: String,
        directoryURL: URL,
        directoryPath: String,
        showHiddenFiles: Bool
    ) -> WorkspaceFileTreeDirectoryLoadState {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey]
        do {
            let urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsPackageDescendants]
            )
            guard
                let result = collectEntries(
                    urls,
                    rootPathWithSlash: rootPathWithSlash,
                    showHiddenFiles: showHiddenFiles
                )
            else {
                return .error(path: directoryURL.path, message: "Loading cancelled")
            }
            let omittedEntryCount = max(0, result.totalCount - result.entries.count)

            return .loaded(
                WorkspaceFileTreeDirectorySnapshot(
                    rootPath: rootURL.path,
                    directoryPath: directoryPath,
                    nodes: WorkspaceFileTree.makeImmediateNodes(entries: result.entries),
                    totalEntryCount: result.totalCount,
                    omittedEntryCount: omittedEntryCount,
                    isCapped: omittedEntryCount > 0
                ))
        } catch {
            return .error(path: directoryURL.path, message: error.localizedDescription)
        }
    }

    private static func collectEntries(
        _ urls: [URL],
        rootPathWithSlash: String,
        showHiddenFiles: Bool
    ) -> (entries: [WorkspaceFileTreeEntry], totalCount: Int)? {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey]
        var entries: [WorkspaceFileTreeEntry] = []
        var totalCount = 0

        for url in urls {
            if Task.isCancelled { return nil }
            if url.lastPathComponent == ".git" { continue }
            let values = try? url.resourceValues(forKeys: resourceKeys)
            if !showHiddenFiles,
                values?.isHidden == true || url.lastPathComponent.hasPrefix(".")
            {
                continue
            }

            let entryURL = url.standardizedFileURL
            guard entryURL.path.hasPrefix(rootPathWithSlash) else { continue }
            let relativePath = String(entryURL.path.dropFirst(rootPathWithSlash.count))
            guard !relativePath.isEmpty else { continue }

            totalCount += 1
            if entries.count < WorkspaceFileTreeSnapshot.displayedEntryLimit {
                entries.append(
                    WorkspaceFileTreeEntry(
                        path: relativePath,
                        isDirectory: values?.isDirectory == true && values?.isSymbolicLink != true
                    ))
            }
        }
        return (entries, totalCount)
    }
}
