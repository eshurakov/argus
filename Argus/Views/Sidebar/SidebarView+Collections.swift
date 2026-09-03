import SwiftUI

private struct SidebarCollectionContentInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var sidebarCollectionContentInset: CGFloat {
        get { self[SidebarCollectionContentInsetKey.self] }
        set { self[SidebarCollectionContentInsetKey.self] = newValue }
    }
}

struct SidebarCollectionSection: View {
    let collection: ProjectCollection
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.sidebarWidthMetrics) private var sidebarMetrics

    var body: some View {
        VStack(spacing: 0) {
            SidebarCollectionHeader(collection: collection)
                .modifier(SidebarNavigationDropTarget(target: .collection(collection.id)))
                .onDrag { workspaceManager.collectionDrag(collection.id).itemProvider }
            if collection.isExpanded {
                ForEach(workspaceManager.projects(in: collection.id)) { project in
                    ProjectSection(project: project)
                }
            } else {
                SidebarCollapsedWorkspaceSummary(
                    workspaceIds: workspaceManager.projects(in: collection.id).flatMap(\.workspaceIds),
                    showsProjectContext: true
                )
            }
        }
        .environment(\.sidebarCollectionContentInset, sidebarMetrics.isCompact ? 0 : 8)
        .padding(.top, appSettings.presentationMetrics.projectHeaderVerticalPadding + 10)
        .padding(.bottom, appSettings.presentationMetrics.projectHeaderVerticalPadding + 2)
    }
}

struct SidebarCollectionHeader: View {
    let collection: ProjectCollection
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.sidebarWidthMetrics) private var sidebarMetrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                workspaceManager.toggleCollection(collection.id)
            }
        } label: {
            HStack(spacing: sidebarMetrics.headerSpacing) {
                Image(systemName: collection.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: sidebarMetrics.disclosureWidth)
                    .accessibilityHidden(true)
                Text(collection.name)
                    .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 12), weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                if !sidebarMetrics.isCompact {
                    Rectangle()
                        .fill(ChromeColors.separator)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .padding(.horizontal, sidebarMetrics.rowPadding)
            .padding(.vertical, appSettings.presentationMetrics.projectHeaderVerticalPadding)
            .windowFocusChrome()
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered || isFocused ? ChromeColors.hoveredTabFill : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .cursor(.pointingHand)
        .help("\(collection.isExpanded ? "Collapse" : "Expand") \(collection.name) Collection")
        .accessibilityLabel("\(collection.name), Collection")
        .accessibilityValue(collection.isExpanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("collection-\(collection.id)")
        .contextMenu {
            Button("Rename Collection…") {
                NotificationCenter.default.post(name: .showCollectionSheet, object: collection.id)
            }
            Button("Move Up") { workspaceManager.moveCollection(collection.id, offset: -1) }
                .disabled(!workspaceManager.canMoveCollection(collection.id, offset: -1))
            Button("Move Down") { workspaceManager.moveCollection(collection.id, offset: 1) }
                .disabled(!workspaceManager.canMoveCollection(collection.id, offset: 1))
            Divider()
            Button("Remove Collection") { workspaceManager.removeCollection(collection.id) }
                .help("Return Projects to Other Projects. No Workspaces or worktrees are removed.")
        }
    }
}

struct SidebarOtherProjectsHeader: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.sidebarWidthMetrics) private var sidebarMetrics

    var body: some View {
        Text("Other Projects")
            .lineLimit(1)
            .truncationMode(.tail)
            .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 11), weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .padding(.horizontal, sidebarMetrics.rowPadding)
            .padding(.top, appSettings.presentationMetrics.projectHeaderVerticalPadding + 10)
            .padding(.bottom, appSettings.presentationMetrics.projectHeaderVerticalPadding + 2)
            .windowFocusChrome()
            .modifier(SidebarNavigationDropTarget(target: .otherProjects))
    }
}

struct ProjectCollectionMenu: View {
    let projectId: UUID
    @EnvironmentObject private var workspaceManager: WorkspaceManager

    var body: some View {
        Menu("Move to Collection") {
            Button("No Collection") { workspaceManager.moveProject(projectId, toCollection: nil) }
                .disabled(workspaceManager.collection(containing: projectId) == nil)
            ForEach(workspaceManager.collections) { collection in
                Button(collection.name) { workspaceManager.moveProject(projectId, toCollection: collection.id) }
                    .disabled(workspaceManager.collection(containing: projectId)?.id == collection.id)
            }
        }
        Button("Move Project Up") { workspaceManager.moveProject(projectId, offset: -1) }
            .disabled(!workspaceManager.canMoveProject(projectId, offset: -1))
        Button("Move Project Down") { workspaceManager.moveProject(projectId, offset: 1) }
            .disabled(!workspaceManager.canMoveProject(projectId, offset: 1))
    }
}

struct SidebarUngroupedProjects: View {
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @Environment(\.sidebarWidthMetrics) private var sidebarMetrics

    var body: some View {
        ForEach(workspaceManager.ungroupedProjects) { project in
            ProjectSection(project: project)
        }
        .environment(
            \.sidebarCollectionContentInset,
            workspaceManager.collections.isEmpty || sidebarMetrics.isCompact ? 0 : 8
        )
    }
}
