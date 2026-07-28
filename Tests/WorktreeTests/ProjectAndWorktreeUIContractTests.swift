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
                "Menu {",
                "Label(\"New Workspace\", systemImage: \"terminal\")",
                "Label(\"New Project…\", systemImage: \"folder.badge.plus\")",
                "Image(systemName: \"plus\")",
                "if project.isCatchAll {",
                "workspaceManager.addWorkspace()",
                "name: .showNewWorkspaceSheet",
                "userInfo: [\"projectId\": project.id]",
                "Button(\"Add Workspace…\")"
            ], "project and catch-all add controls")
    }

    @Test
    func sidebarAddMenuUsesIconActionAffordances() throws {
        let sidebar = try SourceContract("Argus/Views/Sidebar/SidebarView.swift")
        let header = try sidebar.section(
            after: "private struct SidebarHeader: View",
            before: "// MARK: - ProjectSection")

        for expected in [
            "@State private var isAddMenuHovered = false",
            ".frame(width: 20, height: 20)",
            "isAddMenuHovered ? ChromeColors.hoveredTabFill : Color.clear",
            ".contentShape(Rectangle())",
            ".cursor(.pointingHand)",
            ".help(\"New Workspace or Project\")",
            ".accessibilityLabel(\"New Workspace or Project\")",
            ".onHover { isAddMenuHovered = $0 }"
        ] {
            #expect(header.contains(expected))
        }
    }

    @Test
    func catchAllProjectHasDistinctWorkspaceSectionStyling() throws {
        try SourceContract("Argus/Views/Sidebar/SidebarView.swift").containsAll(
            [
                ".fill(ChromeColors.separator)",
                ".frame(height: 1)",
                ".textCase(project.isCatchAll ? .uppercase : nil)"
            ], "catch-all Project separator and Workspace section label")
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

        let discovery = try SourceContract("Argus/Services/WorktreeService+Discovery.swift")
        discovery.containsAll(
            [
                "func listWorkspaceBranchChoices(repositoryPath: String) async throws -> [String]",
                "!$0.isHead"
            ], "branch discovery and timeout behavior")
        try SourceContract("Argus/Services/WorktreeService.swift").containsAll(
            [
                "timeout: TimeInterval? = nil", "Task.sleep(nanoseconds:",
                "process.terminate()"
            ], "git process timeout behavior")
        let operations = try SourceContract("Argus/Services/WorktreeService+Operations.swift")
        operations.containsAll(
            [
                "private func listRemoteHeadBranches", "ls-remote", "timeout: 2"
            ], "remote branch timeout behavior")
    }

    @Test
    func duplicateBranchesAreRejectedWithAVisibleError() throws {
        let manager = try SourceContract("Argus/Services/WorkspaceManager+Projects.swift")
        let addWorkspace = try manager.section(
            after: "func addWorkspaceToProject(",
            before: "private func restoreSelectionAfterRemovingWorkspaces"
        )
        #expect(!addWorkspace.contains("uniqueBranchName(branchName"))
        #expect(addWorkspace.contains("try await worktreeService.ensureBranchNameAvailable("))
        #expect(addWorkspace.contains("branchName,"))
        #expect(addWorkspace.contains("repositoryPath: project.repositoryPath"))

        let service = try SourceContract("Argus/Services/WorktreeService.swift")
        service.containsAll(
            [
                "func ensureBranchNameAvailable(_ branchName: String, repositoryPath: String) async throws",
                "throw WorktreeError.branchAlreadyExists(baseName)"
            ], "duplicate branch validation")
        try SourceContract("Argus/Views/Dialogs/NewWorkspaceSheet.swift").containsAll(
            [
                "case .branchAlreadyExists(let branchName):",
                "errorMessage = \"Branch '\\(branchName)' already exists\""
            ], "duplicate branch error")
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
            "Image(systemName:",
            "the New Workspace sheet must not depend on vector SF Symbol rasterization"
        )

        let generator = try SourceContract("Argus/Models/RandomBranchNameGenerator.swift")
        generator.containsAll(
            [
                "static func generate(prefix: String = \"\") -> String",
                "adjectives.randomElement()",
                "nouns.randomElement()"
            ], "random two-word name generation")

        let service = try SourceContract("Argus/Services/WorktreeService+Operations.swift")
        service.containsAll(
            [
                "func suggestAvailableBranchName(",
                "preferring candidate: String",
                "if !existingBranches.contains(candidate) {",
                "return try await uniqueBranchName(candidate, repositoryPath: repositoryPath)"
            ], "random branch name suggestions avoid existing branches")

        let manager = try SourceContract("Argus/Services/WorkspaceManager+Projects.swift")
        manager.containsAll(
            [
                "customTitle: String? = nil",
                "workspace.setCustomTitle(customTitle)"
            ], "optional custom title is applied to the created workspace")

        let settings = try SourceContract("Argus/Settings/AppSettings.swift")
        settings.contains(
            "@Published var newBranchPrefix: String {",
            "branch prefix is a persisted setting"
        )
        try SourceContract("Argus/Settings/SettingsView.swift").containsAll(
            [
                "TextField(\"Branch prefix\", text: $settings.newBranchPrefix"
            ], "branch prefix setting is editable")
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
                "workspaceManager.shouldConfirmWorktreeDeletionBeforeClosing(workspace.id)",
                "name: .showCloseWorkspaceConfirmation"
            ], "sidebar close confirmation")
        try SourceContract("Argus/Views/Content/TabBarView.swift").contains(
            "workspaceManager.requestCloseTab(panelId, in: workspace.id)",
            "tab close routing"
        )
        try SourceContract("Argus/Views/MainWindowView.swift").containsAll(
            [
                ".alert(\"Close Workspace?\", isPresented: $showCloseWorkspaceConfirmation)",
                "closeWorkspaceCanDeleteWorktree ? \"Close Only\" : \"Close Workspace\"",
                "Button(\"Delete Worktree and Close\", role: .destructive)",
                "WorkspaceDeletionProgressView(stage: workspaceDeletionStage)",
                "Git is unregistering the worktree and deleting its files.",
                "Closing terminal panels and updating workspace state.",
                "workspaceDeletionStage = .removingWorktree",
                "workspaceDeletionStage = nil",
                "if !removed",
                ".alert(\"Could Not Delete Worktree\", isPresented: $showWorkspaceDeletionError)"
            ], "worktree close choices")
    }
}
