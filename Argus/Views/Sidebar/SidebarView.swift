// SidebarView.swift
// Argus
//
// Left sidebar showing the two-level project hierarchy (Phase 2).
// Projects appear as collapsible headers; workspaces are children.
// The catch-all project shows standalone workspaces under "Workspaces".

import SwiftUI

// Source membership is explicit in project.pbxproj, which this refactor must not modify.

// MARK: - Notification Names

extension Notification.Name {
    static let showNewProjectSheet = Notification.Name("ArgusShowNewProjectSheet")
    static let showNewWorkspaceSheet = Notification.Name("ArgusShowNewWorkspaceSheet")
    static let showRenameProjectSheet = Notification.Name("ArgusShowRenameProjectSheet")
    static let showRenameWorkspaceSheet = Notification.Name("ArgusShowRenameWorkspaceSheet")
    static let showChangeWorkspaceRootSheet = Notification.Name("ArgusShowChangeWorkspaceRootSheet")
    static let showCloseWorkspaceConfirmation = Notification.Name("ArgusShowCloseWorkspaceConfirmation")
}

// MARK: - SidebarView

struct SidebarView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
}
