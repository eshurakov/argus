import Testing

@Suite
struct ProjectAndWorktreeUIContractTests {
    @Test
    func projectCreationSupportsCanonicalDuplicatesAndManualMainBranches() throws {
        let sheet = try SourceContract("Argus/Views/Dialogs/NewProjectSheet.swift")
        sheet.containsAll(
            [
                "@State private var mainBranch: String = \"\"",
                "@State private var isRepositoryValid: Bool = false",
                "@State private var branchDetectionWarning: String?",
                "TextField(\"Main branch\", text: $mainBranch)",
                "mainBranch = branch",
                "mainBranchOverride: branch.isEmpty ? nil : branch",
                "workspaceManager.hasDuplicateProject(repositoryRoot: repositoryRoot)",
                "validationError = \"Project already exists for this repository\"",
                "branchDetectionWarning = \"Could not detect main branch. Enter one manually.\"",
                ".padding(.vertical, 28)"
            ], "new project validation and main-branch override")
        let canCreate = try sheet.section(after: "private var canCreate: Bool {", before: "\n    }")
        #expect(canCreate.contains("isRepositoryValid"))
        #expect(!canCreate.contains("detectedBranch != nil"))
        #expect(!canCreate.contains("branchDetectionWarning"))

        let manager = try SourceContract("Argus/Services/WorkspaceManager+Projects.swift")
        manager.containsAll(
            [
                "func hasDuplicateProject(repositoryRoot: String) -> Bool",
                "hasDuplicateProject(repositoryRoot: repositoryRoot)",
                "mainBranchOverride: String? = nil",
                "let mainBranch = normalizedMainBranch.isEmpty ? (detectedMainBranch ?? \"\") : normalizedMainBranch",
                "guard !mainBranch.isEmpty else { return nil }",
                "let detectedMainBranch = try? await worktreeService.detectMainBranch"
            ], "workspace manager project validation")
        let duplicateCheck = try manager.section(
            after: "func hasDuplicateProject(repositoryRoot:",
            before: "func addWorkspaceToProject("
        )
        #expect(duplicateCheck.contains("!$0.isCatchAll"))
        #expect(duplicateCheck.contains("resolvingSymlinksInPath().path"))
    }

    @Test
    func projectAndCatchAllAddActionsStayDistinct() throws {
        let sidebar = try SourceContract("Argus/Views/Sidebar/SidebarView.swift")
        sidebar.containsAll(
            [
                "help: \"New Project\"",
                "accessibilityLabel: \"New Project\"",
                "name: .showNewProjectSheet",
                "help: \"New Workspace\"",
                "accessibilityLabel: \"New Workspace\"",
                "workspaceManager.addWorkspace()",
                "if project.isCatchAll {",
                "name: .showNewWorkspaceSheet",
                "userInfo: [\"projectId\": project.id]",
                "Button(\"Add Workspace…\")"
            ], "project and catch-all add controls")
        sidebar.excludes(
            "New Workspace or Project",
            "section plus buttons must not share a combined add menu"
        )
        sidebar.excludes(
            "Image(systemName: \"folder.badge.plus\")",
            "Projects plus creates a Project directly"
        )
    }

    @Test
    func sidebarAddMenuUsesIconActionAffordances() throws {
        let sidebar = try SourceContract("Argus/Views/Sidebar/SidebarView.swift")
        let addButton = try sidebar.section(
            after: "private struct SidebarSectionAddButton: View",
            before: "// MARK: - ProjectSection")

        for expected in [
            "@State private var isHovered = false",
            ".frame(width: 20, height: 20)",
            "isHovered ? ChromeColors.hoveredTabFill : Color.clear",
            ".contentShape(Rectangle())",
            ".cursor(.pointingHand)",
            ".help(help)",
            ".accessibilityLabel(accessibilityLabel)",
            ".onHover { isHovered = $0 }"
        ] {
            #expect(addButton.contains(expected))
        }
    }

    @Test
    func catchAllProjectHasDistinctWorkspaceSectionStyling() throws {
        try SourceContract("Argus/Views/Sidebar/SidebarView.swift").containsAll(
            [
                "private struct WorkspacesSectionHeader: View",
                "Text(\"Workspaces\")",
                ".textCase(.uppercase)",
                "ProjectSection(project: catchAll, showsHeader: false)",
                "if project.isExpanded || !showsHeader"
            ], "catch-all Workspaces section uses a Projects-style top-level header")
    }

    @Test
    func branchPickerFiltersChoicesAndRecoversFromTimeouts() throws {
        let sheet = try SourceContract("Argus/Views/Dialogs/NewWorkspaceSheet.swift")
        sheet.containsAll(
            [
                "@State private var branchFilter: String = \"\"",
                "private var filteredAvailableBranches: [String]",
                "localizedCaseInsensitiveContains(filter)",
                "TextField(\"Filter branches\", text: $branchFilter)",
                "ForEach(filteredAvailableBranches, id: \\.self)",
                "selectedExistingBranch = branch",
                "listWorkspaceBranchChoices(",
                "repositoryPath: project.repositoryPath",
                "defer { isLoadingBranches = false }",
                "errorMessage = error.localizedDescription"
            ], "existing branch picker")

    }

    @Test
    func duplicateBranchErrorsAreShownByTheWorkspaceSheet() throws {
        try SourceContract("Argus/Views/Dialogs/NewWorkspaceSheet.swift").contains(
            "case .branchAlreadyExists(let branchName):",
            "duplicate branch errors reach the Workspace creation sheet"
        )
    }

    @Test
    func newWorkspaceSheetSuggestsARandomBranchNameAndOptionalDisplayName() throws {
        let sheet = try SourceContract("Argus/Views/Dialogs/NewWorkspaceSheet.swift")
        sheet.containsAll(
            [
                "@State private var workspaceName: String = \"\"",
                "TextField(\"Name (optional)\", text: $workspaceName)",
                "regenerateBranchName()",
                "let candidate = RandomBranchNameGenerator.generate(prefix: prefix)",
                "newBranchName = candidate",
                "workspaceManager.worktreeService.suggestAvailableBranchName(",
                "preferring: candidate",
                "verified != candidate",
                "newBranchName == candidate",
                "Button(\"Regenerate\")",
                "customTitle: trimmedName.isEmpty ? nil : trimmedName"
            ], "random branch name suggestion and optional display name")
        sheet.excludes(
            "Image(system" + "Name:",
            "the New Workspace sheet must not depend on vector SF Symbol rasterization"
        )

        try SourceContract("Argus/Settings/SettingsView.swift").contains(
            "TextField(\"\", text: $settings.newBranchPrefix",
            "branch prefix setting remains editable in its labeled content row"
        )
    }

    @Test
    func orphanAdoptionUsesTheExistingWorktree() throws {
        let manager = try SourceContract("Argus/Services/WorkspaceManager.swift")
        manager.containsAll(
            [
                "func adoptOrphanedWorktree(",
                "workingDirectory: orphan.path",
                "worktreePath: orphan.path",
                "orphan.branchName ??"
            ], "orphan adoption")
        let sheet = try SourceContract("Argus/Views/Dialogs/OrphanedWorktreesSheet.swift")
        sheet.contains(
            "workspaceManager.adoptOrphanedWorktree(orphan)",
            "orphan sheet must use the dedicated adoption operation"
        )
        let adoption = try sheet.section(
            after: "private func adoptOrphan", before: "private func deleteOrphan")
        #expect(!adoption.contains("addWorkspaceToProject"))
    }

    @Test
    func closingAWorktreeWorkspaceOffersDeletionExplicitly() throws {
        let manager = try SourceContract("Argus/Services/WorkspaceManager.swift")
        manager.containsAll(
            [
                "shouldConfirmWorktreeDeletionBeforeClosing(_ workspaceId: UUID) -> Bool",
                "workspace.worktreePath != nil",
                "!project.isCatchAll",
                "onProgress: (@MainActor @Sendable (WorkspaceDeletionStage) -> Void)? = nil",
                "try await worktreeService.removeWorktree",
                "onProgress?(.removingWorktree)",
                "onProgress?(.closingWorkspace)",
                "await Task.yield()",
                "lastWorkspaceDeletionError = error",
                "requestCloseTab(activeTabId, in: workspace.id)"
            ], "worktree close behavior")
        try SourceContract("Argus/Views/Sidebar/SidebarView.swift").containsAll(
            [
                "static let showCloseWorkspaceConfirmation",
                "workspaceManager.requestCloseWorkspace(workspace.id)"
            ], "sidebar close confirmation")
        manager.containsAll(
            [
                "func requestCloseWorkspace(_ workspaceId: UUID)",
                "shouldConfirmWorktreeDeletionBeforeClosing(workspaceId)",
                "shouldConfirmRunningProcessBeforeClosingWorkspace(workspaceId)",
                "name: .showCloseWorkspaceConfirmation"
            ], "workspace close confirmation owner")
        try SourceContract("Argus/Views/Content/TabBarView.swift").contains(
            "workspaceManager.requestCloseTab(panelId, in: workspace.id)",
            "tab close routing"
        )
        try SourceContract("Argus/Views/MainWindowView.swift").containsAll(
            [
                "@State private var closeWorkspaceRequest: CloseWorkspaceRequest?",
                "CloseWorkspaceConfirmationView(",
                "onCloseOnly: { closeWorkspace(closeWorkspaceRequest) }",
                "onDeleteWorktree: { deleteWorktreeAndCloseWorkspace(closeWorkspaceRequest.id) }",
                "WorkspaceDeletionProgressView(stage: workspaceDeletionStage)",
                "Git is unregistering the worktree and deleting its files.",
                "Closing terminal panels and updating workspace state.",
                "workspaceDeletionStage = .removingWorktree",
                "workspaceDeletionStage = nil",
                ".alert(\"Could Not Delete Worktree\", isPresented: $showWorkspaceDeletionError)"
            ], "worktree close choices")
    }
}
