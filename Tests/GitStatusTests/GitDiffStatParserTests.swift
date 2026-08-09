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

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }
}
