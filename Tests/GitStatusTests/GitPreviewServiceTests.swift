import Foundation
import Testing

@testable import Argus

@Suite
struct GitPreviewServiceTests {
    @Test
    func resolvesStagedModifiedContent() async throws {
        let repo = try repository(prefix: "argus-preview-staged-modified", fileContent: "old\n")
        defer { repo.remove() }
        try "staged\n".write(to: repo.fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "file.txt"], in: repo.url)
        try "working\n".write(to: repo.fileURL, atomically: true, encoding: .utf8)

        let diff = try await previewDiff(
            root: repo.url,
            file: GitFileChange(path: "file.txt", status: .modified, sectionKey: "staged"))

        assertEqual(diff.oldContent, "old\n", "staged modified old side comes from HEAD")
        assertEqual(diff.newContent, "staged\n", "staged modified new side comes from index")
    }

    @Test
    func resolvesStagedAddedContent() async throws {
        let repo = try repository(prefix: "argus-preview-staged-added")
        defer { repo.remove() }
        let fileURL = repo.url.appendingPathComponent("added.txt")
        try "added\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "added.txt"], in: repo.url)

        let diff = try await previewDiff(
            root: repo.url,
            file: GitFileChange(path: "added.txt", status: .added, sectionKey: "staged"))

        assertEqual(diff.oldContent, "", "staged added old side is empty")
        assertEqual(diff.newContent, "added\n", "staged added new side comes from index")
    }

    @Test
    func resolvesStagedDeletedContent() async throws {
        let repo = try repository(prefix: "argus-preview-staged-deleted", fileContent: "old\n")
        defer { repo.remove() }
        try runGit(["rm", "file.txt"], in: repo.url)

        let diff = try await previewDiff(
            root: repo.url,
            file: GitFileChange(path: "file.txt", status: .deleted, sectionKey: "staged"))

        assertEqual(diff.oldContent, "old\n", "staged deleted old side comes from HEAD")
        assertEqual(diff.newContent, "", "staged deleted new side is empty")
    }

    @Test
    func resolvesStagedRenamedContent() async throws {
        let repo = try repository(prefix: "argus-preview-staged-renamed", fileContent: "old\n")
        defer { repo.remove() }
        try runGit(["mv", "file.txt", "renamed.txt"], in: repo.url)

        let diff = try await previewDiff(
            root: repo.url,
            file: GitFileChange(
                path: "renamed.txt", originalPath: "file.txt", status: .renamed, sectionKey: "staged"))

        assertEqual(diff.oldContent, "old\n", "staged rename reads original path from HEAD")
        assertEqual(diff.newContent, "old\n", "staged rename reads destination path from index")
    }

    @Test
    func resolvesUnstagedModifiedContent() async throws {
        let repo = try repository(prefix: "argus-preview-unstaged-modified", fileContent: "old\n")
        defer { repo.remove() }
        try "working\n".write(to: repo.fileURL, atomically: true, encoding: .utf8)

        let diff = try await previewDiff(
            root: repo.url,
            file: GitFileChange(path: "file.txt", status: .modified, sectionKey: "unstaged"))

        assertEqual(diff.oldContent, "old\n", "unstaged modified old side comes from index")
        assertEqual(diff.newContent, "working\n", "unstaged modified new side comes from working tree")
    }

    @Test
    func resolvesUnstagedDeletedContent() async throws {
        let repo = try repository(prefix: "argus-preview-unstaged-deleted", fileContent: "old\n")
        defer { repo.remove() }
        try FileManager.default.removeItem(at: repo.fileURL)

        let diff = try await previewDiff(
            root: repo.url,
            file: GitFileChange(path: "file.txt", status: .deleted, sectionKey: "unstaged"))

        assertEqual(diff.oldContent, "old\n", "unstaged deleted old side comes from index")
        assertEqual(diff.newContent, "", "unstaged deleted new side is empty")
    }

    @Test
    func resolvesUnstagedRenamedContent() async throws {
        let repo = try repository(prefix: "argus-preview-unstaged-renamed", fileContent: "old\n")
        defer { repo.remove() }
        let renamedURL = repo.url.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: repo.fileURL, to: renamedURL)

        let diff = try await previewDiff(
            root: repo.url,
            file: GitFileChange(
                path: "renamed.txt", originalPath: "file.txt", status: .renamed,
                sectionKey: "unstaged"))

        assertEqual(diff.oldContent, "old\n", "unstaged rename reads original path from index")
        assertEqual(diff.newContent, "old\n", "unstaged rename reads destination from working tree")
    }

    @Test
    func resolvesUntrackedContent() async throws {
        let repo = try repository(prefix: "argus-preview-untracked")
        defer { repo.remove() }
        let fileURL = repo.url.appendingPathComponent("scratch.txt")
        try "scratch\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let diff = try await previewDiff(
            root: repo.url,
            file: GitFileChange(path: "scratch.txt", status: .untracked, sectionKey: "untracked"))

        assertEqual(diff.oldContent, "", "untracked old side is empty")
        assertEqual(diff.newContent, "scratch\n", "untracked new side comes from working tree")
    }

    @Test
    func returnsTextFallbackForBinaryContent() async throws {
        let repo = try repository(prefix: "argus-preview-binary")
        defer { repo.remove() }
        let fileURL = repo.url.appendingPathComponent("binary.dat")
        try Data([0, 1, 2, 3]).write(to: fileURL)

        let result = await GitPreviewService().preview(
            kind: .diff,
            rootPath: repo.url.path,
            file: GitFileChange(path: "binary.dat", status: .untracked, sectionKey: "untracked"))

        guard case .loaded(let preview) = result,
            case .ansiText(let output) = preview.content
        else {
            fail("expected recoverable binary text preview, got \(result)")
        }
        assertEqual(output, "Binary file differs", "binary files bypass Pierre rendering")
    }

    @Test
    func returnsTextFallbackForLargeContent() async throws {
        let repo = try repository(prefix: "argus-preview-large")
        defer { repo.remove() }
        let fileURL = repo.url.appendingPathComponent("large.txt")
        try Data(repeating: 65, count: GitDiffContentLoader.maximumFileSize + 1).write(to: fileURL)

        let result = await GitPreviewService().preview(
            kind: .diff,
            rootPath: repo.url.path,
            file: GitFileChange(path: "large.txt", status: .untracked, sectionKey: "untracked"))

        guard case .loaded(let preview) = result,
            case .ansiText(let output) = preview.content
        else {
            fail("expected recoverable large-file text preview, got \(result)")
        }
        assertEqual(output, "File is too large to preview", "large files bypass Pierre rendering")
    }

    @Test
    func runsBlamePreviewWithColorizedOutput() async throws {
        let repo = try repository(prefix: "argus-preview-blame", fileContent: "one\n")
        defer { repo.remove() }

        let result = await GitPreviewService().preview(
            kind: .blame, rootPath: repo.url.path,
            file: GitFileChange(path: "file.txt", status: .modified, sectionKey: "unstaged"))

        guard case .loaded(let preview) = result,
            case .ansiText(let output) = preview.content
        else {
            fail("expected loaded blame preview, got \(result)")
        }
        assertEqual(output.contains("Argus Test"), true, "blame output includes author")
        assertEqual(output.contains("\u{001B}["), true, "blame output remains colorized")
    }

    @Test
    func rejectsBlameForUntrackedFiles() async {
        let result = await GitPreviewService().preview(
            kind: .blame,
            rootPath: "/tmp/repo",
            file: GitFileChange(path: "scratch.txt", status: .untracked, sectionKey: "untracked"))

        guard case .failed(let kind, let path, _) = result else {
            fail("expected untracked blame failure, got \(result)")
        }
        assertEqual(kind, .blame, "failure keeps blame kind")
        assertEqual(path, "scratch.txt", "failure keeps file path")
    }

    @Test
    func reportsPreviewCommandFailureWithoutThrowing() async {
        let result = await GitPreviewService().preview(
            kind: .blame,
            rootPath: "/tmp/not-a-real-argus-preview-repo",
            file: GitFileChange(path: "missing.txt", status: .modified, sectionKey: "unstaged"))

        guard case .failed(let kind, let path, let message) = result else {
            fail("expected recoverable preview failure, got \(result)")
        }
        assertEqual(kind, .blame, "failure keeps preview kind")
        assertEqual(path, "missing.txt", "failure keeps file path")
        assertEqual(message.isEmpty, false, "failure includes command message")
    }

    private func previewDiff(root: URL, file: GitFileChange) async throws -> GitDiffPreview {
        let result = await GitPreviewService().preview(kind: .diff, rootPath: root.path, file: file)
        guard case .loaded(let preview) = result,
            case .diff(let diff) = preview.content
        else {
            fail("expected structured diff preview, got \(result)")
        }
        return diff
    }

    private func repository(prefix: String, fileContent: String? = nil) throws -> TestRepository {
        let directory = try TestTemporaryDirectory(prefix: prefix)
        try runGit(["init", "-b", "main"], in: directory.url)
        try runGit(["config", "user.email", "argus@example.test"], in: directory.url)
        try runGit(["config", "user.name", "Argus Test"], in: directory.url)

        if let fileContent {
            try fileContent.write(
                to: directory.url.appendingPathComponent("file.txt"),
                atomically: true,
                encoding: .utf8
            )
            try runGit(["add", "file.txt"], in: directory.url)
            try runGit(["commit", "-m", "initial"], in: directory.url)
        }
        return TestRepository(directory: directory)
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        _ = try TestGit.run(arguments, in: directory)
    }

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }

    private func fail(_ message: String) -> Never {
        Issue.record(Comment(rawValue: message))
        fatalError(message)
    }
}

private struct TestRepository {
    let directory: TestTemporaryDirectory
    var url: URL { directory.url }
    var fileURL: URL { directory.url.appendingPathComponent("file.txt") }
    func remove() { directory.remove() }
}
