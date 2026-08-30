import Foundation
import Testing

@testable import Argus

@Suite
struct GitStatusParserTests {
    @Test
    func parsesBranchMetadataForCleanRepository() {
        let output = """
            # branch.oid 0123456789abcdef
            # branch.head feature/git-sidebar
            # branch.upstream origin/feature/git-sidebar
            # branch.ab +3 -2
            """

        let status = GitStatusPorcelainParser.parse(output, rootPath: "/tmp/repo")

        assertEqual(status.rootPath, "/tmp/repo", "root path is preserved")
        assertEqual(status.branchName, "feature/git-sidebar", "branch name parses")
        assertEqual(status.upstreamName, "origin/feature/git-sidebar", "upstream name parses")
        assertEqual(status.aheadCount, 3, "ahead count parses")
        assertEqual(status.behindCount, 2, "behind count parses")
        assertEqual(status.stagedCount, 0, "clean repo has no staged files")
        assertEqual(status.unstagedCount, 0, "clean repo has no unstaged files")
        assertEqual(status.untrackedCount, 0, "clean repo has no untracked files")
        assertEqual(status.isClean, true, "clean repo is clean")
    }

    @Test
    func parsesChangedFilesIntoSections() {
        let output = """
            # branch.head main
            1 M. N... 100644 100644 100644 aaaaaa bbbbbb staged.txt
            1 .M N... 100644 100644 100644 aaaaaa bbbbbb unstaged.txt
            1 D. N... 100644 000000 000000 aaaaaa 000000 deleted.txt
            ? new file.txt
            """

        let status = GitStatusPorcelainParser.parse(output, rootPath: "/tmp/repo")

        assertEqual(
            status.stagedFiles.map(\.path), ["staged.txt", "deleted.txt"], "staged paths parse")
        assertEqual(status.unstagedFiles.map(\.path), ["unstaged.txt"], "unstaged paths parse")
        assertEqual(status.untrackedFiles.map(\.path), ["new file.txt"], "untracked paths parse")
        assertEqual(status.stagedFiles.first?.status, .modified, "staged status parses")
        assertEqual(status.stagedFiles.last?.status, .deleted, "deleted status parses")
        assertEqual(status.untrackedFiles.first?.status, .untracked, "untracked status parses")
        assertEqual(status.isClean, false, "changed repo is dirty")
    }

    @Test
    func parsesNULTerminatedPathsWithoutGitQuoting() {
        let output =
            [
                "# branch.head main",
                "? café.txt",
                "? tab\tname.txt",
                "? line\nname.txt"
            ].joined(separator: "\u{0}") + "\u{0}"

        let status = GitStatusPorcelainParser.parse(output, rootPath: "/tmp/repo")

        assertEqual(
            status.untrackedFiles.map(\.path),
            ["café.txt", "tab\tname.txt", "line\nname.txt"],
            "NUL porcelain preserves exact filenames"
        )
    }

    @Test
    func parsesNULTerminatedRenameGrammar() {
        let output =
            "2 R. N... 100644 100644 100644 aaaaaa bbbbbb R100 new name.txt\u{0}old name.txt\u{0}"

        let status = GitStatusPorcelainParser.parse(output, rootPath: "/tmp/repo")

        assertEqual(status.stagedFiles.first?.path, "new name.txt", "rename destination parses")
        assertEqual(status.stagedFiles.first?.originalPath, "old name.txt", "rename source parses")
    }

    @Test
    func parsesRenamedAndCopiedFilesWithOriginalPaths() {
        let output = """
            # branch.head main
            2 R. N... 100644 100644 100644 aaaaaa bbbbbb R100 renamed folder/new file.txt	old folder/old file.txt
            2 C. N... 100644 100644 100644 aaaaaa bbbbbb C75 copied file.txt	template file.txt
            2 RM N... 100644 100644 100644 aaaaaa bbbbbb R86 moved and edited.txt	old edited.txt
            """

        let status = GitStatusPorcelainParser.parse(output, rootPath: "/tmp/repo")

        assertEqual(
            status.stagedFiles.map(\.path),
            ["renamed folder/new file.txt", "copied file.txt", "moved and edited.txt"],
            "renamed and copied staged paths parse")
        assertEqual(
            status.stagedFiles.map(\.originalPath),
            ["old folder/old file.txt", "template file.txt", "old edited.txt"],
            "renamed and copied original paths parse")
        assertEqual(
            status.stagedFiles.map(\.status), [.renamed, .copied, .renamed],
            "renamed and copied staged statuses parse")
        assertEqual(
            status.unstagedFiles.map(\.path), ["moved and edited.txt"],
            "renamed file with worktree edits appears in unstaged section")
        assertEqual(
            status.unstagedFiles.first?.originalPath, "old edited.txt",
            "unstaged rename companion preserves original path")
        assertEqual(
            status.unstagedFiles.first?.status, .modified, "unstaged rename companion status parses")
    }

    @Test
    func parsesTypeChangedFiles() {
        let output = """
            # branch.head main
            1 T. N... 100644 120000 120000 aaaaaa bbbbbb staged-symlink
            1 .T N... 100644 100644 120000 aaaaaa bbbbbb unstaged-symlink
            """

        let status = GitStatusPorcelainParser.parse(output, rootPath: "/tmp/repo")

        assertEqual(
            status.stagedFiles,
            [
                GitFileChange(path: "staged-symlink", status: .typeChanged, sectionKey: "staged")
            ], "staged type-changed file parses")
        assertEqual(
            status.unstagedFiles,
            [
                GitFileChange(path: "unstaged-symlink", status: .typeChanged, sectionKey: "unstaged")
            ], "unstaged type-changed file parses")
    }

    @Test
    func parsesUnmergedFilesWithPathSpaces() {
        let output = """
            # branch.head feature/conflict
            u UU N... 100644 100644 100644 100644 aaaaaa bbbbbb cccccc conflict folder/file with spaces.txt
            """

        let status = GitStatusPorcelainParser.parse(output, rootPath: "/tmp/repo")

        assertEqual(status.stagedFiles.isEmpty, true, "unmerged file is not treated as staged")
        assertEqual(
            status.unstagedFiles,
            [
                GitFileChange(
                    path: "conflict folder/file with spaces.txt", status: .unmerged, sectionKey: "unstaged")
            ], "unmerged path with spaces parses")
    }

    @Test
    func capsDisplayedFileRowsAtLimit() {
        let output = (0..<501)
            .map { "? file-\($0).txt" }
            .joined(separator: "\n")

        let status = GitStatusPorcelainParser.parse(output, rootPath: "/tmp/repo")

        assertEqual(status.untrackedCount, 501, "total untracked count is preserved")
        assertEqual(
            status.untrackedFiles.count, GitStatusSummary.displayFileLimit, "display rows are capped")
        assertEqual(status.isFileDisplayCapped, true, "capped flag is set")
        assertEqual(status.totalFileCount, 501, "total file count is preserved")
    }

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }
}

@Suite
struct GitStatusActionsUIContractTests {
    @Test
    func fileRowsExposeSectionAppropriateActions() throws {
        let view = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
        view.containsAll(
            [
                "fileActions(for file: GitFileChange)",
                "case .staged:", ".unstage",
                "case .unstaged:", "case .untracked:", ".stage",
                ".copyPath",
                "return \"Stage File\"", "return \"Unstage File\"",
                "return \"Discard Changes\"", "return \"Delete File\"",
                "return \"View Diff\"", "return \"View Blame\"", "return \"Copy Path\"",
                "perform(action, for: file, owner: owner)",
                "await performFileOperation(action.operation, path: file.path, owner: owner)",
                "viewModel.copyPath(file.path)",
                "case .fileOperationFailed(_, let message):",
                "if let systemImage = file.status.systemImage",
                "Circle()",
                ".frame(width: 6, height: 6)",
                ".foregroundColor(file.status.tintColor)",
                "accessibilityValue: fileAccessibilityValue(file)",
                ".accessibilityValue(accessibilityValue)",
                ".accessibilityActions {",
                ".contextMenu {"
            ], "git file row actions")
    }

    @Test
    func gitFileStatusesExposeDotsOrDistinctIconsAndAccessibleNames() {
        let expectedStyles = [
            ExpectedGitFileStatusStyle(status: .added, icon: nil, accessibleName: "Added"),
            ExpectedGitFileStatusStyle(status: .modified, icon: nil, accessibleName: "Modified"),
            ExpectedGitFileStatusStyle(status: .deleted, icon: nil, accessibleName: "Deleted"),
            ExpectedGitFileStatusStyle(status: .renamed, icon: "arrow.right", accessibleName: "Renamed"),
            ExpectedGitFileStatusStyle(status: .copied, icon: "doc.on.doc", accessibleName: "Copied"),
            ExpectedGitFileStatusStyle(
                status: .typeChanged, icon: "wrench.and.screwdriver", accessibleName: "Type changed"),
            ExpectedGitFileStatusStyle(status: .untracked, icon: nil, accessibleName: "Untracked"),
            ExpectedGitFileStatusStyle(
                status: .unmerged, icon: "exclamationmark.triangle", accessibleName: "Merge conflict")
        ]

        for style in expectedStyles {
            #expect(style.status.systemImage == style.icon)
            #expect(style.status.displayName == style.accessibleName)
        }

        #expect(GitFileStatus.added.tintColor == .green)
        #expect(GitFileStatus.untracked.tintColor == .green)
        #expect(GitFileStatus.modified.tintColor == .orange)
        #expect(GitFileStatus.deleted.tintColor == .red)
    }

    @Test
    func fileRowHoverKeepsLayoutAndHitAreaStable() throws {
        let view = try SourceContract("Argus/Views/GitSidebar/GitSidebarView+RowsAndOperations.swift")
        let fileRow = try view.section(
            after: "private struct GitChangeFileRow: View",
            before: "private var treeRowLeadingPadding")

        #expect(fileRow.contains("ZStack(alignment: .trailing)"))
        #expect(fileRow.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(fileRow.contains(".contentShape(Rectangle())"))
        #expect(fileRow.contains("@State private var isHovered = false"))
        #expect(fileRow.contains("@State private var hoveredAction: GitFileRowAction?"))
        #expect(fileRow.contains("isHovered ? ChromeColors.hoveredTabFill : Color.clear"))
        #expect(fileRow.contains("isHovered || isFocused"))
        #expect(fileRow.contains(".allowsHitTesting(revealsActions)"))
        #expect(fileRow.contains(".accessibilityHidden(!revealsActions)"))
        #expect(fileRow.contains(".focusable()"))
        #expect(fileRow.contains("canPerformActions && hoveredAction == action"))
        #expect(fileRow.contains("Image(systemName: action.systemImage)"))
        #expect(fileRow.contains(".foregroundStyle(.primary)"))
        #expect(fileRow.contains(".cursor(canPerformActions ? .pointingHand : .arrow)"))
        #expect(fileRow.contains("if canPerformActions && isHovering"))

        let sidebar = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
        sidebar.excludes("hoveredFileId", "file hover state must not invalidate the complete Changes View")
        sidebar.excludes("hoveredFileActionId", "action hover state must remain local to its file row")
    }

    @Test
    func directoryRowsShowFileEquivalentHoverFeedback() throws {
        let filesView = try SourceContract("Argus/Views/GitSidebar/RightSidebarView+WorkspaceFilesRows.swift")
        let filesDirectoryRow = try filesView.section(
            after: "func workspaceDirectoryRow(",
            before: "func workspaceFileRow(")
        let changesView = try SourceContract("Argus/Views/GitSidebar/GitSidebarView+Sections.swift")
        let changesDirectoryRow = try changesView.section(
            after: "struct GitChangeDirectoryRow: View",
            before: "extension GitSidebarView")

        for expected in [
            ".frame(maxWidth: .infinity, alignment: .leading)",
            "ChromeColors.hoveredTabFill"
        ] {
            #expect(filesDirectoryRow.contains(expected))
            #expect(changesDirectoryRow.contains(expected))
        }

        #expect(filesDirectoryRow.contains("HoverStateView { isHovered in"))
        #expect(changesDirectoryRow.contains("@State private var isHovered = false"))
        #expect(changesDirectoryRow.contains(".onHover { isHovering in"))
        let sidebar = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
        sidebar.excludes("hoveredDirectoryId", "directory hover state must not invalidate the complete Changes View")
    }

    @Test
    func sectionBulkActionsShowHoverFeedbackAndPointerCursor() throws {
        let view = try SourceContract("Argus/Views/GitSidebar/GitSidebarView+Sections.swift")
        let fileSection = try view.section(
            after: "func fileSection(",
            before: "private func performSectionAction")

        #expect(fileSection.contains("HoverStateView { isHovered in"))
        #expect(fileSection.contains("canPerformActions && isHovered"))
        #expect(fileSection.contains("RoundedRectangle(cornerRadius: 4"))
        #expect(fileSection.contains("ChromeColors.hoveredTabFill"))
        #expect(fileSection.contains(".cursor(canPerformActions ? .pointingHand : .arrow)"))
        #expect(fileSection.contains(".fill(isHovered ? ChromeColors.hoveredTabFill : Color.clear)"))
        #expect(fileSection.contains(".frame(width: 20, height: 20)"))
        #expect(fileSection.contains(".help(\"More \\(section.title.lowercased()) actions\")"))
        #expect(fileSection.contains(".accessibilityLabel(\"More \\(section.title.lowercased()) actions\")"))

        let sidebar = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
        for rootHoverState in [
            "hoveredSectionActionId", "hoveredSectionDisclosureKey", "hoveredSectionMenuKey"
        ] {
            sidebar.excludes(rootHoverState, "Change Section hover state must remain control-local")
        }
    }

    @Test
    func standaloneChangesRefreshUsesIconActionAffordances() throws {
        let sidebar = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
        sidebar.excludes("isHeaderRefreshHovered", "refresh hover state must remain control-local")
        sidebar.excludes("isBranchActionHovered", "branch action hover state must remain control-local")
        sidebar.excludes(
            "var header: some View",
            "standalone Changes header is dead; refresh lives in Right Sidebar")
    }

    @Test
    func untrackedRowsOfferGitignoreActionsForFilesAndDirectories() throws {
        let sidebar = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
        sidebar.containsAll(
            [
                "case addToGitignore",
                "return \"Add to .gitignore\"",
                "private func fileContextActions(for file: GitFileChange)",
                "return fileActions(for: file) + [.addToGitignore]"
            ], "untracked Gitignore context actions"
        )

        let sections = try SourceContract("Argus/Views/GitSidebar/GitSidebarView+Sections.swift")
        sections.containsAll(
            [
                "allowsGitignore: sectionKind == .untracked",
                "Button(\"Add to .gitignore\", action: onAddToGitignore)"
            ], "untracked directory Gitignore actions"
        )

        let rows = try SourceContract("Argus/Views/GitSidebar/GitSidebarView+RowsAndOperations.swift")
        rows.contains(
            "onAddToGitignore: addToGitignore",
            "untracked directory Gitignore callback wiring"
        )
    }

    @Test
    func destructiveAndBulkActionsRequireConfirmation() throws {
        let view = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
        view.containsAll(
            [
                "case discard", "case delete",
                "case .unstaged:", ".discard",
                "case .untracked:", ".delete",
                "await confirmAndPerformFileOperation(action.operation, paths: [file.path], owner: owner)",
                "sectionActions(title: String, count: Int)",
                "Stage All Files", "Unstage All Files", "Discard All Changes", "Delete All Untracked Files",
                "await confirmAndPerformSectionFileOperation(",
                "performSectionAction(",
                "sectionKind: section.kind",
                "pathCount: sectionActionPathCount(action, section: section)"
            ], "destructive and bulk git actions")
        view.excludes("files.map(\\.path)", "bulk actions must not be limited to displayed rows")
        view.excludes("role: .destructive", "Git actions avoid SwiftUI destructive-role rendering")

        let confirmation = try SourceContract("Argus/Views/GitSidebar/GitStatusViewModel+Actions.swift")
        confirmation.containsAll(
            [
                "confirmDestructiveAction(",
                "title: operation.confirmationTitle",
                "confirmTitle: operation.confirmationButtonTitle"
            ], "destructive Git confirmation uses the safe shared presenter")

        let viewModel = try SourceContract("Argus/Views/GitSidebar/GitStatusViewModel.swift")
        viewModel.containsAll(
            [
                "fileOperationConfirmer.confirm(operation: operation, paths: paths)",
                "fileOperationConfirmer.confirm(",
                "confirmationTitle: sectionOperationTitle(operation, sectionKind: sectionKind)",
                "guard activeMutationRequest == nil, activeRefreshRequests[owner] == nil else { return nil }",
                "activeMutationRequest = (requestId, owner)",
                "isMutationInProgress = true",
                "if activeMutationRequest?.owner == owner",
                "pendingRefreshOwners.insert(owner)"
            ], "exact-path confirmation and serialized Git mutations")
    }
}

private struct ExpectedGitFileStatusStyle {
    let status: GitFileStatus
    let icon: String?
    let accessibleName: String
}
