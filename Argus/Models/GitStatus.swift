import Foundation

/// Summary of the active workspace Git Status Snapshot and its current
/// presentation projection.
private struct GitStatusSectionInputs {
    let stagedCount: Int
    let unstagedCount: Int
    let untrackedCount: Int
    let stagedFiles: [GitFileChange]
    let unstagedFiles: [GitFileChange]
    let untrackedFiles: [GitFileChange]
    let uncommittedCount: Int
    let uncommittedFiles: [GitFileChange]
    let againstBaseCount: Int
    let againstBaseFiles: [GitFileChange]
    let againstBaseState: GitChangeSectionState
    let combineWorkingChangeSections: Bool
    let showBaseBranchChanges: Bool
}

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
    let uncommittedCount: Int
    let uncommittedFiles: [GitFileChange]
    let againstBaseCount: Int
    let againstBaseFiles: [GitFileChange]
    let againstBaseState: GitChangeSectionState
    let sections: [GitChangeSection]
    let combineWorkingChangeSections: Bool
    let showBaseBranchChanges: Bool
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
        uncommittedCount: Int? = nil,
        uncommittedFiles: [GitFileChange] = [],
        againstBaseCount: Int? = nil,
        againstBaseFiles: [GitFileChange] = [],
        againstBaseState: GitChangeSectionState = .available,
        sections: [GitChangeSection]? = nil,
        combineWorkingChangeSections: Bool = false,
        showBaseBranchChanges: Bool = false,
        isFileDisplayCapped: Bool? = nil,
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
        self.uncommittedFiles = uncommittedFiles
        self.uncommittedCount = uncommittedCount ?? uncommittedFiles.count
        self.againstBaseFiles = againstBaseFiles
        self.againstBaseCount = againstBaseCount ?? againstBaseFiles.count
        self.againstBaseState = againstBaseState
        self.combineWorkingChangeSections = combineWorkingChangeSections
        self.showBaseBranchChanges = showBaseBranchChanges

        let projectedSections =
            sections
            ?? Self.defaultSections(
                GitStatusSectionInputs(
                    stagedCount: self.stagedCount,
                    unstagedCount: self.unstagedCount,
                    untrackedCount: self.untrackedCount,
                    stagedFiles: stagedFiles,
                    unstagedFiles: unstagedFiles,
                    untrackedFiles: untrackedFiles,
                    uncommittedCount: self.uncommittedCount,
                    uncommittedFiles: uncommittedFiles,
                    againstBaseCount: self.againstBaseCount,
                    againstBaseFiles: againstBaseFiles,
                    againstBaseState: againstBaseState,
                    combineWorkingChangeSections: combineWorkingChangeSections,
                    showBaseBranchChanges: showBaseBranchChanges
                ))
        self.sections = projectedSections
        let activeCount =
            projectedSections
            .filter(\.state.isAvailable)
            .reduce(0) { $0 + $1.totalCount }
        self.totalFileCount = totalFileCount ?? activeCount
        self.isFileDisplayCapped = isFileDisplayCapped ?? (activeCount > Self.displayFileLimit)
    }

    var isClean: Bool {
        stagedCount == 0 && unstagedCount == 0 && untrackedCount == 0
    }

    /// True when no present section has anything to show. Working Changes alone
    /// decide dirty state, so a branch stacked on its Base Branch can have a
    /// clean working tree and a full Against Base section; the clean-state
    /// empty state must not replace the sections in that case. An unavailable
    /// section also has content, because it carries the explanation of why its
    /// comparison could not be made.
    var hasNoSectionContent: Bool {
        sections.allSatisfy { $0.state.isAvailable && $0.totalCount == 0 }
    }

    func applying(
        stagedStats: [String: GitDiffStat],
        unstagedStats: [String: GitDiffStat],
        untrackedStats: [String: GitDiffStat] = [:],
        uncommittedStats: [String: GitDiffStat] = [:],
        againstBaseStats: [String: GitDiffStat] = [:]
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
            uncommittedCount: uncommittedCount,
            uncommittedFiles: uncommittedFiles.map {
                $0.applying(stat: uncommittedStats[$0.path] ?? untrackedStats[$0.path])
            },
            againstBaseCount: againstBaseCount,
            againstBaseFiles: againstBaseFiles.map { $0.applying(stat: againstBaseStats[$0.path]) },
            againstBaseState: againstBaseState,
            combineWorkingChangeSections: combineWorkingChangeSections,
            showBaseBranchChanges: showBaseBranchChanges,
            isFileDisplayCapped: isFileDisplayCapped,
            totalFileCount: totalFileCount
        )
    }

    private static func defaultSections(_ inputs: GitStatusSectionInputs) -> [GitChangeSection] {
        var result: [GitChangeSection] = []
        if inputs.combineWorkingChangeSections {
            result.append(
                GitChangeSection(
                    kind: .uncommitted,
                    title: GitChangeSectionKind.uncommitted.title,
                    totalCount: inputs.uncommittedCount,
                    files: inputs.uncommittedFiles,
                    state: .available
                ))
        } else {
            result.append(contentsOf: [
                GitChangeSection(
                    kind: .staged,
                    title: GitChangeSectionKind.staged.title,
                    totalCount: inputs.stagedCount,
                    files: inputs.stagedFiles,
                    state: .available
                ),
                GitChangeSection(
                    kind: .unstaged,
                    title: GitChangeSectionKind.unstaged.title,
                    totalCount: inputs.unstagedCount,
                    files: inputs.unstagedFiles,
                    state: .available
                ),
                GitChangeSection(
                    kind: .untracked,
                    title: GitChangeSectionKind.untracked.title,
                    totalCount: inputs.untrackedCount,
                    files: inputs.untrackedFiles,
                    state: .available
                )
            ])
        }
        if inputs.showBaseBranchChanges {
            result.append(
                GitChangeSection(
                    kind: .againstBase,
                    title: GitChangeSectionKind.againstBase.title,
                    totalCount: inputs.againstBaseCount,
                    files: inputs.againstBaseFiles,
                    state: inputs.againstBaseState
                ))
        }
        return result
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
            sectionKind: sectionKind,
            hasStagedChanges: hasStagedChanges,
            hasUnstagedChanges: hasUnstagedChanges,
            isUntracked: isUntracked,
            diffSource: diffSource,
            isNetDiffEmpty: isNetDiffEmpty
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
    let configuredBaseBranch: String?

    init(
        kind: WorkspaceKind,
        currentDirectory: String,
        worktreePath: String?,
        projectRepositoryPath: String?,
        configuredBaseBranch: String? = nil
    ) {
        self.kind = kind
        self.currentDirectory = currentDirectory
        self.worktreePath = worktreePath
        self.projectRepositoryPath = projectRepositoryPath
        self.configuredBaseBranch = configuredBaseBranch
    }
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
