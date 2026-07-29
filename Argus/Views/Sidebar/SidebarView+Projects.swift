import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ProjectSection

/// A collapsible project section containing a header row and its child
/// workspace rows.
struct ProjectSection: View {
    @ObservedObject var project: Project
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @EnvironmentObject private var appSettings: AppSettings

    /// Workspaces belonging to this project, in project workspace order.
    private var childWorkspaces: [Workspace] {
        project.workspaceIds.compactMap { wsId in
            workspaceManager.workspaces.first { $0.id == wsId }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ProjectHeaderRow(project: project)
                .padding(.top, 4)

            if project.isExpanded {
                ForEach(childWorkspaces, id: \.id) { workspace in
                    if let globalIndex = workspaceManager.globalSidebarIndex(for: workspace.id) {
                        SidebarWorkspaceRow(
                            workspace: workspace,
                            globalIndex: globalIndex,
                            isSelected: workspace.id == workspaceManager.selectedWorkspaceId,
                            onSelect: { workspaceManager.selectWorkspace(workspace.id) }
                        )
                        .onDrag {
                            SidebarWorkspaceDragState.draggedWorkspaceId = workspace.id
                            return NSItemProvider(object: workspace.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: SidebarWorkspaceDropDelegate(
                                workspaceManager: workspaceManager,
                                projectId: project.id,
                                targetWorkspaceId: workspace.id
                            )
                        )
                        .contextMenu {
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
                            }
                            Button("Move Up") {
                                moveWorkspaceUp(workspace.id)
                            }
                            .disabled(project.workspaceIds.first == workspace.id)
                            Button("Move Down") {
                                moveWorkspaceDown(workspace.id)
                            }
                            .disabled(project.workspaceIds.last == workspace.id)
                            Divider()
                            Button("Copy Path") {
                                copyPath(workspace.worktreePath)
                            }
                            .disabled(workspace.worktreePath == nil)
                            Divider()
                            Button("Close Workspace") {
                                if workspaceManager.shouldConfirmWorktreeDeletionBeforeClosing(workspace.id) {
                                    NotificationCenter.default.post(
                                        name: .showCloseWorkspaceConfirmation,
                                        object: nil,
                                        userInfo: ["workspaceId": workspace.id]
                                    )
                                } else {
                                    workspaceManager.removeWorkspace(workspace.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func moveWorkspaceUp(_ workspaceId: UUID) {
        guard let index = project.workspaceIds.firstIndex(of: workspaceId),
            index > 0
        else { return }
        workspaceManager.reorderWorkspace(
            in: project.id,
            moving: workspaceId,
            before: project.workspaceIds[index - 1]
        )
    }

    private func moveWorkspaceDown(_ workspaceId: UUID) {
        guard let index = project.workspaceIds.firstIndex(of: workspaceId),
            index < project.workspaceIds.count - 1
        else { return }
        workspaceManager.reorderWorkspace(
            in: project.id,
            moving: project.workspaceIds[index + 1],
            before: workspaceId
        )
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
        workspaceManager.reorderWorkspace(
            in: projectId,
            moving: draggedWorkspaceId,
            before: targetWorkspaceId
        )
        return true
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
    @State private var isHovered = false
    @State private var isAddHovered = false
    @State private var showRemoveConfirmation = false
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

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    project.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    SemanticIcon(name: "chevron.right", pointSize: 9, weight: .semibold)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(project.isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: project.isExpanded)
                        .frame(width: 12)

                    if let color = project.color {
                        Circle()
                            .fill(Color(nsColor: color.nsColor))
                            .frame(width: 8, height: 8)
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

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .disclosure)
            .cursor(.pointingHand)
            .accessibilityLabel("\(project.displayName), Project")
            .accessibilityValue(project.isExpanded ? "Expanded" : "Collapsed")
            .help(project.isExpanded ? "Collapse Project" : "Expand Project")

            // Add workspace to this project
            Button(
                action: {
                    if project.isCatchAll {
                        workspaceManager.addWorkspace()
                    } else {
                        NotificationCenter.default.post(
                            name: .showNewWorkspaceSheet,
                            object: nil,
                            userInfo: ["projectId": project.id]
                        )
                    }
                },
                label: {
                    SemanticIcon(name: "plus", pointSize: 10, weight: .regular)
                        .frame(width: 20, height: 20)
                        .background {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isAddHovered || focusedControl == .add ? Color.primary.opacity(0.1) : Color.clear)
                        }
                        .contentShape(Rectangle())
                }
            )
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
        .padding(.horizontal, 8)
        .padding(.vertical, appSettings.presentationMetrics.projectHeaderVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered || focusedControl != nil ? Color.secondary.opacity(0.1) : Color.clear)
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
                Divider()
                Button("Remove Project", role: .destructive) {
                    showRemoveConfirmation = true
                }
                .disabled(isRemovingProject)
            }
        }
        .alert("Remove Project \"\(project.displayName)\"?", isPresented: $showRemoveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Project", role: .destructive) {
                isRemovingProject = true
                Task {
                    await workspaceManager.removeProject(project.id)
                }
            }
        } message: {
            Text(projectRemovalMessage)
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
