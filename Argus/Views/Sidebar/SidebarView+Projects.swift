import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ProjectSection

/// A collapsible project section containing a header row and its child
/// workspace rows.
struct ProjectSection: View {
    @ObservedObject var project: Project
    var showsHeader: Bool = true
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                ProjectHeaderRow(project: project)
                    .windowFocusChrome()
                    .padding(.top, 4)
            }

            if project.isExpanded || !showsHeader {
                ForEach(workspaceManager.sidebarItems(for: project)) { item in
                    switch item {
                    case .workspace(let workspaceId):
                        workspaceRow(workspaceId)
                    case .stack(let group):
                        stackSection(group)
                            .id(group.id)
                    }
                }
            } else {
                SidebarCollapsedWorkspaceSummary(workspaceIds: project.workspaceIds)
            }
        }
    }

    @ViewBuilder
    func workspaceRow(_ workspaceId: UUID, stackRelationship: WorkspaceStackRow? = nil) -> some View {
        if let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId }),
            let globalIndex = workspaceManager.globalSidebarIndex(for: workspace.id)
        {
            SidebarWorkspaceRow(
                workspace: workspace,
                globalIndex: globalIndex,
                shortcutDigit: workspaceManager.workspaceShortcutDigit(for: workspace.id),
                isSelected: workspace.id == workspaceManager.selectedWorkspaceId,
                onSelect: { workspaceManager.selectWorkspace(workspace.id) },
                stackRelationship: stackRelationship,
                showsStackGutter: stackRelationship != nil
            )
            .modifier(SidebarWorkspaceReordering(projectId: project.id, workspaceId: workspace.id))
            .contextMenu {
                workspaceContextMenu(for: workspace, isStack: stackRelationship != nil)
            }
            .id(workspace.id)
        }
    }

    @ViewBuilder
    private func workspaceContextMenu(for workspace: Workspace, isStack: Bool) -> some View {
        Button("Rename…") {
            NotificationCenter.default.post(
                name: .showRenameWorkspaceSheet,
                object: nil,
                userInfo: ["workspaceId": workspace.id]
            )
        }
        if workspace.workspaceType == .external {
            Button("Change Working Directory…") {
                chooseWorkspaceRoot(for: workspace)
            }
            Button("Enter Path Directly…") {
                NotificationCenter.default.post(
                    name: .showChangeWorkspaceRootSheet,
                    object: nil,
                    userInfo: ["workspaceId": workspace.id]
                )
            }
        }
        workspaceMoveActions(for: workspace.id, isStack: isStack)
        Divider()
        Button("Copy Path") {
            copyPath(workspace.worktreePath)
        }
        .disabled(workspace.worktreePath == nil)
        Divider()
        Button("Close Workspace") {
            workspaceManager.requestCloseWorkspace(workspace.id)
        }
    }

    @ViewBuilder
    func workspaceMoveActions(for workspaceId: UUID, isStack: Bool) -> some View {
        Button(isStack ? "Move Stack Up" : "Move Up") {
            workspaceManager.moveWorkspace(in: project.id, moving: workspaceId, offset: -1)
        }
        .disabled(!workspaceManager.canMoveWorkspace(in: project.id, moving: workspaceId, offset: -1))
        Button(isStack ? "Move Stack Down" : "Move Down") {
            workspaceManager.moveWorkspace(in: project.id, moving: workspaceId, offset: 1)
        }
        .disabled(!workspaceManager.canMoveWorkspace(in: project.id, moving: workspaceId, offset: 1))
    }

    private func copyPath(_ path: String?) {
        guard let path else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    private func chooseWorkspaceRoot(for workspace: Workspace) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workspace.currentDirectory)
        panel.message = "Select the working directory for \(workspace.displayTitle)"
        guard panel.runModal() == .OK, let directoryURL = panel.url else { return }
        workspaceManager.setStandaloneWorkspaceRoot(workspace.id, directoryURL: directoryURL)
    }
}

// MARK: - Workspace Drag and Drop

struct SidebarWorkspaceReordering: ViewModifier {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    let projectId: UUID
    let workspaceId: UUID

    func body(content: Content) -> some View {
        content
            .onDrag {
                SidebarWorkspaceDragState.draggedWorkspaceId = workspaceId
                return NSItemProvider(object: workspaceId.uuidString as NSString)
            }
            .onDrop(
                of: [UTType.text],
                delegate: SidebarWorkspaceDropDelegate(
                    workspaceManager: workspaceManager,
                    projectId: projectId,
                    targetWorkspaceId: workspaceId
                )
            )
    }
}

@MainActor
private enum SidebarWorkspaceDragState {
    static var draggedWorkspaceId: UUID?
}

private struct SidebarWorkspaceDropDelegate: DropDelegate {
    let workspaceManager: WorkspaceManager
    let projectId: UUID
    let targetWorkspaceId: UUID

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedWorkspaceId = SidebarWorkspaceDragState.draggedWorkspaceId else { return false }
        defer { SidebarWorkspaceDragState.draggedWorkspaceId = nil }
        return workspaceManager.reorderWorkspace(
            in: projectId,
            moving: draggedWorkspaceId,
            before: targetWorkspaceId
        )
    }
}

// MARK: - ProjectHeaderRow

/// Disclosure-triangle header for a project. Shows color dot, display name,
/// and provides a context menu for project operations.
private struct ProjectHeaderRow: View {
    @ObservedObject var project: Project
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sidebarWidthMetrics) private var sidebarMetrics
    @State private var isHovered = false
    @State private var isAddHovered = false
    @State private var isRemovingProject = false
    @FocusState private var focusedControl: FocusedControl?

    private enum FocusedControl: Hashable {
        case disclosure
        case add
    }

    private var childWorkspaces: [Workspace] {
        project.workspaceIds.compactMap { workspaceId in
            workspaceManager.workspaces.first { $0.id == workspaceId }
        }
    }

    private var showsAddAction: Bool {
        isHovered || focusedControl != nil
    }

    private var hasStackDiscoveryStatus: Bool {
        !project.isCatchAll
            && (workspaceManager.refreshingWorkspaceStackProjectIds.contains(project.id)
                || workspaceManager.workspaceStackErrors[project.id] != nil)
    }

    var body: some View {
        HStack(spacing: sidebarMetrics.headerSpacing) {
            disclosureButton
            if !project.isCatchAll {
                if !sidebarMetrics.isCompact || hasStackDiscoveryStatus {
                    SidebarStackDiscoveryStatus(projectId: project.id)
                }
            }
            if !sidebarMetrics.isCompact || !hasStackDiscoveryStatus {
                addWorkspaceButton
            }
        }
        .padding(.horizontal, sidebarMetrics.rowPadding)
        .padding(.vertical, appSettings.presentationMetrics.projectHeaderVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered || focusedControl != nil ? ChromeColors.hoveredTabFill : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            if project.isCatchAll {
                Button("Add Workspace…") {
                    workspaceManager.addWorkspace()
                }
            } else {
                Button("Rename…") {
                    NotificationCenter.default.post(
                        name: .showRenameProjectSheet,
                        object: nil,
                        userInfo: ["projectId": project.id]
                    )
                }
                Button("Add Workspace…") {
                    NotificationCenter.default.post(
                        name: .showNewWorkspaceSheet,
                        object: nil,
                        userInfo: ["projectId": project.id]
                    )
                }
                Button("Refresh Stacks") {
                    workspaceManager.refreshWorkspaceStacks(in: project.id)
                }
                .disabled(workspaceManager.refreshingWorkspaceStackProjectIds.contains(project.id))
                Divider()
                Button("Remove Project") {
                    confirmProjectRemoval()
                }
                .disabled(isRemovingProject)
            }
        }
    }

    private var disclosureButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                workspaceManager.cancelPendingWorkspaceStackReveal(in: project.id)
                project.isExpanded.toggle()
            }
        } label: {
            HStack(spacing: sidebarMetrics.headerSpacing) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                    .rotationEffect(.degrees(project.isExpanded ? 90 : 0))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: project.isExpanded)
                    .frame(width: sidebarMetrics.disclosureWidth)

                if let color = project.color {
                    Circle()
                        .fill(Color(nsColor: color.nsColor))
                        .frame(width: sidebarMetrics.isCompact ? 4 : 8, height: sidebarMetrics.isCompact ? 4 : 8)
                }

                Text(project.displayName)
                    .font(
                        .system(
                            size: appSettings.presentationMetrics.textSize(forBaseSize: 11),
                            weight: .semibold
                        )
                    )
                    .foregroundColor(.secondary)
                    .textCase(project.isCatchAll ? .uppercase : nil)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                if !sidebarMetrics.isCompact {
                    Spacer(minLength: 0)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: .disclosure)
        .cursor(.pointingHand)
        .accessibilityLabel("\(project.displayName), Project")
        .accessibilityValue(project.isExpanded ? "Expanded" : "Collapsed")
        .help("\(project.isExpanded ? "Collapse" : "Expand") \(project.displayName) Project")
    }

    private var addWorkspaceButton: some View {
        Button {
            if project.isCatchAll {
                workspaceManager.addWorkspace()
            } else {
                NotificationCenter.default.post(
                    name: .showNewWorkspaceSheet,
                    object: nil,
                    userInfo: ["projectId": project.id]
                )
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .frame(width: 20, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isAddHovered || focusedControl == .add ? ChromeColors.hoveredTabFill : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .focused($focusedControl, equals: .add)
        .opacity(showsAddAction ? 1 : 0)
        .allowsHitTesting(showsAddAction)
        .accessibilityHidden(!showsAddAction)
        .onHover { isAddHovered = $0 }
        .cursor(.pointingHand)
        .help("Add Workspace")
        .accessibilityLabel("Add Workspace to \(project.displayName)")
    }

    private func confirmProjectRemoval() {
        guard !isRemovingProject else { return }

        guard
            confirmDestructiveAction(
                title: "Remove Project \"\(project.displayName)\"?",
                message: projectRemovalMessage,
                confirmTitle: "Remove Project"
            )
        else { return }

        isRemovingProject = true
        Task {
            await workspaceManager.removeProject(project.id)
        }
    }

    private var projectRemovalMessage: String {
        let workspaceCount = childWorkspaces.count
        let worktreeCount = childWorkspaces.filter { $0.worktreePath != nil }.count
        let workspaceLabel = workspaceCount == 1 ? "Workspace" : "Workspaces"
        let worktreeLabel = worktreeCount == 1 ? "worktree" : "worktrees"
        return "This permanently removes \(workspaceCount) \(workspaceLabel) from Argus "
            + "and deletes \(worktreeCount) associated \(worktreeLabel) from disk. "
            + "This cannot be undone."
    }
}
