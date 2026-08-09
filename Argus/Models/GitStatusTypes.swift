import Foundation

/// Presentation section used by the Changes View.
enum GitChangeSectionKind: String, Equatable, Hashable, Sendable, CaseIterable {
    case staged
    case unstaged
    case untracked
    case uncommitted
    case againstBase

    var title: String {
        switch self {
        case .staged: "Staged"
        case .unstaged: "Unstaged"
        case .untracked: "Untracked"
        case .uncommitted: "Uncommitted"
        case .againstBase: "Against Base"
        }
    }

    var defaultDiffSource: GitDiffSource {
        switch self {
        case .staged: .staged
        case .unstaged: .unstaged
        case .untracked: .untracked
        case .uncommitted: .uncommitted
        case .againstBase: .againstBase(baseName: "", resolvedRef: "")
        }
    }
}

/// Comparison source used to load a Git Preview for a changed path.
enum GitDiffSource: Equatable, Hashable, Sendable {
    case staged
    case unstaged
    case untracked
    case uncommitted
    case againstBase(baseName: String, resolvedRef: String)
}

/// Availability state for a presentation-ready Changes View section.
enum GitChangeSectionState: Equatable, Sendable {
    case available
    case unavailable(message: String)

    var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }
}

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
    var id: String {
        "\(sectionKind.rawValue):\(path):\(originalPath ?? "")"
    }

    let path: String
    let originalPath: String?
    let status: GitFileStatus
    let additions: Int?
    let deletions: Int?
    let sectionKind: GitChangeSectionKind
    let hasStagedChanges: Bool
    let hasUnstagedChanges: Bool
    let isUntracked: Bool
    let diffSource: GitDiffSource
    let isNetDiffEmpty: Bool

    /// Compatibility projection for the v1 string-based model. New code uses
    /// `sectionKind` and `diffSource` so section routing cannot depend on UI
    /// titles or localized strings.
    var sectionKey: String { sectionKind.rawValue }

    init(
        path: String,
        originalPath: String? = nil,
        status: GitFileStatus,
        additions: Int? = nil,
        deletions: Int? = nil,
        sectionKind: GitChangeSectionKind,
        hasStagedChanges: Bool? = nil,
        hasUnstagedChanges: Bool? = nil,
        isUntracked: Bool? = nil,
        diffSource: GitDiffSource? = nil,
        isNetDiffEmpty: Bool = false
    ) {
        self.path = path
        self.originalPath = originalPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.sectionKind = sectionKind
        self.hasStagedChanges = hasStagedChanges ?? (sectionKind == .staged)
        self.hasUnstagedChanges = hasUnstagedChanges ?? (sectionKind == .unstaged)
        self.isUntracked = isUntracked ?? (sectionKind == .untracked)
        self.diffSource = diffSource ?? sectionKind.defaultDiffSource
        self.isNetDiffEmpty = isNetDiffEmpty
    }

    init(
        path: String,
        originalPath: String? = nil,
        status: GitFileStatus,
        additions: Int? = nil,
        deletions: Int? = nil,
        sectionKey: String
    ) {
        self.init(
            path: path,
            originalPath: originalPath,
            status: status,
            additions: additions,
            deletions: deletions,
            sectionKind: GitChangeSectionKind(rawValue: sectionKey) ?? .unstaged
        )
    }
}

/// Presentation-ready section in a Git Status Snapshot.
struct GitChangeSection: Equatable, Sendable, Identifiable {
    let kind: GitChangeSectionKind
    let title: String
    let totalCount: Int
    let files: [GitFileChange]
    let state: GitChangeSectionState

    var id: GitChangeSectionKind { kind }
}

/// Changes View presentation settings carried by a Git status request.
struct GitStatusPresentation: Equatable, Hashable, Sendable {
    static let `default` = GitStatusPresentation()

    let combineWorkingChangeSections: Bool
    let showBaseBranchChanges: Bool
    let configuredBaseBranch: String?

    init(
        combineWorkingChangeSections: Bool = false,
        showBaseBranchChanges: Bool = false,
        configuredBaseBranch: String? = nil
    ) {
        self.combineWorkingChangeSections = combineWorkingChangeSections
        self.showBaseBranchChanges = showBaseBranchChanges
        self.configuredBaseBranch = configuredBaseBranch
    }
}

/// Complete input identity for a Git status request.
struct GitStatusRequest: Equatable, Hashable, Sendable {
    let rootPath: String
    let presentation: GitStatusPresentation

    init(rootPath: String, presentation: GitStatusPresentation = .default) {
        self.rootPath = rootPath
        self.presentation = presentation
    }
}

/// Identity of one async Git Status Snapshot request. Settings are part of the
/// owner so a late result from another presentation cannot be published.
struct GitStatusSnapshotOwner: Equatable, Hashable, Sendable {
    let workspaceId: UUID
    let request: GitStatusRequest

    init(workspaceId: UUID, request: GitStatusRequest) {
        self.workspaceId = workspaceId
        self.request = request
    }

    /// Compatibility initializer for callers that use the stable default
    /// Changes View presentation.
    init(workspaceId: UUID, rootPath: String) {
        self.init(workspaceId: workspaceId, request: GitStatusRequest(rootPath: rootPath))
    }

    var rootPath: String { request.rootPath }
}
