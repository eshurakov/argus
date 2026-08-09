import Foundation

@testable import Argus

struct ViewModelPreviewRequest {
    let kind: GitPreviewKind
    let rootPath: String
    let file: GitFileChange

    var description: String { "\(kind)-\(rootPath)-\(file.path)" }
}

struct ViewModelFileOperationRequest {
    let operation: GitStatusFileOperation
    let rootPath: String
    let path: String

    var description: String { "\(operation)-\(rootPath)-\(path)" }
}

struct ViewModelBulkOperationRequest {
    let operation: GitStatusFileOperation
    let rootPath: String
    let paths: [String]

    var description: String { "\(operation)-\(rootPath)-\(paths.joined(separator: ","))" }
}

struct ViewModelSectionOperationRequest {
    let operation: GitStatusFileOperation
    let rootPath: String
    let sectionKey: String

    var description: String { "\(operation)-\(rootPath)-\(sectionKey)" }
}

final class ObservingStatusService: GitStatusProviding, @unchecked Sendable {
    let result: GitStatusLoadState
    let onStart: @MainActor () -> Void

    init(result: GitStatusLoadState, onStart: @escaping @MainActor () -> Void) {
        self.result = result
        self.onStart = onStart
    }

    func status(rootPath: String) async -> GitStatusLoadState {
        await MainActor.run { onStart() }
        return result
    }

    func initializeRepository(rootPath: String) async -> GitStatusLoadState {
        result
    }

    func performFileOperation(_ operation: GitStatusFileOperation, rootPath: String, path: String)
        async -> GitStatusLoadState
    {
        result
    }

    func performBulkFileOperation(
        _ operation: GitStatusFileOperation, rootPath: String, paths: [String]
    ) async -> GitStatusLoadState {
        result
    }
}

actor SuspendingSectionStatusService: GitStatusProviding {
    let result: GitStatusLoadState
    private var operationContinuation: CheckedContinuation<GitStatusLoadState, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?

    init(result: GitStatusLoadState) {
        self.result = result
    }

    func status(rootPath: String) async -> GitStatusLoadState { result }
    func initializeRepository(rootPath: String) async -> GitStatusLoadState { result }
    func performFileOperation(_ operation: GitStatusFileOperation, rootPath: String, path: String)
        async -> GitStatusLoadState
    { result }
    func performBulkFileOperation(
        _ operation: GitStatusFileOperation, rootPath: String, paths: [String]
    ) async -> GitStatusLoadState { result }

    func performSectionFileOperation(
        _ operation: GitStatusFileOperation, rootPath: String, sectionKey: String
    ) async -> GitStatusLoadState {
        await withCheckedContinuation { continuation in
            operationContinuation = continuation
            startContinuation?.resume()
            startContinuation = nil
        }
    }

    func waitUntilOperationStarts() async {
        if operationContinuation != nil { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func finishOperation() {
        operationContinuation?.resume(returning: result)
        operationContinuation = nil
    }
}

final class ViewModelTestWatcher: FileSystemEventWatching, @unchecked Sendable {
    var onEvents: (@MainActor @Sendable ([String]) -> Void)?

    func start(paths: [String], onEvents: @escaping @MainActor @Sendable ([String]) -> Void) {
        self.onEvents = onEvents
    }

    func stop() {}

    @MainActor
    func emit(paths: [String]) {
        onEvents?(paths)
    }
}

@MainActor
final class ViewModelTestScheduler: RefreshScheduling {
    private var operation: (@MainActor @Sendable () async -> Void)?

    func schedule(
        after delay: TimeInterval, operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.operation = operation
    }

    func cancel() {
        operation = nil
    }

    func runScheduled() async {
        await operation?()
    }
}

final class RecordingFileOperationConfirmer: GitStatusFileOperationConfirming {
    let shouldConfirm: Bool
    private(set) var requests: [GitStatusFileOperation] = []
    private(set) var pathCountRequests: [Int] = []
    private(set) var confirmationTitleRequests: [String] = []

    init(shouldConfirm: Bool) {
        self.shouldConfirm = shouldConfirm
    }

    func confirm(operation: GitStatusFileOperation, paths: [String]) -> Bool {
        requests.append(operation)
        pathCountRequests.append(paths.count)
        return shouldConfirm
    }

    func confirm(operation: GitStatusFileOperation, pathCount: Int) -> Bool {
        requests.append(operation)
        pathCountRequests.append(pathCount)
        return shouldConfirm
    }

    func confirm(
        operation: GitStatusFileOperation,
        pathCount: Int,
        confirmationTitle: String
    ) -> Bool {
        requests.append(operation)
        pathCountRequests.append(pathCount)
        confirmationTitleRequests.append(confirmationTitle)
        return shouldConfirm
    }
}

final class RecordingPathClipboard: GitStatusPathCopying {
    private(set) var copiedPaths: [String] = []

    func copyPath(_ path: String) {
        copiedPaths.append(path)
    }
}

final class RecordingPreviewService: GitPreviewProviding, @unchecked Sendable {
    let result: GitPreviewLoadState
    private(set) var requests: [ViewModelPreviewRequest] = []

    init(result: GitPreviewLoadState) {
        self.result = result
    }

    func preview(kind: GitPreviewKind, rootPath: String, file: GitFileChange) async
        -> GitPreviewLoadState
    {
        requests.append(ViewModelPreviewRequest(kind: kind, rootPath: rootPath, file: file))
        return result
    }
}

final class FakeStatusService: GitStatusProviding, @unchecked Sendable {
    let result: GitStatusLoadState
    let initializeResult: GitStatusLoadState
    let operationResult: GitStatusLoadState
    private(set) var requestedRoots: [String] = []
    private(set) var initializedRoots: [String] = []
    private(set) var operationRequests: [ViewModelFileOperationRequest] = []
    private(set) var bulkOperationRequests: [ViewModelBulkOperationRequest] = []
    private(set) var sectionOperationRequests: [ViewModelSectionOperationRequest] = []

    init(
        result: GitStatusLoadState,
        initializeResult: GitStatusLoadState? = nil,
        operationResult: GitStatusLoadState? = nil
    ) {
        self.result = result
        self.initializeResult = initializeResult ?? result
        self.operationResult = operationResult ?? result
    }

    func status(rootPath: String) async -> GitStatusLoadState {
        requestedRoots.append(rootPath)
        return result
    }

    func initializeRepository(rootPath: String) async -> GitStatusLoadState {
        initializedRoots.append(rootPath)
        return initializeResult
    }

    func performFileOperation(_ operation: GitStatusFileOperation, rootPath: String, path: String)
        async -> GitStatusLoadState
    {
        operationRequests.append(
            ViewModelFileOperationRequest(operation: operation, rootPath: rootPath, path: path))
        return operationResult
    }

    func performBulkFileOperation(
        _ operation: GitStatusFileOperation, rootPath: String, paths: [String]
    ) async -> GitStatusLoadState {
        bulkOperationRequests.append(
            ViewModelBulkOperationRequest(operation: operation, rootPath: rootPath, paths: paths))
        return operationResult
    }

    func performSectionFileOperation(
        _ operation: GitStatusFileOperation, rootPath: String, sectionKey: String
    ) async -> GitStatusLoadState {
        sectionOperationRequests.append(
            ViewModelSectionOperationRequest(
                operation: operation, rootPath: rootPath, sectionKey: sectionKey))
        return operationResult
    }
}
