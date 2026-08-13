import Foundation
import SwiftUI

/// Session-scoped Right Sidebar expansion state.
///
/// This is runtime view state, not Session Snapshot data. It survives
/// Right-sidebar View switches, Right Sidebar hide/show, and Workspace
/// selection changes for the lifetime of the main window.
@MainActor
final class RightSidebarSessionState: ObservableObject {
    struct FilesKey: Hashable {
        let workspaceId: UUID
        let rootPath: String
    }

    @Published private var filesExpandedDirectoryIds: [FilesKey: Set<String>] = [:]
    @Published private var changesExpandedSectionKinds: [UUID: Set<GitChangeSectionKind>] = [:]
    @Published private var changesCollapsedDirectoryIds: [UUID: Set<String>] = [:]

    static let defaultExpandedSectionKinds = Set(GitChangeSectionKind.allCases)

    func expandedDirectoryIds(workspaceId: UUID, rootPath: String) -> Set<String> {
        filesExpandedDirectoryIds[FilesKey(workspaceId: workspaceId, rootPath: rootPath)] ?? []
    }

    func setExpandedDirectoryIds(_ ids: Set<String>, workspaceId: UUID, rootPath: String) {
        filesExpandedDirectoryIds[FilesKey(workspaceId: workspaceId, rootPath: rootPath)] = ids
    }

    func expandDirectory(_ id: String, workspaceId: UUID, rootPath: String) {
        var ids = expandedDirectoryIds(workspaceId: workspaceId, rootPath: rootPath)
        ids.insert(id)
        setExpandedDirectoryIds(ids, workspaceId: workspaceId, rootPath: rootPath)
    }

    func collapseDirectory(_ id: String, workspaceId: UUID, rootPath: String) {
        var ids = expandedDirectoryIds(workspaceId: workspaceId, rootPath: rootPath)
        ids.remove(id)
        setExpandedDirectoryIds(ids, workspaceId: workspaceId, rootPath: rootPath)
    }

    func expandedSectionKinds(for workspaceId: UUID) -> Set<GitChangeSectionKind> {
        changesExpandedSectionKinds[workspaceId] ?? Self.defaultExpandedSectionKinds
    }

    func setSectionExpanded(
        _ kind: GitChangeSectionKind,
        isExpanded: Bool,
        workspaceId: UUID
    ) {
        var kinds = expandedSectionKinds(for: workspaceId)
        if isExpanded {
            kinds.insert(kind)
        } else {
            kinds.remove(kind)
        }
        changesExpandedSectionKinds[workspaceId] = kinds
    }

    func collapsedDirectoryIds(for workspaceId: UUID) -> Set<String> {
        changesCollapsedDirectoryIds[workspaceId] ?? []
    }

    func toggleCollapsedDirectory(_ id: String, workspaceId: UUID) {
        var ids = collapsedDirectoryIds(for: workspaceId)
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        changesCollapsedDirectoryIds[workspaceId] = ids
    }

    func retainWorkspaces(_ workspaceIds: Set<UUID>) {
        filesExpandedDirectoryIds = filesExpandedDirectoryIds.filter {
            workspaceIds.contains($0.key.workspaceId)
        }
        changesExpandedSectionKinds = changesExpandedSectionKinds.filter {
            workspaceIds.contains($0.key)
        }
        changesCollapsedDirectoryIds = changesCollapsedDirectoryIds.filter {
            workspaceIds.contains($0.key)
        }
    }
}
