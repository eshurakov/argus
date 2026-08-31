import Foundation
import Testing

@testable import Argus

@Suite
struct GitDiffStatParserTests {
    @Test
    func parsesTextBinaryAndRenamedStats() {
        let output = """
            12	3	Sources/App.swift
            -	-	Assets/logo.png
            1	2	old name.txt => new name.txt
            """

        let stats = GitDiffStatParser.parse(output)

        assertEqual(
            stats["Sources/App.swift"], GitDiffStat(additions: 12, deletions: 3, isBinary: false),
            "text stats parse")
        assertEqual(
            stats["Assets/logo.png"], GitDiffStat(additions: nil, deletions: nil, isBinary: true),
            "binary stats parse")
        assertEqual(
            stats["new name.txt"], GitDiffStat(additions: 1, deletions: 2, isBinary: false),
            "renamed path stats parse by destination")
    }

    @Test
    func parsesNULNameStatusAndDiffStats() {
        let nameStatus = "R100\u{0}old name.txt\u{0}new name.txt\u{0}A\u{0}added.txt\u{0}"
        let records = GitDiffNameStatusParser.parse(nameStatus)

        assertEqual(
            records,
            [
                GitDiffNameStatusRecord(
                    status: .renamed, path: "new name.txt", originalPath: "old name.txt"),
                GitDiffNameStatusRecord(status: .added, path: "added.txt", originalPath: nil)
            ],
            "NUL name-status records preserve rename paths"
        )

        let stats = GitDiffStatParser.parseNUL(
            "0\t0\t\u{0}old name.txt\u{0}new name.txt\u{0}2\t1\tadded.txt\u{0}"
        )
        assertEqual(
            stats["new name.txt"], GitDiffStat(additions: 0, deletions: 0, isBinary: false),
            "NUL numstat maps rename destination stats"
        )
        assertEqual(
            stats["added.txt"], GitDiffStat(additions: 2, deletions: 1, isBinary: false),
            "NUL numstat maps ordinary path stats"
        )
    }

    @Test
    func nulStatsPreserveTabsNewlinesAndLiteralRenameSyntax() {
        let stats = GitDiffStatParser.parseNUL(
            "1\t2\ttab\tname.txt\u{0}3\t4\tline\nname.txt\u{0}5\t6\tliteral => name.txt\u{0}"
                + "7\t8\t\u{0}old\tname.txt\u{0}new\nname.txt\u{0}"
        )

        assertEqual(
            stats["tab\tname.txt"],
            GitDiffStat(additions: 1, deletions: 2, isBinary: false),
            "tab path is exact"
        )
        assertEqual(
            stats["line\nname.txt"],
            GitDiffStat(additions: 3, deletions: 4, isBinary: false),
            "newline path is exact"
        )
        assertEqual(
            stats["literal => name.txt"],
            GitDiffStat(additions: 5, deletions: 6, isBinary: false),
            "literal rename syntax is not normalized in NUL mode"
        )
        let renameStat = GitDiffStat(additions: 7, deletions: 8, isBinary: false)
        assertEqual(stats["old\tname.txt"], renameStat, "rename source tab path is exact")
        assertEqual(stats["new\nname.txt"], renameStat, "rename destination newline path is exact")
    }

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }
}
