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

                    // Catch-all project last
                    if let catchAll = workspaceManager.catchAllProject {
                        Rectangle()
                            .fill(ChromeColors.separator)
                            .frame(height: 1)
                            .padding(.vertical, 8)

                        ProjectSection(project: catchAll)
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

/// Top header with "Projects" label and add-project / add-workspace buttons.
private struct SidebarHeader: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var isAddMenuHovered = false

    var body: some View {
        HStack {
            Text("Projects")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Spacer()
            // Global add menu for standalone workspaces and projects.
            Menu {
                Button(
                    action: {
                        workspaceManager.addWorkspace()
                    },
                    label: {
                        Label {
                            Text("New Workspace")
                        } icon: {
                            SemanticIcon(name: "terminal", pointSize: 13, weight: .regular)
                        }
                    })

                Button(
                    action: {
                        NotificationCenter.default.post(name: .showNewProjectSheet, object: nil)
                    },
                    label: {
                        Label {
                            Text("New Project…")
                        } icon: {
                            SemanticIcon(name: "folder.badge.plus", pointSize: 13, weight: .regular)
                        }
                    })
            } label: {
                SemanticIcon(name: "plus", pointSize: 12, weight: .regular)
                    .frame(width: 20, height: 20)
                    .background {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isAddMenuHovered ? ChromeColors.hoveredTabFill : Color.clear)
                    }
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundColor(.secondary)
            .cursor(.pointingHand)
            .help("New Workspace or Project")
            .accessibilityLabel("New Workspace or Project")
            .onHover { isAddMenuHovered = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .padding(.top, 28)  // Space for titlebar traffic lights
    }
}
