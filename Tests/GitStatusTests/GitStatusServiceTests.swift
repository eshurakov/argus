// swiftlint:disable file_length
import Foundation
import Testing

@testable import Argus

@Suite
struct GitStatusServiceTests {
    @Test
    func coveredBehaviors() async throws {
        try await reportsCleanRepositoryBranchSummary()
        try await reportsNotRepositoryState()
        try await initializesRepositoryAndReturnsCleanStatus()
        try await reportsRepositoryInitializationFailure()
        try await stagesUnstagedFileAndRefreshesStatus()
        try await unstagesStagedFileAndRefreshesStatus()
        try await discardsUnstagedTrackedChangeAndRefreshesStatus()
        try await deletesUntrackedFileAndRefreshesStatus()
        try await addsUntrackedFileToGitignoreAndRefreshesStatus()
        try await addsUntrackedDirectoryToGitignoreAndRefreshesStatus()
    }

    private func reportsCleanRepositoryBranchSummary() async throws {
        let repo = try TemporaryDirectory(prefix: "argus-git-status-clean")
        defer { repo.remove() }
        try run("/usr/bin/git", ["init", "-b", "main"], in: repo.url)

        let state = await GitStatusService().status(rootPath: repo.url.path)

        guard case .loaded(let summary) = state else {
            fail("expected loaded status for git repository, got \(state)")
        }
        assertEqual(summary.rootPath, repo.url.path, "root path is preserved")
        assertEqual(summary.branchName, "main", "branch name comes from git status")
        assertEqual(summary.isClean, true, "new repository is clean")
    }

    private func reportsNotRepositoryState() async throws {
        let directory = try TemporaryDirectory(prefix: "argus-git-status-not-repo")
        defer { directory.remove() }

        let state = await GitStatusService().status(rootPath: directory.url.path)

        guard case .notRepository(let rootPath) = state else {
            fail("expected notRepository state, got \(state)")
        }
        assertEqual(rootPath, directory.url.path, "not-repository state keeps root path")
    }

    private func initializesRepositoryAndReturnsCleanStatus() async throws {
        let directory = try TemporaryDirectory(prefix: "argus-git-status-init")
        defer { directory.remove() }

        let state = await GitStatusService().initializeRepository(rootPath: directory.url.path)

        guard case .loaded(let summary) = state else {
            fail("expected loaded status after initializing repository, got \(state)")
        }
        assertEqual(summary.rootPath, directory.url.path, "initialized status keeps root path")
        assertEqual(summary.isClean, true, "newly initialized repository is clean")
        assertEqual(
            FileManager.default.fileExists(atPath: directory.url.appendingPathComponent(".git").path),
            true, "git init creates metadata")
    }

    private func reportsRepositoryInitializationFailure() async throws {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "argus-git-status-init-missing-\(UUID().uuidString)", isDirectory: true
            )
            .path

        let state = await GitStatusService().initializeRepository(rootPath: missingPath)

        guard case .repositoryInitializationFailed(let rootPath, let message) = state else {
            fail("expected recoverable initialization failure, got \(state)")
        }
        assertEqual(rootPath, missingPath, "initialization failure keeps attempted root")
        assertEqual(message.isEmpty, false, "initialization failure includes an actionable message")
    }

    private func stagesUnstagedFileAndRefreshesStatus() async throws {
        let repo = try TemporaryDirectory(prefix: "argus-git-status-stage")
        defer { repo.remove() }
        try run("/usr/bin/git", ["init", "-b", "main"], in: repo.url)
        try "hello\n".write(
            to: repo.url.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let state = await GitStatusService().performFileOperation(
            .stage, rootPath: repo.url.path, path: "file.txt")

        guard case .loaded(let summary) = state else {
            fail("expected refreshed status after staging file, got \(state)")
        }
        assertEqual(
            summary.stagedFiles.map(\.path), ["file.txt"],
            "stage operation moves file into staged section")
        assertEqual(
            summary.untrackedFiles.isEmpty, true, "stage operation removes file from untracked section")
    }

    private func unstagesStagedFileAndRefreshesStatus() async throws {
        let repo = try TemporaryDirectory(prefix: "argus-git-status-unstage")
        defer { repo.remove() }
        try run("/usr/bin/git", ["init", "-b", "main"], in: repo.url)
        try run("/usr/bin/git", ["config", "user.email", "argus@example.test"], in: repo.url)
        try run("/usr/bin/git", ["config", "user.name", "Argus Test"], in: repo.url)
        let fileURL = repo.url.appendingPathComponent("file.txt")
        try "hello\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "file.txt"], in: repo.url)
        try run("/usr/bin/git", ["commit", "-m", "initial"], in: repo.url)
        try "hello\nworld\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "file.txt"], in: repo.url)

        let state = await GitStatusService().performFileOperation(
            .unstage, rootPath: repo.url.path, path: "file.txt")

        guard case .loaded(let summary) = state else {
            fail("expected refreshed status after unstaging file, got \(state)")
        }
        assertEqual(
            summary.stagedFiles.isEmpty, true, "unstage operation removes file from staged section")
        assertEqual(
            summary.unstagedFiles.map(\.path), ["file.txt"],
            "unstage operation moves file into unstaged section")
    }

    private func discardsUnstagedTrackedChangeAndRefreshesStatus() async throws {
        let repo = try TemporaryDirectory(prefix: "argus-git-status-discard")
        defer { repo.remove() }
        try run("/usr/bin/git", ["init", "-b", "main"], in: repo.url)
        try run("/usr/bin/git", ["config", "user.email", "argus@example.test"], in: repo.url)
        try run("/usr/bin/git", ["config", "user.name", "Argus Test"], in: repo.url)
        let fileURL = repo.url.appendingPathComponent("file.txt")
        try "original\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "file.txt"], in: repo.url)
        try run("/usr/bin/git", ["commit", "-m", "initial"], in: repo.url)
        try "changed\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let state = await GitStatusService().performFileOperation(
            .discard, rootPath: repo.url.path, path: "file.txt")

        guard case .loaded(let summary) = state else {
            fail("expected refreshed status after discarding file, got \(state)")
        }
        assertEqual(summary.isClean, true, "discard operation refreshes to clean status")
        assertEqual(
            try String(contentsOf: fileURL, encoding: .utf8), "original\n",
            "discard reverts tracked unstaged changes")
    }

    private func deletesUntrackedFileAndRefreshesStatus() async throws {
        let repo = try TemporaryDirectory(prefix: "argus-git-status-delete")
        defer { repo.remove() }
        try run("/usr/bin/git", ["init", "-b", "main"], in: repo.url)
        let fileURL = repo.url.appendingPathComponent("scratch.txt")
        try "temporary\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let state = await GitStatusService().performFileOperation(
            .delete, rootPath: repo.url.path, path: "scratch.txt")

        guard case .loaded(let summary) = state else {
            fail("expected refreshed status after deleting untracked file, got \(state)")
        }
        assertEqual(summary.isClean, true, "delete operation refreshes to clean status")
        assertEqual(
            FileManager.default.fileExists(atPath: fileURL.path), false,
            "delete removes untracked file from disk")
    }

    private func addsUntrackedFileToGitignoreAndRefreshesStatus() async throws {
        let repo = try TemporaryDirectory(prefix: "argus-git-status-ignore-file")
        defer { repo.remove() }
        try run("/usr/bin/git", ["init", "-b", "main"], in: repo.url)
        try "existing\n".write(
            to: repo.url.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "temporary\n".write(
            to: repo.url.appendingPathComponent("scratch.txt"),
            atomically: true,
            encoding: .utf8
        )

        let state = await GitStatusService().performFileOperation(
            .addToGitignore, rootPath: repo.url.path, path: "scratch.txt")

        guard case .loaded(let summary) = state else {
            fail("expected refreshed status after adding file to .gitignore, got \(state)")
        }
        assertEqual(
            try String(contentsOf: repo.url.appendingPathComponent(".gitignore"), encoding: .utf8),
            "existing\nscratch.txt\n",
            "file path is appended to .gitignore without replacing existing entries"
        )
        assertEqual(
            summary.untrackedFiles.map(\.path), [".gitignore"],
            "ignored untracked file is removed from the Changes View"
        )
    }

    private func addsUntrackedDirectoryToGitignoreAndRefreshesStatus() async throws {
        let repo = try TemporaryDirectory(prefix: "argus-git-status-ignore-directory")
        defer { repo.remove() }
        try run("/usr/bin/git", ["init", "-b", "main"], in: repo.url)
        let directoryURL = repo.url.appendingPathComponent("New Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try "temporary\n".write(
            to: directoryURL.appendingPathComponent("child.txt"),
            atomically: true,
            encoding: .utf8
        )

        let state = await GitStatusService().performFileOperation(
            .addToGitignore, rootPath: repo.url.path, path: "New Folder")

        guard case .loaded(let summary) = state else {
            fail("expected refreshed status after adding directory to .gitignore, got \(state)")
        }
        assertEqual(
            try String(contentsOf: repo.url.appendingPathComponent(".gitignore"), encoding: .utf8),
            "New Folder/\n",
            "directory paths receive a trailing slash in .gitignore"
        )
        assertEqual(
            summary.untrackedFiles.map(\.path), [".gitignore"],
            "ignored directory contents are removed from the Changes View"
        )
    }
}

@Suite
struct GitStatusServiceBulkAndDiffTests {
    @Test
    func coveredBehaviors() async throws {
        try await performsBulkFileOperationsAndRefreshesStatus()
        try await performsSectionBulkOperationBeyondDisplayedCap()
        try await reportsFileOperationFailureAsRecoverableState()
        try await reportsChangedFileRowsWithDiffStats()
        try await reportsUntrackedFileRowsWithDiffStats()
        try await expandsUntrackedDirectoriesToChildFiles()
    }

    private func performsBulkFileOperationsAndRefreshesStatus() async throws {
        let repo = try TemporaryDirectory(prefix: "argus-git-status-bulk")
        defer { repo.remove() }
        try run("/usr/bin/git", ["init", "-b", "main"], in: repo.url)
        try run("/usr/bin/git", ["config", "user.email", "argus@example.test"], in: repo.url)
        try run("/usr/bin/git", ["config", "user.name", "Argus Test"], in: repo.url)
        let trackedA = repo.url.appendingPathComponent("a.txt")
        let trackedB = repo.url.appendingPathComponent("b.txt")
        try "a\n".write(to: trackedA, atomically: true, encoding: .utf8)
        try "b\n".write(to: trackedB, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "a.txt", "b.txt"], in: repo.url)
        try run("/usr/bin/git", ["commit", "-m", "initial"], in: repo.url)
        try "changed a\n".write(to: trackedA, atomically: true, encoding: .utf8)
        try "changed b\n".write(to: trackedB, atomically: true, encoding: .utf8)

        let staged = await GitStatusService().performBulkFileOperation(
            .stage, rootPath: repo.url.path, paths: ["a.txt", "b.txt"])
        guard case .loaded(let stagedSummary) = staged else {
            fail("expected refreshed status after bulk stage, got \(staged)")
        }
        assertEqual(
            stagedSummary.stagedFiles.map(\.path).sorted(), ["a.txt", "b.txt"],
            "bulk stage stages all requested paths")

        let unstaged = await GitStatusService().performBulkFileOperation(
            .unstage, rootPath: repo.url.path, paths: ["a.txt", "b.txt"])
        guard case .loaded(let unstagedSummary) = unstaged else {
            fail("expected refreshed status after bulk unstage, got \(unstaged)")
        }
        assertEqual(
            unstagedSummary.unstagedFiles.map(\.path).sorted(), ["a.txt", "b.txt"],
            "bulk unstage unstages all requested paths")

        let discarded = await GitStatusService().performBulkFileOperation(
            .discard, rootPath: repo.url.path, paths: ["a.txt", "b.txt"])
        guard case .loaded(let discardedSummary) = discarded else {
            fail("expected refreshed status after bulk discard, got \(discarded)")
        }
        assertEqual(discardedSummary.isClean, true, "bulk discard refreshes to clean status")

        let untrackedA = repo.url.appendingPathComponent("scratch-a.txt")
        let untrackedB = repo.url.appendingPathComponent("scratch-b.txt")
        try "temp\n".write(to: untrackedA, atomically: true, encoding: .utf8)
        try "temp\n".write(to: untrackedB, atomically: true, encoding: .utf8)
        let deleted = await GitStatusService().performBulkFileOperation(
            .delete, rootPath: repo.url.path, paths: ["scratch-a.txt", "scratch-b.txt"])
        guard case .loaded(let deletedSummary) = deleted else {
            fail("expected refreshed status after bulk delete, got \(deleted)")
        }
        assertEqual(deletedSummary.isClean, true, "bulk delete refreshes to clean status")
        for file in [untrackedA, untrackedB] {
            assertEqual(
                FileManager.default.fileExists(atPath: file.path), false, "bulk delete removes each file")
        }
    }

    private func performsSectionBulkOperationBeyondDisplayedCap() async throws {
        let repo = try TemporaryDirectory(prefix: "argus-git-status-section-bulk-cap")
        defer { repo.remove() }
        try run("/usr/bin/git", ["init", "-b", "main"], in: repo.url)

        for index in 0..<501 {
            try "file \(index)\n".write(
                to: repo.url.appendingPathComponent("file-\(index).txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let before = await GitStatusService().status(rootPath: repo.url.path)
        guard case .loaded(let beforeSummary) = before else {
            fail("expected loaded status before section bulk operation, got \(before)")
        }
        assertEqual(
            beforeSummary.untrackedCount, 501, "test repository has more untracked files than display cap"
        )
        assertEqual(
            beforeSummary.untrackedFiles.count, GitStatusSummary.displayFileLimit,
            "status display rows are capped")

        let staged = await GitStatusService().performSectionFileOperation(
            .stage, rootPath: repo.url.path, sectionKey: "untracked")
        guard case .loaded(let stagedSummary) = staged else {
            fail("expected refreshed status after section bulk stage, got \(staged)")
        }
        assertEqual(
            stagedSummary.stagedCount, 501, "section bulk stage includes files hidden by display cap")
        assertEqual(stagedSummary.untrackedCount, 0, "section bulk stage clears all untracked files")
    }

    private func reportsFileOperationFailureAsRecoverableState() async throws {
        let repo = try TemporaryDirectory(prefix: "argus-git-status-operation-failure")
        defer { repo.remove() }
        try run("/usr/bin/git", ["init", "-b", "main"], in: repo.url)

        let state = await GitStatusService().performFileOperation(
            .stage, rootPath: repo.url.path, path: "missing.txt")

        guard case .fileOperationFailed(let rootPath, let message) = state else {
            fail("expected recoverable file operation failure, got \(state)")
        }
        assertEqual(rootPath, repo.url.path, "file operation failure keeps status root")
        assertEqual(message.isEmpty, false, "file operation failure includes a message")
    }

    private func reportsChangedFileRowsWithDiffStats() async throws {
        let repo = try TemporaryDirectory(prefix: "argus-git-status-changed")
        defer { repo.remove() }
        try run("/usr/bin/git", ["init", "-b", "main"], in: repo.url)
        try run("/usr/bin/git", ["config", "user.email", "argus@example.test"], in: repo.url)
        try run("/usr/bin/git", ["config", "user.name", "Argus Test"], in: repo.url)
        let fileURL = repo.url.appendingPathComponent("file.txt")
        try "one\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "file.txt"], in: repo.url)
        try run("/usr/bin/git", ["commit", "-m", "initial"], in: repo.url)
        try "one\ntwo\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let state = await GitStatusService().status(rootPath: repo.url.path)

        guard case .loaded(let summary) = state else {
            fail("expected loaded status for changed git repository, got \(state)")
        }
        assertEqual(
            summary.unstagedFiles.map(\.path), ["file.txt"], "unstaged row comes from git status")
        assertEqual(summary.unstagedFiles.first?.additions, 1, "unstaged additions come from numstat")
        assertEqual(summary.unstagedFiles.first?.deletions, 0, "unstaged deletions come from numstat")
    }

    private func reportsUntrackedFileRowsWithDiffStats() async throws {
        let repo = try TemporaryDirectory(prefix: "argus-git-status-untracked-stats")
        defer { repo.remove() }
        try run("/usr/bin/git", ["init", "-b", "main"], in: repo.url)
        try "one\ntwo\nthree\n".write(
            to: repo.url.appendingPathComponent("scratch.txt"), atomically: true, encoding: .utf8)

        let state = await GitStatusService().status(rootPath: repo.url.path)

        guard case .loaded(let summary) = state else {
            fail("expected loaded status for repository with untracked file, got \(state)")
        }
        assertEqual(
            summary.untrackedFiles.map(\.path), ["scratch.txt"], "untracked row comes from git status")
        assertEqual(summary.untrackedFiles.first?.additions, 3, "untracked additions count file lines")
        assertEqual(summary.untrackedFiles.first?.deletions, 0, "untracked deletions are zero")
    }

    private func expandsUntrackedDirectoriesToChildFiles() async throws {
        let repo = try TemporaryDirectory(prefix: "argus-git-status-untracked-dir")
        defer { repo.remove() }
        try run("/usr/bin/git", ["init", "-b", "main"], in: repo.url)
        let nestedDir = repo.url.appendingPathComponent("New Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try "hello\n".write(
            to: nestedDir.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)

        let state = await GitStatusService().status(rootPath: repo.url.path)

        guard case .loaded(let summary) = state else {
            fail("expected loaded status for repository with untracked directory, got \(state)")
        }
        assertEqual(
            summary.untrackedFiles.map(\.path), ["New Folder/child.txt"],
            "untracked directories expand to child files")
    }
}

private func run(_ executable: String, _ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw NSError(domain: "GitStatusServiceTests", code: Int(process.terminationStatus))
    }
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    #expect(actual == expected, Comment(rawValue: message))
}

private func fail(_ message: String) -> Never {
    Issue.record(Comment(rawValue: message))
    fatalError(message)
}

private struct TemporaryDirectory {
    let url: URL

    init(prefix: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
