import SwiftUI

@MainActor
final class WorkspaceFilesViewModel: ObservableObject {
    @Published private(set) var state: WorkspaceFileTreeLoadState = .idle
    @Published private(set) var isRefreshing = false
    @Published private(set) var loadingDirectoryPaths: Set<String> = []
    @Published private(set) var directoryErrors: [String: WorkspaceFileTreeDirectoryError] = [:]

    private let provider: any WorkspaceFileTreeProviding
    private let fileOperator: any WorkspaceFileOperating
    private let filePrompter: any WorkspaceFileOperationPrompting
    private let relativePathClipboard: any WorkspaceRelativePathCopying
    private var activeRequest: WorkspaceFileTreeRequest?
    private var requestGeneration: UInt64 = 0
    private var directoryLoadGenerations: [String: UInt64] = [:]

    init(
        provider: any WorkspaceFileTreeProviding = FileManagerWorkspaceFileTreeProvider(),
        fileOperator: any WorkspaceFileOperating = FileManagerWorkspaceFileOperator(),
        filePrompter: any WorkspaceFileOperationPrompting = AlertWorkspaceFileOperationPrompter(),
        relativePathClipboard: any WorkspaceRelativePathCopying = PasteboardWorkspaceRelativePathClipboard()
    ) {
        self.provider = provider
        self.fileOperator = fileOperator
        self.filePrompter = filePrompter
        self.relativePathClipboard = relativePathClipboard
    }
}

extension WorkspaceFilesViewModel {
    func reset() {
        activate(request: nil)
    }

    func activate(request: WorkspaceFileTreeRequest?) {
        guard activeRequest != request else { return }
        invalidateRequests()
        activeRequest = request
        state = request == nil ? .idle : .loading
        isRefreshing = false
        loadingDirectoryPaths = []
        directoryLoadGenerations = [:]
        directoryErrors = [:]
    }

    func refresh(request: WorkspaceFileTreeRequest) async {
        guard !(isRefreshing && activeRequest == request) else { return }

        let directoryPathsToReload = reloadableDirectoryPaths(for: request)
        invalidateRequests()
        let generation = requestGeneration
        let previousRequest = activeRequest
        activeRequest = request
        isRefreshing = true
        loadingDirectoryPaths = []
        directoryLoadGenerations = [:]
        if case .loaded(let snapshot) = state, snapshot.request == request, previousRequest == request {
            // Keep the previous tree visible during quick refreshes.
        } else {
            state = .loading
        }
        defer {
            if requestGeneration == generation, activeRequest == request {
                isRefreshing = false
            }
        }

        let result = await provider.loadTree(request: request)
        guard !Task.isCancelled,
            requestGeneration == generation,
            activeRequest == request
        else {
            return
        }

        switch result {
        case .loaded(let snapshot):
            await applyLoadedSnapshot(
                snapshot,
                reloading: directoryPathsToReload,
                request: request,
                generation: generation
            )
        case .missingDirectory(let path):
            state = .missingDirectory(path: path)
        case .error(let path, let message):
            state = .error(path: path, message: message)
        case .idle, .loading:
            state = result
        }
    }

    private func applyLoadedSnapshot(
        _ snapshot: WorkspaceFileTreeSnapshot,
        reloading directoryPaths: [String],
        request: WorkspaceFileTreeRequest,
        generation: UInt64
    ) async {
        guard snapshot.rootPath == request.rootPath else {
            state = .error(path: snapshot.rootPath, message: "Workspace root changed while loading")
            return
        }
        let rebuiltSnapshot = WorkspaceFileTreeSnapshot(
            request: request,
            rootPath: snapshot.rootPath,
            nodes: snapshot.nodes,
            fileCount: snapshot.fileCount,
            directoryCount: snapshot.directoryCount,
            totalEntryCount: snapshot.totalEntryCount,
            omittedEntryCount: snapshot.omittedEntryCount,
            isCapped: snapshot.isCapped,
            loadedDirectoryPaths: snapshot.loadedDirectoryPaths
        )
        guard
            let result = await reloadDirectories(
                directoryPaths,
                into: rebuiltSnapshot,
                request: request,
                generation: generation
            )
        else { return }

        state = .loaded(result.snapshot)
        directoryErrors = result.errors
    }

    private func reloadDirectories(
        _ directoryPaths: [String],
        into initialSnapshot: WorkspaceFileTreeSnapshot,
        request: WorkspaceFileTreeRequest,
        generation: UInt64
    ) async -> (
        snapshot: WorkspaceFileTreeSnapshot,
        errors: [String: WorkspaceFileTreeDirectoryError]
    )? {
        var snapshot = initialSnapshot
        var errors: [String: WorkspaceFileTreeDirectoryError] = [:]

        for directoryPath in directoryPaths {
            let result = await provider.loadChildren(
                request: request,
                directoryPath: directoryPath
            )
            guard isCurrent(request: request, generation: generation) else { return nil }

            switch result {
            case .loaded(let directory):
                if let merged = mergedSnapshot(directory: directory, into: snapshot, request: request) {
                    snapshot = merged
                }
            case .missingDirectory:
                break
            case .error(let path, let message):
                if WorkspaceFileTree.containsDirectory(path: directoryPath, in: snapshot.nodes) {
                    errors[directoryPath] = WorkspaceFileTreeDirectoryError(path: path, message: message)
                }
            }
        }
        return (snapshot, errors)
    }

    private func isCurrent(request: WorkspaceFileTreeRequest, generation: UInt64) -> Bool {
        !Task.isCancelled && requestGeneration == generation && activeRequest == request
    }

    func loadChildren(request: WorkspaceFileTreeRequest, directoryPath: String) async {
        guard case .loaded(let snapshot) = state,
            snapshot.request == request,
            activeRequest == request,
            !snapshot.loadedDirectoryPaths.contains(directoryPath),
            !loadingDirectoryPaths.contains(directoryPath)
        else {
            return
        }

        let generation = requestGeneration
        loadingDirectoryPaths.insert(directoryPath)
        directoryLoadGenerations[directoryPath] = generation
        defer { finishDirectoryLoad(directoryPath: directoryPath, generation: generation) }

        let result = await provider.loadChildren(
            request: request,
            directoryPath: directoryPath
        )
        guard !Task.isCancelled,
            requestGeneration == generation,
            activeRequest == request
        else {
            return
        }

        switch result {
        case .loaded(let directory):
            guard case .loaded(let current) = state,
                current.request == request,
                current.rootPath == directory.rootPath
            else {
                return
            }

            guard
                let merged = mergedSnapshot(
                    directory: directory,
                    into: current,
                    request: request
                )
            else { return }
            state = .loaded(merged)
            directoryErrors[directoryPath] = nil
        case .missingDirectory(let path):
            directoryErrors[directoryPath] = WorkspaceFileTreeDirectoryError(
                path: path,
                message: "Directory not found"
            )
        case .error(let path, let message):
            directoryErrors[directoryPath] = WorkspaceFileTreeDirectoryError(
                path: path,
                message: message
            )
        }
    }

    func copyFile(rootPath: String, path: String) {
        do {
            try fileOperator.copyFile(rootPath: rootPath, path: path)
        } catch {
            filePrompter.showFailure(
                title: "Copy Failed",
                message: error.localizedDescription
            )
        }
    }

    func copyRelativePath(_ path: String) {
        relativePathClipboard.copyRelativePath(path)
    }

    func deleteFile(request: WorkspaceFileTreeRequest, path: String) async -> Bool {
        do {
            try await fileOperator.deleteFile(rootPath: request.rootPath, path: path)
            guard activeRequest == request else { return true }
            await refresh(request: request)
            return true
        } catch {
            filePrompter.showFailure(
                title: "Delete Failed",
                message: error.localizedDescription
            )
            return false
        }
    }

    func renameFileWithPrompt(request: WorkspaceFileTreeRequest, path: String) async -> String? {
        let currentName = (path as NSString).lastPathComponent
        guard let newName = filePrompter.promptRename(currentName: currentName) else { return nil }
        do {
            let newPath = try await fileOperator.renameFile(
                rootPath: request.rootPath,
                path: path,
                newName: newName
            )
            guard activeRequest == request else { return newPath }
            await refresh(request: request)
            return newPath
        } catch {
            filePrompter.showFailure(
                title: "Rename Failed",
                message: error.localizedDescription
            )
            return nil
        }
    }

    func isCurrent(_ request: WorkspaceFileTreeRequest) -> Bool {
        activeRequest == request
    }

    private func invalidateRequests() {
        requestGeneration &+= 1
    }

    private func reloadableDirectoryPaths(for request: WorkspaceFileTreeRequest) -> [String] {
        guard case .loaded(let snapshot) = state,
            snapshot.request == request,
            activeRequest == request
        else {
            return []
        }

        return snapshot.loadedDirectoryPaths
            .union(loadingDirectoryPaths)
            .union(directoryErrors.keys)
            .filter { !$0.isEmpty }
            .sorted { lhs, rhs in
                let lhsDepth = lhs.split(separator: "/").count
                let rhsDepth = rhs.split(separator: "/").count
                if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
    }

    private func mergedSnapshot(
        directory: WorkspaceFileTreeDirectorySnapshot,
        into current: WorkspaceFileTreeSnapshot,
        request: WorkspaceFileTreeRequest
    ) -> WorkspaceFileTreeSnapshot? {
        guard current.request == request,
            current.rootPath == directory.rootPath,
            WorkspaceFileTree.containsDirectory(
                path: directory.directoryPath,
                in: current.nodes
            )
        else {
            return nil
        }

        let remainingBudget = max(
            0,
            WorkspaceFileTreeSnapshot.displayedEntryLimit - current.displayedEntryCount
        )
        let displayedNodes = Array(directory.nodes.prefix(remainingBudget))
        let displayedDirectoryCounts = WorkspaceFileTree.countEntries(nodes: displayedNodes)
        let displayedDirectoryEntryCount =
            displayedDirectoryCounts.files
            + displayedDirectoryCounts.directories
        let omittedDirectoryEntryCount = max(
            directory.omittedEntryCount,
            directory.totalEntryCount - displayedDirectoryEntryCount
        )
        let updatedNodes = WorkspaceFileTree.replacingChildren(
            in: current.nodes,
            directoryPath: directory.directoryPath,
            with: displayedNodes
        )
        let counts = WorkspaceFileTree.countEntries(nodes: updatedNodes)
        let omittedEntryCount = current.omittedEntryCount + omittedDirectoryEntryCount
        return WorkspaceFileTreeSnapshot(
            request: request,
            rootPath: current.rootPath,
            nodes: updatedNodes,
            fileCount: counts.files,
            directoryCount: counts.directories,
            totalEntryCount: current.totalEntryCount + directory.totalEntryCount,
            omittedEntryCount: omittedEntryCount,
            isCapped: omittedEntryCount > 0,
            loadedDirectoryPaths: current.loadedDirectoryPaths.union([directory.directoryPath])
        )
    }

    private func finishDirectoryLoad(directoryPath: String, generation: UInt64) {
        guard directoryLoadGenerations[directoryPath] == generation else { return }
        directoryLoadGenerations[directoryPath] = nil
        loadingDirectoryPaths.remove(directoryPath)
    }
}
