import Foundation

struct GitDiffStat: Equatable, Sendable {
    let additions: Int?
    let deletions: Int?
    let isBinary: Bool
}

/// Git change kind shown in the Phase 3 sidebar.
enum GitFileStatus: String, Equatable, Sendable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case typeChanged
    case untracked
    case unmerged
}

/// One changed file row in the git sidebar.
struct GitFileChange: Equatable, Sendable, Identifiable {
    var id: String { "\(sectionKey):\(path):\(originalPath ?? "")" }

    let path: String
    let originalPath: String?
    let status: GitFileStatus
    let additions: Int?
    let deletions: Int?
    let sectionKey: String

    init(
        path: String,
        originalPath: String? = nil,
        status: GitFileStatus,
        additions: Int? = nil,
        deletions: Int? = nil,
        sectionKey: String
    ) {
        self.path = path
        self.originalPath = originalPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.sectionKey = sectionKey
    }
}

/// Summary of the active workspace git status for the Phase 3 sidebar.
struct GitStatusSummary: Equatable, Sendable {
    static let displayFileLimit = 500

    let rootPath: String
    let branchName: String?
    let upstreamName: String?
    let aheadCount: Int
    let behindCount: Int
    let stagedCount: Int
    let unstagedCount: Int
    let untrackedCount: Int
    let stagedFiles: [GitFileChange]
    let unstagedFiles: [GitFileChange]
    let untrackedFiles: [GitFileChange]
    let isFileDisplayCapped: Bool
    let totalFileCount: Int

    init(
        rootPath: String,
        branchName: String?,
        upstreamName: String?,
        aheadCount: Int,
        behindCount: Int,
        stagedCount: Int? = nil,
        unstagedCount: Int? = nil,
        untrackedCount: Int? = nil,
        stagedFiles: [GitFileChange] = [],
        unstagedFiles: [GitFileChange] = [],
        untrackedFiles: [GitFileChange] = [],
        isFileDisplayCapped: Bool = false,
        totalFileCount: Int? = nil
    ) {
        self.rootPath = rootPath
        self.branchName = branchName
        self.upstreamName = upstreamName
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.stagedFiles = stagedFiles
        self.unstagedFiles = unstagedFiles
        self.untrackedFiles = untrackedFiles
        self.stagedCount = stagedCount ?? stagedFiles.count
        self.unstagedCount = unstagedCount ?? unstagedFiles.count
        self.untrackedCount = untrackedCount ?? untrackedFiles.count
        self.isFileDisplayCapped = isFileDisplayCapped
        self.totalFileCount = totalFileCount ?? (self.stagedCount + self.unstagedCount + self.untrackedCount)
    }

    var isClean: Bool {
        stagedCount == 0 && unstagedCount == 0 && untrackedCount == 0
    }

    func applying(
        stagedStats: [String: GitDiffStat],
        unstagedStats: [String: GitDiffStat],
        untrackedStats: [String: GitDiffStat] = [:]
    ) -> GitStatusSummary {
        GitStatusSummary(
            rootPath: rootPath,
            branchName: branchName,
            upstreamName: upstreamName,
            aheadCount: aheadCount,
            behindCount: behindCount,
            stagedCount: stagedCount,
            unstagedCount: unstagedCount,
            untrackedCount: untrackedCount,
            stagedFiles: stagedFiles.map { $0.applying(stat: stagedStats[$0.path]) },
            unstagedFiles: unstagedFiles.map { $0.applying(stat: unstagedStats[$0.path]) },
            untrackedFiles: untrackedFiles.map { $0.applying(stat: untrackedStats[$0.path]) },
            isFileDisplayCapped: isFileDisplayCapped,
            totalFileCount: totalFileCount
        )
    }
}

extension GitFileChange {
    func applying(stat: GitDiffStat?) -> GitFileChange {
        guard let stat else { return self }
        return GitFileChange(
            path: path,
            originalPath: originalPath,
            status: status,
            additions: stat.additions,
            deletions: stat.deletions,
            sectionKey: sectionKey
        )
    }
}

/// Row-level git file operation supported by the Phase 3 sidebar.
enum GitStatusFileOperation: Equatable, Sendable {
    case stage
    case unstage
    case discard
    case delete
    case addToGitignore

    var requiresConfirmation: Bool {
        switch self {
        case .discard, .delete:
            return true
        case .stage, .unstage, .addToGitignore:
            return false
        }
    }

    var confirmationTitle: String {
        switch self {
        case .discard:
            return "Discard Changes?"
        case .delete:
            return "Delete Untracked Files?"
        case .addToGitignore:
            return "Add to .gitignore"
        case .stage:
            return "Stage Files?"
        case .unstage:
            return "Unstage Files?"
        }
    }

    var confirmationButtonTitle: String {
        switch self {
        case .discard:
            return "Discard"
        case .delete:
            return "Delete"
        case .addToGitignore:
            return "Add to .gitignore"
        case .stage:
            return "Stage"
        case .unstage:
            return "Unstage"
        }
    }

    func confirmationMessage(pathCount: Int) -> String {
        let itemText = pathCount == 1 ? "this file" : "these \(pathCount) files"
        switch self {
        case .discard:
            return "This will permanently discard unstaged changes in \(itemText)."
        case .delete:
            return "This will permanently delete \(itemText) from disk."
        case .addToGitignore:
            return "Add \(itemText) to .gitignore?"
        case .stage:
            return "Stage \(itemText)?"
        case .unstage:
            return "Unstage \(itemText)?"
        }
    }

    func confirmationMessage(paths: [String]) -> String {
        guard !paths.isEmpty else { return confirmationMessage(pathCount: 0) }
        let pathList = paths.map { "\"\($0)\"" }.joined(separator: "\n")
        switch self {
        case .discard:
            return "This will permanently discard unstaged changes in:\n\n\(pathList)"
        case .delete:
            return "This will permanently delete from disk:\n\n\(pathList)"
        case .addToGitignore:
            return "Add to .gitignore:\n\n\(pathList)"
        case .stage:
            return "Stage:\n\n\(pathList)"
        case .unstage:
            return "Unstage:\n\n\(pathList)"
        }
    }
}

/// User-visible load state for the git sidebar.
enum GitStatusLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded(GitStatusSummary)
    case notRepository(rootPath: String)
    case repositoryInitializationFailed(rootPath: String, message: String)
    case fileOperationFailed(rootPath: String, message: String)
    case error(rootPath: String, message: String)
}

/// Minimal workspace context needed to resolve the git status root without
/// depending on terminal state.
struct GitStatusRootContext: Equatable, Sendable {
    enum WorkspaceKind: Equatable, Sendable {
        case worktree
        case mainCheckout
        case standalone
    }

    let kind: WorkspaceKind
    let currentDirectory: String
    let worktreePath: String?
    let projectRepositoryPath: String?
}

struct GitStatusRootResolver: Sendable {
    func root(for context: GitStatusRootContext) -> String {
        switch context.kind {
        case .worktree:
            return nonEmpty(context.worktreePath) ?? context.currentDirectory
        case .mainCheckout:
            return nonEmpty(context.projectRepositoryPath) ?? context.currentDirectory
        case .standalone:
            return context.currentDirectory
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }
}
