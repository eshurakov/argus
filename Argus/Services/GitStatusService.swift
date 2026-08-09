import Foundation

protocol GitStatusProviding: Sendable {
    func status(rootPath: String) async -> GitStatusLoadState
    func status(request: GitStatusRequest) async -> GitStatusLoadState
    func initializeRepository(rootPath: String) async -> GitStatusLoadState
    func initializeRepository(request: GitStatusRequest) async -> GitStatusLoadState
    func performFileOperation(
        _ operation: GitStatusFileOperation,
        rootPath: String,
        path: String
    ) async -> GitStatusLoadState
    func performFileOperation(
        _ operation: GitStatusFileOperation,
        request: GitStatusRequest,
        path: String
    ) async -> GitStatusLoadState
    func performBulkFileOperation(
        _ operation: GitStatusFileOperation,
        rootPath: String,
        paths: [String]
    ) async -> GitStatusLoadState
    func performBulkFileOperation(
        _ operation: GitStatusFileOperation,
        request: GitStatusRequest,
        paths: [String]
    ) async -> GitStatusLoadState
    func performSectionFileOperation(
        _ operation: GitStatusFileOperation,
        rootPath: String,
        sectionKey: String
    ) async -> GitStatusLoadState
    func performSectionFileOperation(
        _ operation: GitStatusFileOperation,
        request: GitStatusRequest,
        sectionKind: GitChangeSectionKind
    ) async -> GitStatusLoadState
}

extension GitStatusProviding {
    func status(request: GitStatusRequest) async -> GitStatusLoadState {
        await status(rootPath: request.rootPath)
    }

    func initializeRepository(request: GitStatusRequest) async -> GitStatusLoadState {
        await initializeRepository(rootPath: request.rootPath)
    }

    func performFileOperation(
        _ operation: GitStatusFileOperation,
        request: GitStatusRequest,
        path: String
    ) async -> GitStatusLoadState {
        await performFileOperation(operation, rootPath: request.rootPath, path: path)
    }

    func performBulkFileOperation(
        _ operation: GitStatusFileOperation,
        request: GitStatusRequest,
        paths: [String]
    ) async -> GitStatusLoadState {
        await performBulkFileOperation(operation, rootPath: request.rootPath, paths: paths)
    }

    func performSectionFileOperation(
        _ operation: GitStatusFileOperation,
        request: GitStatusRequest,
        sectionKind: GitChangeSectionKind
    ) async -> GitStatusLoadState {
        await performSectionFileOperation(
            operation,
            rootPath: request.rootPath,
            sectionKey: sectionKind.rawValue
        )
    }

    func performSectionFileOperation(
        _ operation: GitStatusFileOperation,
        rootPath: String,
        sectionKey: String
    ) async -> GitStatusLoadState {
        .fileOperationFailed(rootPath: rootPath, message: "Section operation is unavailable")
    }
}

/// Runs git status commands for the active workspace root.
///
/// This service is intentionally not `@MainActor`. Calls execute the blocking
/// `git` process work in a detached task so SwiftUI callers do not block the
/// main actor while status is refreshed.
final class GitStatusService: GitStatusProviding {
    func status(rootPath: String) async -> GitStatusLoadState {
        await status(request: GitStatusRequest(rootPath: rootPath))
    }

    func status(request: GitStatusRequest) async -> GitStatusLoadState {
        await Task.detached(priority: .utility) {
            statusSynchronously(request: request)
        }.value
    }

    func initializeRepository(rootPath: String) async -> GitStatusLoadState {
        await initializeRepository(request: GitStatusRequest(rootPath: rootPath))
    }

    func initializeRepository(request: GitStatusRequest) async -> GitStatusLoadState {
        await Task.detached(priority: .utility) {
            do {
                _ = try runGit(args: ["-C", request.rootPath, "init"])
                return statusSynchronously(request: request)
            } catch let error as GitStatusServiceError {
                return .repositoryInitializationFailed(rootPath: request.rootPath, message: error.message)
            } catch {
                return .repositoryInitializationFailed(
                    rootPath: request.rootPath,
                    message: error.localizedDescription
                )
            }
        }.value
    }

    func performFileOperation(
        _ operation: GitStatusFileOperation,
        rootPath: String,
        path: String
    ) async -> GitStatusLoadState {
        await performFileOperation(
            operation,
            request: GitStatusRequest(rootPath: rootPath),
            path: path
        )
    }

    func performFileOperation(
        _ operation: GitStatusFileOperation,
        request: GitStatusRequest,
        path: String
    ) async -> GitStatusLoadState {
        await performBulkFileOperation(operation, request: request, paths: [path])
    }

    func performBulkFileOperation(
        _ operation: GitStatusFileOperation,
        rootPath: String,
        paths: [String]
    ) async -> GitStatusLoadState {
        await performBulkFileOperation(
            operation,
            request: GitStatusRequest(rootPath: rootPath),
            paths: paths
        )
    }

    func performBulkFileOperation(
        _ operation: GitStatusFileOperation,
        request: GitStatusRequest,
        paths: [String]
    ) async -> GitStatusLoadState {
        await Task.detached(priority: .utility) {
            do {
                try performOperationSynchronously(operation, rootPath: request.rootPath, paths: paths)
                return statusSynchronously(request: request)
            } catch let error as GitStatusServiceError {
                return .fileOperationFailed(rootPath: request.rootPath, message: error.message)
            } catch {
                return .fileOperationFailed(rootPath: request.rootPath, message: error.localizedDescription)
            }
        }.value
    }

    func performSectionFileOperation(
        _ operation: GitStatusFileOperation,
        rootPath: String,
        sectionKey: String
    ) async -> GitStatusLoadState {
        await performSectionFileOperation(
            operation,
            request: GitStatusRequest(rootPath: rootPath),
            sectionKind: GitChangeSectionKind(rawValue: sectionKey) ?? .unstaged
        )
    }

    func performSectionFileOperation(
        _ operation: GitStatusFileOperation,
        request: GitStatusRequest,
        sectionKind: GitChangeSectionKind
    ) async -> GitStatusLoadState {
        await Task.detached(priority: .utility) {
            do {
                try performSectionOperationSynchronously(
                    operation,
                    rootPath: request.rootPath,
                    sectionKind: sectionKind
                )
                return statusSynchronously(request: request)
            } catch let error as GitStatusServiceError {
                return .fileOperationFailed(rootPath: request.rootPath, message: error.message)
            } catch {
                return .fileOperationFailed(rootPath: request.rootPath, message: error.localizedDescription)
            }
        }.value
    }
}

func verifyGitRef(rootPath: String, ref: String) -> Bool {
    optionalGitOutput(args: ["-C", rootPath, "rev-parse", "--verify", "--quiet", "\(ref)^{commit}"]) != nil
}

func optionalGitOutput(args: [String]) -> String? {
    guard let result = try? runGit(args: args) else { return nil }
    let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return output.isEmpty ? nil : output
}

func diffStatsForUntrackedFiles(rootPath: String, files: [GitFileChange]) -> [String: GitDiffStat] {
    var stats: [String: GitDiffStat] = [:]
    let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
    let rootPathWithSlash = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"

    for file in files {
        let fileURL = rootURL.appendingPathComponent(file.path).standardizedFileURL
        guard fileURL.path.hasPrefix(rootPathWithSlash),
            let data = try? Data(contentsOf: fileURL)
        else { continue }

        if data.contains(0) {
            stats[file.path] = GitDiffStat(additions: nil, deletions: nil, isBinary: true)
        } else {
            stats[file.path] = GitDiffStat(
                additions: lineCount(in: data),
                deletions: 0,
                isBinary: false
            )
        }
    }

    return stats
}

private func lineCount(in data: Data) -> Int {
    guard !data.isEmpty else { return 0 }
    let newline = UInt8(ascii: "\n")
    let count = data.reduce(0) { partial, byte in
        partial + (byte == newline ? 1 : 0)
    }
    return data.last == newline ? count : count + 1
}

func deletePath(rootPath: String, path: String) throws {
    let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
    let targetURL = rootURL.appendingPathComponent(path).standardizedFileURL
    let rootPathWithSlash = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
    guard targetURL.path == rootURL.path || targetURL.path.hasPrefix(rootPathWithSlash) else {
        throw GitStatusServiceError.commandFailed("Refusing to delete a path outside the repository root")
    }
    try FileManager.default.removeItem(at: targetURL)
}

func addPathToGitignore(rootPath: String, path: String) throws {
    guard !path.isEmpty,
        !path.hasPrefix("/"),
        !path.contains("\n"),
        !path.contains("\r"),
        !path.contains("\0")
    else {
        throw GitStatusServiceError.commandFailed("Refusing to add an invalid path to .gitignore")
    }

    let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
    let relativePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let targetURL = rootURL.appendingPathComponent(relativePath).standardizedFileURL
    let rootPathWithSlash = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
    guard targetURL.path.hasPrefix(rootPathWithSlash), targetURL.path != rootURL.path else {
        throw GitStatusServiceError.commandFailed("Refusing to add a path outside the repository root")
    }

    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else {
        throw GitStatusServiceError.commandFailed("The untracked path no longer exists")
    }

    let entry = isDirectory.boolValue ? "\(relativePath)/" : relativePath
    let gitignoreURL = rootURL.appendingPathComponent(".gitignore")
    let existing: String
    if FileManager.default.fileExists(atPath: gitignoreURL.path) {
        do {
            existing = try String(contentsOf: gitignoreURL, encoding: .utf8)
        } catch {
            throw GitStatusServiceError.commandFailed("Unable to read .gitignore: \(error.localizedDescription)")
        }
    } else {
        existing = ""
    }

    let existingEntries = existing.split(whereSeparator: { character in
        character == "\n" || character == "\r"
    })
    guard !existingEntries.contains(where: { String($0) == entry }) else { return }

    var updated = existing
    if !updated.isEmpty && !updated.hasSuffix("\n") && !updated.hasSuffix("\r") {
        updated.append("\n")
    }
    updated.append(entry)
    updated.append("\n")

    do {
        try updated.write(to: gitignoreURL, atomically: true, encoding: .utf8)
    } catch {
        throw GitStatusServiceError.commandFailed("Unable to update .gitignore: \(error.localizedDescription)")
    }
}

struct GitCommandResult: Sendable {
    let stdout: String
    let stderr: String
}

final class GitStatusDataBox: @unchecked Sendable {
    var data = Data()
}

func runGit(args: [String]) throws -> GitCommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.environment = ProcessInfo.processInfo.environment.merging([
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "echo"
    ]) { _, new in new }

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    let outputGroup = DispatchGroup()
    let stdoutBox = GitStatusDataBox()
    let stderrBox = GitStatusDataBox()
    outputGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        stdoutBox.data = stdout.fileHandleForReading.readDataToEndOfFile()
        outputGroup.leave()
    }
    outputGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        stderrBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
        outputGroup.leave()
    }
    process.waitUntilExit()
    outputGroup.wait()

    let stdoutText = String(data: stdoutBox.data, encoding: .utf8) ?? ""
    let stderrText = String(data: stderrBox.data, encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        if stderrText.contains("not a git repository") || stderrText.contains("not a git repo") {
            throw GitStatusServiceError.notRepository
        }
        let message = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        throw GitStatusServiceError.commandFailed(message.isEmpty ? "git command failed" : message)
    }

    return GitCommandResult(stdout: stdoutText, stderr: stderrText)
}
