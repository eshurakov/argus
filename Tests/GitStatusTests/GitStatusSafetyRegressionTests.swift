import Foundation
import Testing

@testable import Argus

@Suite
struct GitStatusSafetyRegressionTests {
    @Test
    func rowOperationsTreatEveryFilenameAsALiteralPath() async throws {
        let repo = try TemporaryDirectory(prefix: "argus-git-status-literal-paths")
        defer { repo.remove() }
        try run("/usr/bin/git", ["init", "-b", "main"], in: repo.url)
        try run("/usr/bin/git", ["config", "user.email", "argus@example.test"], in: repo.url)
        try run("/usr/bin/git", ["config", "user.name", "Argus Test"], in: repo.url)
        let names = [
            "file[1].txt", "file1.txt", "star*.txt", "starX.txt",
            ":leading.txt", "white space.txt", "café.txt"
        ]
        for name in names {
            try "original\n".write(
                to: repo.url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try run("/usr/bin/git", ["add", "--", "."], in: repo.url)
        try run("/usr/bin/git", ["commit", "-m", "initial"], in: repo.url)
        for name in names {
            try "changed \(name)\n".write(
                to: repo.url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        _ = await GitStatusService().performFileOperation(
            .discard, rootPath: repo.url.path, path: "file[1].txt"
        )
        #expect(
            try String(contentsOf: repo.url.appendingPathComponent("file[1].txt"), encoding: .utf8)
                == "original\n"
        )
        #expect(
            try String(contentsOf: repo.url.appendingPathComponent("file1.txt"), encoding: .utf8)
                == "changed file1.txt\n"
        )

        let selected = ["star*.txt", ":leading.txt", "white space.txt", "café.txt"]
        let state = await GitStatusService().performBulkFileOperation(
            .stage,
            rootPath: repo.url.path,
            paths: selected
        )
        guard case .loaded(let summary) = state else {
            fail("expected literal paths to stage, got \(state)")
        }
        assertEqual(summary.stagedFiles.map(\.path).sorted(), selected.sorted(), "only exact paths stage")
        assertEqual(
            summary.unstagedFiles.map(\.path).sorted(),
            ["file1.txt", "starX.txt"],
            "glob siblings remain unstaged"
        )
    }

    @Test
    func unstageSupportsUnbornRepositoriesForRowsAndSections() async throws {
        let repo = try TemporaryDirectory(prefix: "argus-git-status-unborn-unstage")
        defer { repo.remove() }
        try run("/usr/bin/git", ["init", "-b", "main"], in: repo.url)
        for name in ["first.txt", "second.txt"] {
            try "working tree\n".write(
                to: repo.url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try run("/usr/bin/git", ["add", "--", "."], in: repo.url)

        let rowState = await GitStatusService().performFileOperation(
            .unstage, rootPath: repo.url.path, path: "first.txt"
        )
        guard case .loaded(let afterRow) = rowState else {
            fail("expected row unstage in unborn repository, got \(rowState)")
        }
        assertEqual(afterRow.stagedFiles.map(\.path), ["second.txt"], "row unstage removes one index entry")
        #expect(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("first.txt").path))

        let sectionState = await GitStatusService().performSectionFileOperation(
            .unstage, rootPath: repo.url.path, sectionKey: "staged"
        )
        guard case .loaded(let afterSection) = sectionState else {
            fail("expected section unstage in unborn repository, got \(sectionState)")
        }
        #expect(afterSection.stagedFiles.isEmpty)
        #expect(Set(afterSection.untrackedFiles.map(\.path)) == Set(["first.txt", "second.txt"]))
    }

    @Test
    func statusPreservesUnicodeTabsAndNewlinesInFilenames() async throws {
        let repo = try TemporaryDirectory(prefix: "argus-git-status-exact-filenames")
        defer { repo.remove() }
        try run("/usr/bin/git", ["init", "-b", "main"], in: repo.url)
        let names = ["café.txt", "tab\tname.txt", "line\nname.txt"]
        for name in names {
            try "content\n".write(
                to: repo.url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let state = await GitStatusService().status(rootPath: repo.url.path)
        guard case .loaded(let summary) = state else {
            fail("expected exact filename status, got \(state)")
        }
        assertEqual(summary.untrackedFiles.map(\.path).sorted(), names.sorted(), "status paths are exact")
    }
}
