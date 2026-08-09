import Combine
import Foundation
import SwiftUI

/// Direction for splitting terminal panes inside a workspace tab.
enum PanelSplitDirection: String, Codable, Sendable {
    /// Side-by-side panes separated by a vertical divider.
    case vertical
    /// Stacked panes separated by a horizontal divider.
    case horizontal
}

/// One branch in a path from a tab layout root to a nested split.
enum PanelLayoutBranch: Sendable {
    case first
    case second
}

/// Tree describing the panes visible inside one workspace tab.
indirect enum PanelLayoutNode: Equatable, Sendable {
    case leaf(UUID)
    case split(direction: PanelSplitDirection, ratio: CGFloat = 0.5, first: PanelLayoutNode, second: PanelLayoutNode)

    var leaves: [UUID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(_, _, let first, let second):
            return first.leaves + second.leaves
        }
    }

    func contains(_ panelId: UUID) -> Bool {
        leaves.contains(panelId)
    }

    func replacingLeaf(_ panelId: UUID, with replacement: PanelLayoutNode) -> PanelLayoutNode {
        switch self {
        case .leaf(let id):
            return id == panelId ? replacement : self
        case .split(let direction, let ratio, let first, let second):
            return .split(
                direction: direction,
                ratio: ratio,
                first: first.replacingLeaf(panelId, with: replacement),
                second: second.replacingLeaf(panelId, with: replacement)
            )
        }
    }

    func removingLeaf(_ panelId: UUID) -> PanelLayoutNode? {
        switch self {
        case .leaf(let id):
            return id == panelId ? nil : self
        case .split(let direction, let ratio, let first, let second):
            let newFirst = first.removingLeaf(panelId)
            let newSecond = second.removingLeaf(panelId)
            switch (newFirst, newSecond) {
            case (nil, nil): return nil
            case (let remaining?, nil): return remaining
            case (nil, let remaining?): return remaining
            case (let first?, let second?):
                return .split(direction: direction, ratio: ratio, first: first, second: second)
            }
        }
    }

    func settingSplitRatio(
        _ ratio: CGFloat,
        at path: [PanelLayoutBranch],
        depth: Int = 0
    ) -> PanelLayoutNode {
        guard case .split(let direction, let currentRatio, let first, let second) = self else {
            return self
        }

        if depth == path.count {
            return .split(
                direction: direction,
                ratio: min(max(ratio, 0.1), 0.9),
                first: first,
                second: second
            )
        }

        switch path[depth] {
        case .first:
            return .split(
                direction: direction,
                ratio: currentRatio,
                first: first.settingSplitRatio(ratio, at: path, depth: depth + 1),
                second: second
            )
        case .second:
            return .split(
                direction: direction,
                ratio: currentRatio,
                first: first,
                second: second.settingSplitRatio(ratio, at: path, depth: depth + 1)
            )
        }
    }
}

/// A workspace containing an ordered list of tabbed panels.
///
/// Each workspace maps to a single git worktree (or a standalone directory)
/// and presents its panels as tabs in the content area. A nonempty workspace
/// has one active panel; an intentionally empty workspace has no active panel.
///
/// The spec (§Workspaces) requires:
/// - Ordered tabbed panels with tab bar display.
/// - Exactly one active panel per nonempty workspace.
/// - Panel creation, removal, reordering, and selection.
/// - Workspace renaming with default name derived from the shell's cwd.
@MainActor
final class Workspace: Identifiable, ObservableObject {

    // MARK: - Identity

    let id: UUID

    // MARK: - Project Association (Phase 2)

    /// The project this workspace belongs to. `nil` for standalone workspaces
    /// (adopted by the catch-all project).
    @Published var projectId: UUID?

    /// The git branch this workspace is checked out on.
    @Published var branchName: String?

    /// How this workspace relates to its project's git repository.
    @Published var workspaceType: WorkspaceType = .external

    /// Filesystem path to the worktree, if this workspace uses a project worktree.
    /// `nil` for standalone or main-checkout workspaces.
    @Published var worktreePath: String?

    // MARK: - Published state

    /// Title derived from shell working directory or process title.
    @Published var title: String

    /// User-assigned custom title. When non-nil and non-empty, takes
    /// precedence over the derived `title` in the sidebar and titlebar.
    @Published var customTitle: String?

    /// Working directory for this workspace (worktree root or standalone dir).
    @Published var currentDirectory: String

    /// Ordered panel IDs defining tab order left-to-right.
    @Published internal(set) var panelOrder: [UUID] = []

    /// Panel instances keyed by their `id`. Uses `any Panel` existential
    /// because a workspace can contain mixed terminal and browser panels.
    @Published internal(set) var panels: [UUID: any Panel] = [:]

    /// The `id` of the currently active (focused) panel, or `nil` if the
    /// workspace has no panels.
    @Published var activePanelId: UUID?

    /// Split-pane layout for each top-level tab, keyed by that tab's root
    /// panel id. Tabs without an entry are single-pane tabs.
    @Published internal(set) var tabLayouts: [UUID: PanelLayoutNode] = [:]

    /// User-assigned terminal tab titles, keyed by top-level panel id.
    @Published internal(set) var terminalCustomTitles: [UUID: String] = [:]

    var panelCancellables: [UUID: AnyCancellable] = [:]

    // MARK: - Computed properties

    /// The currently active panel instance.
    var activePanel: (any Panel)? {
        guard let id = activePanelId else { return nil }
        return panels[id]
    }

    /// The title shown in the sidebar and titlebar.
    /// Prefers the user-assigned `customTitle` over the derived `title`.
    var displayTitle: String {
        if let custom = customTitle, !custom.isEmpty { return custom }
        return title.isEmpty ? "Terminal" : title
    }

    /// Number of top-level tabs in this workspace.
    var panelCount: Int { panelOrder.count }

    /// The top-level tab that owns the active focused pane.
    var activeTabId: UUID? {
        guard let activePanelId else { return panelOrder.first }
        if panelOrder.contains(activePanelId) { return activePanelId }
        return panelOrder.first { tabId in
            layout(for: tabId).contains(activePanelId)
        } ?? panelOrder.first
    }

    /// Split layout for the active tab.
    var activeTabLayout: PanelLayoutNode? {
        guard let activeTabId else { return nil }
        return layout(for: activeTabId)
    }

    /// Returns the layout for a top-level tab, falling back to a single leaf.
    func layout(for tabId: UUID) -> PanelLayoutNode {
        tabLayouts[tabId] ?? .leaf(tabId)
    }

    /// Returns the Top-level Tab containing a current Terminal Surface.
    ///
    /// Surface IDs are Terminal Panel IDs. Nonterminal panels deliberately do
    /// not resolve here, even when their Panel ID appears in a tab layout.
    func topLevelTabId(containingTerminalSurface surfaceId: UUID) -> UUID? {
        guard panels[surfaceId] is TerminalPanel else { return nil }
        return panelOrder.first { layout(for: $0).contains(surfaceId) }
    }

    /// Updates one nested split ratio without changing Pane or Top-level Tab identity.
    func setSplitRatio(_ ratio: CGFloat, for tabId: UUID, at path: [PanelLayoutBranch]) {
        guard panelOrder.contains(tabId) else { return }
        tabLayouts[tabId] = layout(for: tabId).settingSplitRatio(ratio, at: path)
    }

    /// Returns the ordinal label shown in the tab bar for a top-level tab.
    func tabDisplayTitle(for panelId: UUID) -> String {
        guard let index = panelOrder.firstIndex(of: panelId) else { return "Terminal" }
        if let panel = panels[panelId], panel.panelType != .terminal {
            return panel.displayTitle
        }
        return terminalCustomTitles[panelId] ?? "Terminal \(index + 1)"
    }

    // MARK: - Initializer

    /// Creates a new workspace with a single terminal panel.
    ///
    /// - Parameters:
    ///   - title: Initial workspace title. Defaults to `"Terminal"`.
    ///   - workingDirectory: Initial working directory. Defaults to the
    ///     user's home directory when `nil`.
    init(id: UUID = UUID(), title: String = "Terminal", workingDirectory: String? = nil) {
        self.id = id
        self.title = title
        self.currentDirectory =
            workingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        // Spec §Workspaces rule 7: new workspaces start with one terminal panel.
        let panel = TerminalPanel(workspaceId: id, workingDirectory: workingDirectory)
        addPanel(panel)
    }

    /// Creates a workspace within a project, associated with a git branch/worktree.
    ///
    /// - Parameters:
    ///   - title: Initial workspace title. Defaults to `"Terminal"`.
    ///   - workingDirectory: Initial working directory. Defaults to the
    ///     user's home directory when `nil`.
    ///   - projectId: The owning project's identifier.
    ///   - branchName: The git branch this workspace is checked out on.
    ///   - workspaceType: How this workspace relates to its project's repo.
    ///   - worktreePath: Filesystem path to the worktree, if applicable.
    init(
        id: UUID = UUID(),
        title: String = "Terminal",
        workingDirectory: String? = nil,
        projectId: UUID,
        branchName: String,
        workspaceType: WorkspaceType,
        worktreePath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.currentDirectory =
            workingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        self.projectId = projectId
        self.branchName = branchName
        self.workspaceType = workspaceType
        self.worktreePath = worktreePath

        let panel = TerminalPanel(workspaceId: id, workingDirectory: workingDirectory)
        addPanel(panel)
    }

    /// Restores a workspace from a persisted Phase 2 snapshot.
    init(snapshot: WorkspaceSnapshot) {
        self.id = snapshot.id
        self.title = snapshot.title
        self.customTitle = snapshot.customTitle
        self.currentDirectory = snapshot.currentDirectory
        self.projectId = snapshot.projectId
        self.branchName = snapshot.branchName
        self.workspaceType = snapshot.workspaceType
        self.worktreePath = snapshot.worktreePath

        for (directory, customTitle) in zip(
            snapshot.restoredTerminalDirectories,
            snapshot.restoredTerminalCustomTitles
        ) {
            let panel = addTerminalPanel(workingDirectory: directory)
            if let customTitle {
                renameTerminalPanel(panel.id, title: customTitle)
            }
        }
    }

    /// Creates a minimal durable snapshot for Phase 2 persistence.
    func snapshot() -> WorkspaceSnapshot {
        let terminalDirectories = terminalDirectoriesForSnapshot()
        return WorkspaceSnapshot(
            id: id,
            projectId: projectId,
            branchName: branchName,
            workspaceType: workspaceType,
            worktreePath: worktreePath,
            title: title,
            customTitle: customTitle,
            currentDirectory: currentDirectory,
            panelCount: terminalDirectories.count,
            terminalDirectories: terminalDirectories,
            terminalCustomTitles: terminalCustomTitlesForSnapshot()
        )
    }

    private func terminalDirectoriesForSnapshot() -> [String] {
        let directories = panelOrder.compactMap { panelId -> String? in
            guard let terminal = panels[panelId] as? TerminalPanel else { return nil }
            let directory = terminal.directory.trimmingCharacters(in: .whitespacesAndNewlines)
            return directory.isEmpty ? currentDirectory : directory
        }
        return directories
    }

    private func terminalCustomTitlesForSnapshot() -> [String?] {
        panelOrder
            .filter { panels[$0] is TerminalPanel }
            .map { terminalCustomTitles[$0] }
    }

}
