import Foundation

struct GitDiffStatParser: Sendable {
    static func parse(_ output: String) -> [String: GitDiffStat] {
        var stats: [String: GitDiffStat] = [:]

        for line in output.components(separatedBy: .newlines) where !line.isEmpty {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }

            let path = normalizedPath(String(fields[2]))
            let additions = Int(fields[0])
            let deletions = Int(fields[1])
            let isBinary = fields[0] == "-" || fields[1] == "-"

            stats[path] = GitDiffStat(
                additions: additions,
                deletions: deletions,
                isBinary: isBinary
            )
        }

        return stats
    }

    /// Parses `git diff --numstat -z` output. The NUL form keeps paths with
    /// spaces, tabs, and newlines unambiguous. Git emits the destination path
    /// after the stat tuple for rename/copy records, so both path spellings
    /// receive the same statistic when that form is encountered.
    static func parseNUL(_ output: String) -> [String: GitDiffStat] {
        let records = output.split(separator: "\u{0}", omittingEmptySubsequences: true)
        var stats: [String: GitDiffStat] = [:]
        var index = 0

        while index < records.count {
            let fields = records[index].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else {
                index += 1
                continue
            }

            let stat = GitDiffStat(
                additions: Int(fields[0]),
                deletions: Int(fields[1]),
                isBinary: fields[0] == "-" || fields[1] == "-"
            )
            if fields[2].isEmpty, index + 2 < records.count {
                // Rename/copy records have an empty path in the stat tuple,
                // followed by old and new paths as separate NUL values.
                stats[String(records[index + 1])] = stat
                stats[String(records[index + 2])] = stat
                index += 3
                continue
            }
            stats[String(fields[2])] = stat
            index += 1
        }

        return stats
    }

    fileprivate static func normalizedPath(_ path: String) -> String {
        if let range = path.range(of: " => ") {
            return String(path[range.upperBound...])
        }
        return path
    }
}

struct GitDiffNameStatusRecord: Equatable, Sendable {
    let status: GitFileStatus
    let path: String
    let originalPath: String?
}

/// Parses the NUL-delimited records emitted by `git diff --name-status -z`.
struct GitDiffNameStatusParser: Sendable {
    static func parse(_ output: String) -> [GitDiffNameStatusRecord] {
        let values = output.split(separator: "\u{0}", omittingEmptySubsequences: true)
        var records: [GitDiffNameStatusRecord] = []
        var index = 0

        while index < values.count {
            let statusToken = String(values[index])
            guard let code = statusToken.first else {
                index += 1
                continue
            }
            let status = fileStatus(for: code)

            if code == "R" || code == "C" {
                guard index + 2 < values.count else { break }
                records.append(
                    GitDiffNameStatusRecord(
                        status: status,
                        path: String(values[index + 2]),
                        originalPath: String(values[index + 1])
                    )
                )
                index += 3
            } else {
                guard index + 1 < values.count else { break }
                records.append(
                    GitDiffNameStatusRecord(
                        status: status,
                        path: String(values[index + 1]),
                        originalPath: nil
                    )
                )
                index += 2
            }
        }

        return records
    }

    private static func fileStatus(for code: Character) -> GitFileStatus {
        switch code {
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        case "U": .unmerged
        default: .modified
        }
    }
}
