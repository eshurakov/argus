import Foundation

protocol GitStatusProviding: Sendable {
    func status(rootPath: String) async -> GitStatusLoadState
    func initializeRepository(rootPath: String) async -> GitStatusLoadState
    func performFileOperation(
        _ operation: GitStatusFileOperation,
        rootPath: String,
        path: String
    ) async -> GitStatusLoadState
    func performBulkFileOperation(
        _ operation: GitStatusFileOperation,
        rootPath: String,
        paths: [String]
    ) async -> GitStatusLoadState
    func performSectionFileOperation(
        _ operation: GitStatusFileOperation,
        rootPath: String,
        sectionKey: String
    ) async -> GitStatusLoadState
}

extension GitStatusProviding {
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
    private static let gitPath = "/usr/bin/git"

    func status(rootPath: String) async -> GitStatusLoadState {
        await Task.detached(priority: .utility) {
            statusSynchronously(rootPath: rootPath)
        }.value
    }

    func initializeRepository(rootPath: String) async -> GitStatusLoadState {
        await Task.detached(priority: .utility) {
            do {
                _ = try runGit(args: ["-C", rootPath, "init"])
                return statusSynchronously(rootPath: rootPath)
            } catch let error as GitStatusServiceError {
                switch error {
                case .notRepository:
                    return .repositoryInitializationFailed(rootPath: rootPath, message: "Not a git repository")
                case .commandFailed(let message):
                    return .repositoryInitializationFailed(rootPath: rootPath, message: message)
                }
            } catch {
                return .repositoryInitializationFailed(rootPath: rootPath, message: error.localizedDescription)
            }
        }.value
    }

    func performFileOperation(
        _ operation: GitStatusFileOperation,
        rootPath: String,
        path: String
    ) async -> GitStatusLoadState {
        await performBulkFileOperation(operation, rootPath: rootPath, paths: [path])
    }

    func performBulkFileOperation(
        _ operation: GitStatusFileOperation,
        rootPath: String,
        paths: [String]
    ) async -> GitStatusLoadState {
        await Task.detached(priority: .utility) {
            do {
                try performOperationSynchronously(operation, rootPath: rootPath, paths: paths)
                return statusSynchronously(rootPath: rootPath)
            } catch let error as GitStatusServiceError {
                switch error {
                case .notRepository:
                    return .fileOperationFailed(rootPath: rootPath, message: "Not a git repository")
                case .commandFailed(let message):
                    return .fileOperationFailed(rootPath: rootPath, message: message)
                }
            } catch {
                return .fileOperationFailed(rootPath: rootPath, message: error.localizedDescription)
            }
        }.value
    }

    func performSectionFileOperation(
        _ operation: GitStatusFileOperation,
        rootPath: String,
        sectionKey: String
    ) async -> GitStatusLoadState {
        await Task.detached(priority: .utility) {
            do {
                try performSectionOperationSynchronously(operation, rootPath: rootPath, sectionKey: sectionKey)
                return statusSynchronously(rootPath: rootPath)
            } catch let error as GitStatusServiceError {
                switch error {
                case .notRepository:
                    return .fileOperationFailed(rootPath: rootPath, message: "Not a git repository")
                case .commandFailed(let message):
                    return .fileOperationFailed(rootPath: rootPath, message: message)
                }
            } catch {
                return .fileOperationFailed(rootPath: rootPath, message: error.localizedDescription)
            }
        }.value
    }
}

private enum GitStatusServiceError: Error {
    case notRepository
    case commandFailed(String)
}

private func performOperationSynchronously(
    _ operation: GitStatusFileOperation,
    rootPath: String,
    paths: [String]
) throws {
    switch operation {
    case .stage:
        _ = try runGit(args: ["-C", rootPath, "add", "--"] + paths)
    case .unstage:
        _ = try runGit(args: ["-C", rootPath, "restore", "--staged", "--"] + paths)
    case .discard:
        _ = try runGit(args: ["-C", rootPath, "restore", "--"] + paths)
    case .delete:
        for path in paths {
            try deletePath(rootPath: rootPath, path: path)
        }
    case .addToGitignore:
        for path in paths {
            try addPathToGitignore(rootPath: rootPath, path: path)
        }
    }
}

private func performSectionOperationSynchronously(
    _ operation: GitStatusFileOperation,
    rootPath: String,
    sectionKey: String
) throws {
    switch (sectionKey, operation) {
    case ("staged", .unstage):
        _ = try runGit(args: ["-C", rootPath, "restore", "--staged", "--", "."])
    case ("unstaged", .stage):
        _ = try runGit(args: ["-C", rootPath, "add", "-u", "--", "."])
    case ("unstaged", .discard):
        _ = try runGit(args: ["-C", rootPath, "restore", "--", "."])
    case ("untracked", .stage):
        let untrackedPaths = try allUntrackedPaths(rootPath: rootPath)
        if !untrackedPaths.isEmpty {
            _ = try runGit(args: ["-C", rootPath, "add", "--"] + untrackedPaths)
        }
    case ("untracked", .delete):
        _ = try runGit(args: ["-C", rootPath, "clean", "-fd", "--", "."])
    default:
        throw GitStatusServiceError.commandFailed("Unsupported section file operation")
    }
}

private func allUntrackedPaths(rootPath: String) throws -> [String] {
    let result = try runGit(args: ["-C", rootPath, "ls-files", "--others", "--exclude-standard", "-z"])
    return result.stdout
        .split(separator: "\u{0}", omittingEmptySubsequences: true)
        .map(String.init)
}

private func statusSynchronously(rootPath: String) -> GitStatusLoadState {
    do {
        let result = try runGit(args: [
            "-C", rootPath, "status", "--porcelain=v2", "--branch", "--untracked-files=all"
        ])
        let summary = GitStatusPorcelainParser.parse(result.stdout, rootPath: rootPath)
        let unstagedOutput = try? runGit(args: ["-C", rootPath, "diff", "--numstat"]).stdout
        let stagedOutput = try? runGit(args: ["-C", rootPath, "diff", "--cached", "--numstat"]).stdout
        let unstagedStats = GitDiffStatParser.parse(unstagedOutput ?? "")
        let stagedStats = GitDiffStatParser.parse(stagedOutput ?? "")
        let untrackedStats = diffStatsForUntrackedFiles(rootPath: rootPath, files: summary.untrackedFiles)
        return .loaded(
            summary.applying(
                stagedStats: stagedStats,
                unstagedStats: unstagedStats,
                untrackedStats: untrackedStats
            ))
    } catch let error as GitStatusServiceError {
        switch error {
        case .notRepository:
            return .notRepository(rootPath: rootPath)
        case .commandFailed(let message):
            return .error(rootPath: rootPath, message: message)
        }
    } catch {
        return .error(rootPath: rootPath, message: error.localizedDescription)
    }
}

private func diffStatsForUntrackedFiles(rootPath: String, files: [GitFileChange]) -> [String: GitDiffStat] {
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

private func deletePath(rootPath: String, path: String) throws {
    let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
    let targetURL = rootURL.appendingPathComponent(path).standardizedFileURL
    let rootPathWithSlash = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
    guard targetURL.path == rootURL.path || targetURL.path.hasPrefix(rootPathWithSlash) else {
        throw GitStatusServiceError.commandFailed("Refusing to delete a path outside the repository root")
    }
    try FileManager.default.removeItem(at: targetURL)
}

private func addPathToGitignore(rootPath: String, path: String) throws {
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

private struct GitCommandResult: Sendable {
    let stdout: String
    let stderr: String
}

private func runGit(args: [String]) throws -> GitCommandResult {
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
    process.waitUntilExit()

    let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        if stderrText.contains("not a git repository") || stderrText.contains("not a git repo") {
            throw GitStatusServiceError.notRepository
        }
        let message = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        throw GitStatusServiceError.commandFailed(message.isEmpty ? "git command failed" : message)
    }

    return GitCommandResult(stdout: stdoutText, stderr: stderrText)
}
