import Foundation
import SwiftUI

/// Color for visual project identification in the sidebar.
enum ProjectColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, pink

    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        }
    }
}

/// Classification of a workspace's relationship to its project's git repo.
enum WorkspaceType: String, Codable, Sendable {
    case mainCheckout
    case worktree
    case external

    var label: String {
        switch self {
        case .mainCheckout: return "Main"
        case .worktree: return "Worktree"
        case .external: return "External"
        }
    }

    var icon: String {
        switch self {
        case .mainCheckout: return "folder.fill"
        case .worktree: return "arrow.triangle.branch"
        case .external: return "folder"
        }
    }
}

/// A worktree on disk with no corresponding workspace data.
struct OrphanedWorktree: Identifiable {
    let id = UUID()
    let path: String
    let branchName: String?
    let projectId: UUID
}

/// Codable snapshot of a `Project`, used for persistence.
/// Decoupled from the `@MainActor` class so Codable conformance doesn't
/// fight Swift 6 strict concurrency.
struct ProjectSnapshot: Codable, Sendable {
    let id: UUID
    let repositoryPath: String
    let isCatchAll: Bool
    let displayName: String
    let mainBranch: String
    let workspaceIds: [UUID]
    let isExpanded: Bool
    let color: ProjectColor?
}

/// A project groups workspaces under a single git repository.
///
/// Each project is identified by an immutable UUID used as the stable key
/// for worktree storage paths (`~/.argus/worktrees/<project-uuid>/`).
/// The display name is mutable and MUST NOT be used as a storage key.
///
/// The spec (§Projects) requires:
/// - UUID-keyed identity, not display name.
/// - Ordered list of child workspace references.
/// - One non-removable catch-all project for unassigned workspaces.
/// - Expand/collapse sidebar state that persists across sessions.
/// - Optional color for sidebar identification.
@MainActor
final class Project: Identifiable, ObservableObject {

    // MARK: - Identity

    let id: UUID
    let repositoryPath: String
    let isCatchAll: Bool

    // MARK: - Published state

    @Published var displayName: String
    @Published var mainBranch: String
    @Published var workspaceIds: [UUID]
    @Published var isExpanded: Bool
    @Published var color: ProjectColor?

    // MARK: - Initializers

    /// Creates a named project for a git repository.
    ///
    /// - Parameters:
    ///   - repositoryPath: Absolute path to the git repo root.
    ///   - displayName: Custom name. Defaults to the repo directory basename.
    ///   - mainBranch: Auto-detected main branch name.
    init(repositoryPath: String, displayName: String? = nil, mainBranch: String) {
        self.id = UUID()
        self.repositoryPath = repositoryPath
        self.isCatchAll = false
        self.displayName =
            displayName
            ?? (repositoryPath as NSString).lastPathComponent
        self.mainBranch = mainBranch
        self.workspaceIds = []
        self.isExpanded = true
        self.color = nil
    }

    /// Restores a project from a persisted snapshot.
    init(snapshot: ProjectSnapshot) {
        self.id = snapshot.id
        self.repositoryPath = snapshot.repositoryPath
        self.isCatchAll = snapshot.isCatchAll
        self.displayName = snapshot.displayName
        self.mainBranch = snapshot.mainBranch
        self.workspaceIds = snapshot.workspaceIds
        self.isExpanded = snapshot.isExpanded
        self.color = snapshot.color
    }

    /// Creates the non-removable catch-all project for unassigned workspaces.
    static func catchAll() -> Project {
        Project(
            snapshot: ProjectSnapshot(
                id: UUID(),
                repositoryPath: "",
                isCatchAll: true,
                displayName: "Workspaces",
                mainBranch: "",
                workspaceIds: [],
                isExpanded: true,
                color: nil
            ))
    }

    // MARK: - Snapshot

    /// Creates a `Sendable` snapshot for persistence.
    func snapshot() -> ProjectSnapshot {
        ProjectSnapshot(
            id: id,
            repositoryPath: repositoryPath,
            isCatchAll: isCatchAll,
            displayName: displayName,
            mainBranch: mainBranch,
            workspaceIds: workspaceIds,
            isExpanded: isExpanded,
            color: color
        )
    }

    // MARK: - Workspace Management

    func addWorkspace(_ workspaceId: UUID) {
        guard !workspaceIds.contains(workspaceId) else { return }
        workspaceIds.append(workspaceId)
    }

    func removeWorkspace(_ workspaceId: UUID) {
        workspaceIds.removeAll { $0 == workspaceId }
    }

    func moveWorkspace(from source: Int, to destination: Int) {
        guard source >= 0, source < workspaceIds.count,
            destination >= 0, destination < workspaceIds.count
        else { return }

        let id = workspaceIds.remove(at: source)
        workspaceIds.insert(id, at: destination)
    }

    func containsWorkspace(_ workspaceId: UUID) -> Bool {
        workspaceIds.contains(workspaceId)
    }
}
