import SwiftUI

extension SidebarView {
    var body: some View {
        VStack(spacing: 0) {
            // Header with title and global add buttons
            SidebarHeader()

            // Project sections
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Named projects first
                    ForEach(workspaceManager.namedProjects, id: \.id) { project in
                        ProjectSection(project: project)
                    }

                    // Catch-all project last, as a top-level section like Projects.
                    if let catchAll = workspaceManager.catchAllProject {
                        WorkspacesSectionHeader()
                        ProjectSection(project: catchAll, showsHeader: false)
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer()
        }
        .frame(maxHeight: .infinity)
        .background(ChromeColors.shellBackground)
    }
}

// MARK: - Sidebar Header

/// Top header with "Projects" label and a New Project action.
private struct SidebarHeader: View {
    var body: some View {
        HStack {
            Text("Projects")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Spacer()
            SidebarSectionAddButton(
                help: "New Project",
                accessibilityLabel: "New Project"
            ) {
                NotificationCenter.default.post(name: .showNewProjectSheet, object: nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .padding(.top, 28)  // Space for titlebar traffic lights
    }
}

// MARK: - Workspaces Section Header

/// Top-level section header for the Catch-all Project, matching Projects.
private struct WorkspacesSectionHeader: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        HStack {
            Text("Workspaces")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Spacer()
            SidebarSectionAddButton(
                help: "New Workspace",
                accessibilityLabel: "New Workspace"
            ) {
                workspaceManager.addWorkspace()
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - Section Add Button

/// Compact plus control used by the Projects and Workspaces section headers.
private struct SidebarSectionAddButton: View {
    let help: String
    let accessibilityLabel: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .frame(width: 20, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isHovered ? ChromeColors.hoveredTabFill : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .cursor(.pointingHand)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .onHover { isHovered = $0 }
    }
}
