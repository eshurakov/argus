import Foundation

/// Git configuration spelling of a recorded branch parent.
///
/// Reading and writing a recorded parent must agree on one key format, so both
/// sides go through this type rather than composing the string in place.
enum RecordedBaseBranchConfiguration {
    private static let keyPrefix = "branch."
    private static let keySuffix = ".base"

    static func key(for branch: String) -> String {
        "\(keyPrefix)\(branch)\(keySuffix)"
    }

    static func branchName(forKey key: String) -> String? {
        guard key.hasPrefix(keyPrefix), key.hasSuffix(keySuffix),
            key.count > keyPrefix.count + keySuffix.count
        else { return nil }
        return String(key.dropFirst(keyPrefix.count).dropLast(keySuffix.count))
    }
}

struct GitWorktreeBranch: Equatable, Sendable {
    let path: String
    let branch: String?

    init(path: String, branch: String? = nil) {
        self.path = path
        self.branch = branch
    }
}

struct RecordedBaseBranchSnapshot: Equatable, Sendable {
    let gitCommonDirectory: String
    let worktrees: [GitWorktreeBranch]
    let parents: [String: String]
    let trunkBranches: Set<String>
    let conflicts: [String: String]
    let diagnostics: [String]

    init(
        gitCommonDirectory: String,
        worktrees: [GitWorktreeBranch] = [],
        parents: [String: String] = [:],
        trunkBranches: Set<String> = [],
        conflicts: [String: String] = [:],
        diagnostics: [String] = []
    ) {
        self.gitCommonDirectory = gitCommonDirectory
        self.worktrees = worktrees
        self.parents = parents
        self.trunkBranches = trunkBranches
        self.conflicts = conflicts
        self.diagnostics = diagnostics
    }

    var issue: String? {
        var seen = Set<String>()
        let messages = (conflicts.keys.sorted().compactMap { conflicts[$0] } + diagnostics.sorted())
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !messages.isEmpty else { return nil }
        let summary = messages.prefix(2).joined(separator: " ")
        return messages.count > 2 ? summary + " \(messages.count - 2) more metadata issues." : summary
    }
}
