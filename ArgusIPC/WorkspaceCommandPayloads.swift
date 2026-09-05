import Foundation

// MARK: - workspace.list

/// `workspace.list` takes no parameters; the projection is always the fully
/// expanded left-sidebar order including Stack Groups.
public struct WorkspaceListParameters: Codable, Sendable {
    public init() {}
}

public struct WorkspaceListResult: Codable, Sendable {
    public let selectedWorkspaceId: String?
    public let projects: [ProjectListEntry]

    public init(selectedWorkspaceId: String?, projects: [ProjectListEntry]) {
        self.selectedWorkspaceId = selectedWorkspaceId
        self.projects = projects
    }
}

public struct ProjectListEntry: Codable, Sendable {
    public let id: String
    public let name: String
    public let isCatchAll: Bool
    public let repositoryPath: String?
    public let mainBranch: String?
    /// Stack discovery diagnostic for this Project, when one is present.
    public let stackDiagnostic: String?
    public let items: [WorkspaceListItem]

    public init(
        id: String,
        name: String,
        isCatchAll: Bool,
        repositoryPath: String?,
        mainBranch: String?,
        stackDiagnostic: String?,
        items: [WorkspaceListItem]
    ) {
        self.id = id
        self.name = name
        self.isCatchAll = isCatchAll
        self.repositoryPath = repositoryPath
        self.mainBranch = mainBranch
        self.stackDiagnostic = stackDiagnostic
        self.items = items
    }
}

/// One left-sidebar item: a standalone Workspace row or a Stack Group.
public enum WorkspaceListItem: Codable, Sendable {
    case workspace(WorkspaceListEntry)
    case stack(StackGroupListEntry)

    private enum Kind: String, Codable {
        case workspace
        case stack
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case workspace
        case stack
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .workspace:
            self = .workspace(try container.decode(WorkspaceListEntry.self, forKey: .workspace))
        case .stack:
            self = .stack(try container.decode(StackGroupListEntry.self, forKey: .stack))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .workspace(let entry):
            try container.encode(Kind.workspace, forKey: .kind)
            try container.encode(entry, forKey: .workspace)
        case .stack(let group):
            try container.encode(Kind.stack, forKey: .kind)
            try container.encode(group, forKey: .stack)
        }
    }
}

/// A Stack Group: at least two open Workspaces from one Stack, plus the
/// nonselectable branch references needed to draw the relationship.
public struct StackGroupListEntry: Codable, Sendable {
    public let id: String
    public let baseBranch: String?
    public let rows: [StackRowListEntry]

    public init(id: String, baseBranch: String?, rows: [StackRowListEntry]) {
        self.id = id
        self.baseBranch = baseBranch
        self.rows = rows
    }
}

public struct StackRowListEntry: Codable, Sendable {
    public let branch: String
    public let parentBranch: String?
    public let lane: Int
    /// Recorded-parent conflict diagnostic for this branch, when present.
    public let issue: String?
    /// `nil` for a branch reference with no open Workspace.
    public let workspace: WorkspaceListEntry?

    public init(
        branch: String,
        parentBranch: String?,
        lane: Int,
        issue: String?,
        workspace: WorkspaceListEntry?
    ) {
        self.branch = branch
        self.parentBranch = parentBranch
        self.lane = lane
        self.issue = issue
        self.workspace = workspace
    }
}

public enum WorkspaceKindEntry: String, Codable, Sendable {
    case mainCheckout = "main-checkout"
    case worktree
    case standalone
}

public struct WorkspaceListEntry: Codable, Sendable {
    public let id: String
    /// Workspace Number: 1-based global left-sidebar position.
    public let number: Int?
    public let title: String
    public let kind: WorkspaceKindEntry
    public let branch: String?
    /// Workspace Root.
    public let root: String
    public let worktreePath: String?
    public let isSelected: Bool
    /// Number of Top-level Tabs.
    public let tabCount: Int

    public init(
        id: String,
        number: Int?,
        title: String,
        kind: WorkspaceKindEntry,
        branch: String?,
        root: String,
        worktreePath: String?,
        isSelected: Bool,
        tabCount: Int
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.kind = kind
        self.branch = branch
        self.root = root
        self.worktreePath = worktreePath
        self.isSelected = isSelected
        self.tabCount = tabCount
    }
}

// MARK: - workspace.create

/// `workspace.create` parameters.
///
/// `project` and `base` are unresolved references. The Argus Application
/// resolves them against current domain state; the Companion CLI never
/// interprets them.
public struct WorkspaceCreateParameters: Codable, Sendable {
    /// Project reference: Project ID, exact display name, or `.` for the
    /// Project implied by the calling context.
    public let project: String?
    /// Base Workspace reference for stacked creation: Workspace ID, branch
    /// name, display title, or `.` for the calling context's Workspace.
    public let base: String?
    /// New branch name. When omitted, Argus generates an available name.
    public let branch: String?
    /// Optional custom Workspace title.
    public let name: String?
    /// `ARGUS_WORKSPACE_ID` of the terminal that invoked the CLI, when set.
    public let contextWorkspaceId: String?
    /// Working directory of the invoking process, used to imply a Project.
    public let contextDirectory: String?

    public init(
        project: String? = nil,
        base: String? = nil,
        branch: String? = nil,
        name: String? = nil,
        contextWorkspaceId: String? = nil,
        contextDirectory: String? = nil
    ) {
        self.project = project
        self.base = base
        self.branch = branch
        self.name = name
        self.contextWorkspaceId = contextWorkspaceId
        self.contextDirectory = contextDirectory
    }
}

public struct WorkspaceCreateResult: Codable, Sendable {
    public let workspace: WorkspaceListEntry
    public let projectId: String
    public let projectName: String
    public let branch: String
    /// Branch the new branch started from, when creation was stacked.
    public let baseBranch: String?
    /// True when Argus recorded `branch.<new>.base` for the new branch.
    public let recordedBaseBranch: Bool

    public init(
        workspace: WorkspaceListEntry,
        projectId: String,
        projectName: String,
        branch: String,
        baseBranch: String?,
        recordedBaseBranch: Bool
    ) {
        self.workspace = workspace
        self.projectId = projectId
        self.projectName = projectName
        self.branch = branch
        self.baseBranch = baseBranch
        self.recordedBaseBranch = recordedBaseBranch
    }
}
