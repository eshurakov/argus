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

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }
}
