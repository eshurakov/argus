import Foundation

struct GitStatusPorcelainParser: Sendable {
    static func parse(_ output: String, rootPath: String) -> GitStatusSummary {
        cappedSummary(rootPath: rootPath, status: parseUncapped(output))
    }

    /// Parses the complete porcelain result without applying the Changes View
    /// display limit. Git mutations and combined sections must be based on the
    /// complete status, even when the sidebar only renders 500 entries.
    static func parseUncapped(_ output: String) -> GitStatusRawSnapshot {
        var status = GitStatusRawSnapshot()

        for line in output.components(separatedBy: .newlines) {
            parse(line, into: &status)
        }

        return status
    }

    private static func parse(_ line: String, into status: inout GitStatusRawSnapshot) {
        if line.hasPrefix("# ") {
            parseBranch(line, into: &status)
        } else if line.hasPrefix("? ") {
            let path = String(line.dropFirst(2))
            status.untrackedFiles.append(
                GitFileChange(path: path, status: .untracked, sectionKind: .untracked)
            )
        } else if line.hasPrefix("1 ") {
            appendOrdinaryChange(line, status: &status)
        } else if line.hasPrefix("2 ") {
            appendRenamedOrCopiedChange(line, status: &status)
        } else if line.hasPrefix("u "), let path = pathFromUnmergedLine(line) {
            status.unstagedFiles.append(
                GitFileChange(path: path, status: .unmerged, sectionKind: .unstaged)
            )
        }
    }

    private static func parseBranch(_ line: String, into status: inout GitStatusRawSnapshot) {
        if line.hasPrefix("# branch.head ") {
            let value = String(line.dropFirst("# branch.head ".count))
            status.branchName = value == "(detached)" ? nil : value
        } else if line.hasPrefix("# branch.upstream ") {
            status.upstreamName = String(line.dropFirst("# branch.upstream ".count))
        } else if line.hasPrefix("# branch.ab ") {
            parseBranchCounts(line, into: &status)
        }
    }

    private static func parseBranchCounts(_ line: String, into status: inout GitStatusRawSnapshot) {
        for part in line.dropFirst("# branch.ab ".count).split(separator: " ") {
            if part.hasPrefix("+") {
                status.aheadCount = Int(part.dropFirst()) ?? 0
            } else if part.hasPrefix("-") {
                status.behindCount = Int(part.dropFirst()) ?? 0
            }
        }
    }

    private static func appendOrdinaryChange(
        _ line: String,
        status: inout GitStatusRawSnapshot
    ) {
        let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard fields.count >= 9 else { return }
        appendChanges(
            xy: String(fields[1]),
            path: String(fields[8]),
            originalPath: nil,
            status: &status
        )
    }

    private static func appendRenamedOrCopiedChange(
        _ line: String,
        status: inout GitStatusRawSnapshot
    ) {
        let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
        guard fields.count >= 10 else { return }
        let paths = String(fields[9]).components(separatedBy: "\t")
        appendChanges(
            xy: String(fields[1]),
            path: paths.first ?? String(fields[9]),
            originalPath: paths.dropFirst().first,
            status: &status
        )
    }

    private static func pathFromUnmergedLine(_ line: String) -> String? {
        let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
        return fields.last.map(String.init)
    }

    private static func appendChanges(
        xy: String,
        path: String,
        originalPath: String?,
        status parsedStatus: inout GitStatusRawSnapshot
    ) {
        let characters = Array(xy)
        guard characters.count >= 2 else { return }
        if characters[0] != "." {
            parsedStatus.stagedFiles.append(
                GitFileChange(
                    path: path,
                    originalPath: originalPath,
                    status: status(for: characters[0]),
                    sectionKind: .staged
                ))
        }
        if characters[1] != "." {
            parsedStatus.unstagedFiles.append(
                GitFileChange(
                    path: path,
                    originalPath: originalPath,
                    status: status(for: characters[1]),
                    sectionKind: .unstaged
                ))
        }
    }

    private static func status(for code: Character) -> GitFileStatus {
        switch code {
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        case "U": return .unmerged
        default: return .modified
        }
    }

    private static func cappedSummary(
        rootPath: String,
        status: GitStatusRawSnapshot
    ) -> GitStatusSummary {
        let total = status.stagedFiles.count + status.unstagedFiles.count + status.untrackedFiles.count
        var remaining = GitStatusSummary.displayFileLimit
        let cappedStaged = Array(status.stagedFiles.prefix(remaining))
        remaining -= cappedStaged.count
        let cappedUnstaged = Array(status.unstagedFiles.prefix(max(remaining, 0)))
        remaining -= cappedUnstaged.count
        let cappedUntracked = Array(status.untrackedFiles.prefix(max(remaining, 0)))

        return GitStatusSummary(
            rootPath: rootPath,
            branchName: status.branchName,
            upstreamName: status.upstreamName,
            aheadCount: status.aheadCount,
            behindCount: status.behindCount,
            stagedCount: status.stagedFiles.count,
            unstagedCount: status.unstagedFiles.count,
            untrackedCount: status.untrackedFiles.count,
            stagedFiles: cappedStaged,
            unstagedFiles: cappedUnstaged,
            untrackedFiles: cappedUntracked,
            isFileDisplayCapped: total > GitStatusSummary.displayFileLimit,
            totalFileCount: total
        )
    }
}

struct GitStatusRawSnapshot: Equatable, Sendable {
    var branchName: String?
    var upstreamName: String?
    var aheadCount = 0
    var behindCount = 0
    var stagedFiles: [GitFileChange] = []
    var unstagedFiles: [GitFileChange] = []
    var untrackedFiles: [GitFileChange] = []
}
