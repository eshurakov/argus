import AppKit
import Foundation
import Testing

@testable import Argus

@Suite
struct GitStatusUIContractTests {
    @Test
    func fileTreeGroupsAndCompactsDirectoryPaths() throws {
        let files = [
            GitFileChange(
                path: "Argus/Services/GitStatusService.swift",
                status: .modified,
                sectionKey: "unstaged"),
            GitFileChange(
                path: "Argus/Views/GitSidebar/GitSidebarView.swift",
                status: .modified,
                sectionKey: "unstaged"),
            GitFileChange(
                path: "Argus/Views/GitSidebar/GitStatusViewModel.swift",
                status: .modified,
                sectionKey: "unstaged"),
            GitFileChange(
                path: "Tests/GitStatusTests/GitStatusViewModelTests.swift",
                status: .modified,
                sectionKey: "unstaged")
        ]

        let nodes = GitFileTree.makeNodes(files: files)

        #expect(nodes.map(\.name) == ["Argus", "Tests / GitStatusTests"])
        #expect(nodes[0].children.map(\.name) == ["Services", "Views / GitSidebar"])
        #expect(nodes[0].children[0].children.map(\.name) == ["GitStatusService.swift"])
        #expect(
            nodes[0].children[1].children.map(\.name) == [
                "GitSidebarView.swift", "GitStatusViewModel.swift"
            ])
        #expect(nodes[1].children.first?.file?.path == "Tests/GitStatusTests/GitStatusViewModelTests.swift")
    }

    @Test
    func collapsedDirectoryHidesOnlyItsDescendants() throws {
        let files = [
            GitFileChange(
                path: "Argus/Services/GitStatusService.swift",
                status: .modified,
                sectionKey: "unstaged"),
            GitFileChange(
                path: "README.md",
                status: .modified,
                sectionKey: "unstaged")
        ]
        let nodes = GitFileTree.makeNodes(files: files)
        let argusId = try #require(nodes.first(where: { $0.name == "Argus / Services" })?.id)

        let rows = GitFileTree.visibleRows(
            nodes: nodes,
            collapsedDirectoryIds: [argusId])

        #expect(rows.map(\.name) == ["Argus / Services", "README.md"])
    }

    @Test
    func workspaceFileTreeShowsDirectoriesAndFiles() throws {
        let entries = [
            WorkspaceFileTreeEntry(path: "Sources/App.swift", isDirectory: false),
            WorkspaceFileTreeEntry(path: "Sources/Views", isDirectory: true),
            WorkspaceFileTreeEntry(path: "Sources/Views/MainView.swift", isDirectory: false),
            WorkspaceFileTreeEntry(path: "Empty", isDirectory: true),
            WorkspaceFileTreeEntry(path: "README.md", isDirectory: false)
        ]

        let nodes = WorkspaceFileTree.makeNodes(entries: entries)

        #expect(nodes.map(\.name) == ["Empty", "Sources", "README.md"])
        #expect(nodes[1].children.map(\.name) == ["Views", "App.swift"])
        #expect(nodes[1].children[0].children.map(\.name) == ["MainView.swift"])

        let rows = WorkspaceFileTree.visibleRows(
            nodes: nodes,
            expandedDirectoryIds: [])

        #expect(rows.map(\.name) == ["Empty", "Sources", "README.md"])
    }

    @Test
    func workspaceFileIconsKeepSemanticSFSymbolNames() {
        let expectedSymbols = [
            "Sources/App.swift": "chevron.left.forwardslash.chevron.right",
            "COMPONENT.TSX": "chevron.left.forwardslash.chevron.right",
            "scripts/build.sh": "terminal",
            "Makefile": "terminal",
            "README.md": "doc.text",
            "LICENSE": "doc.text",
            ".env.local": "gearshape",
            ".gitignore": "gearshape",
            "settings.toml": "gearshape",
            "response.json": "curlybraces",
            "records.csv": "tablecells",
            "hero.webp": "photo",
            "theme.mp3": "waveform",
            "demo.mov": "film",
            "source.tar.gz": "archivebox",
            "Package.swift": "shippingbox",
            "Cargo.lock": "shippingbox",
            "guide.pdf": "doc.richtext",
            "payload.bin": "doc"
        ]

        for (fileName, expectedSymbol) in expectedSymbols {
            let symbol = WorkspaceFileIcon.systemName(for: fileName)
            #expect(symbol == expectedSymbol)
        }
    }

    @Test
    // swiftlint:disable:next function_body_length
    func workspaceFileProviderLoadsRootEntriesBeforeChildren() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-files-panel-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        let nested = sources.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "readme\n".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8)
        try "hidden\n".write(
            to: root.appendingPathComponent(".hidden"),
            atomically: true,
            encoding: .utf8)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        try "app\n".write(
            to: sources.appendingPathComponent("App.swift"),
            atomically: true,
            encoding: .utf8)
        try "nested\n".write(
            to: nested.appendingPathComponent("Nested.swift"),
            atomically: true,
            encoding: .utf8)

        let provider = FileManagerWorkspaceFileTreeProvider()
        let rootState = await provider.loadTree(
            request: WorkspaceFileTreeRequest(
                workspaceId: UUID(),
                rootPath: root.path,
                showHiddenFiles: false
            ))
        guard case .loaded(let rootSnapshot) = rootState else {
            Issue.record("expected root file tree, got \(rootState)")
            return
        }

        #expect(rootSnapshot.nodes.map(\.name) == ["Sources", "README.md"])
        #expect(rootSnapshot.nodes.first(where: { $0.name == "Sources" })?.children.isEmpty == true)

        let sourceState = await provider.loadChildren(
            request: WorkspaceFileTreeRequest(
                workspaceId: UUID(),
                rootPath: rootSnapshot.rootPath,
                showHiddenFiles: false
            ),
            directoryPath: "Sources")
        guard case .loaded(let sourceSnapshot) = sourceState else {
            Issue.record("expected source child file tree, got \(sourceState)")
            return
        }

        #expect(sourceSnapshot.nodes.map(\.name) == ["Nested", "App.swift"])
        #expect(sourceSnapshot.nodes.first(where: { $0.name == "Nested" })?.children.isEmpty == true)
    }

    @Test
    func workspaceFileRequestsIncludeWorkspaceIdentityHiddenVisibilityAndNormalizedRoot() {
        let firstWorkspaceId = UUID()
        let secondWorkspaceId = UUID()
        let first = WorkspaceFileTreeRequest(
            workspaceId: firstWorkspaceId,
            rootPath: "/tmp/argus/../workspace")
        let sameWorkspaceAndRoot = WorkspaceFileTreeRequest(
            workspaceId: firstWorkspaceId,
            rootPath: "/tmp/workspace")
        let differentWorkspace = WorkspaceFileTreeRequest(
            workspaceId: secondWorkspaceId,
            rootPath: "/tmp/workspace")
        let differentHiddenFileVisibility = WorkspaceFileTreeRequest(
            workspaceId: firstWorkspaceId,
            rootPath: "/tmp/workspace",
            showHiddenFiles: false)

        #expect(first == sameWorkspaceAndRoot)
        #expect(first != differentWorkspace)
        #expect(first != differentHiddenFileVisibility)
        #expect(first.rootPath == "/tmp/workspace")
    }

    @Test
    func workspaceFileProviderFiltersHiddenEntriesButAlwaysExcludesGitDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-hidden-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "visible\n".write(to: root.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        try "hidden\n".write(to: root.appendingPathComponent(".hidden.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)

        let provider = FileManagerWorkspaceFileTreeProvider()
        let visibleOnly = await provider.loadTree(
            request: WorkspaceFileTreeRequest(workspaceId: UUID(), rootPath: root.path, showHiddenFiles: false))
        let includingHidden = await provider.loadTree(
            request: WorkspaceFileTreeRequest(workspaceId: UUID(), rootPath: root.path, showHiddenFiles: true))

        guard case .loaded(let visibleSnapshot) = visibleOnly,
            case .loaded(let hiddenSnapshot) = includingHidden
        else {
            Issue.record("expected loaded workspace file trees")
            return
        }
        #expect(visibleSnapshot.nodes.map(\.name) == ["visible.txt"])
        #expect(hiddenSnapshot.nodes.map(\.name) == [".hidden.txt", "visible.txt"])
        #expect(!hiddenSnapshot.nodes.contains(where: { $0.name == ".git" }))
    }
}

@Suite
struct GitChangesUIContractTests {
    @Test
    func changeFileRowsOpenDiffOnDoubleClick() throws {
        let changesView = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
        changesView.containsAll(
            [
                "onDoubleClick: {",
                "perform(.diff, for: file, owner: owner)",
                "TapGesture(count: 2).onEnded {",
                "guard canPerformActions else { return }",
                "onDoubleClick()",
                ".cursor(canPerformActions ? .pointingHand : .arrow)",
                ".help(\"Double-click to view diff\")"
            ],
            "Changes View file rows open a Git Preview Tab on double-click"
        )
    }
}

@Suite
struct WorkspaceFilesUIContractTests {
    @Test
    func rightSidebarHostsFilesAndChangesPanels() throws {
        let rightView = try SourceContract("Argus/Views/GitSidebar/RightSidebarView.swift")
        rightView.containsAll(
            [
                "struct RightSidebarView: View",
                "WorkspaceFilesView(",
                "workspaceId: workspaceManager.selectedWorkspace?.id",
                "rootPath: workspaceManager.selectedWorkspace?.currentDirectory",
                "WorkspaceFileTreeRequest(",
                "GitSidebarView(showsHeader: false)",
                "private var changesCount: Int?",
                "summary.totalFileCount",
                "Refresh files", "Refresh changes"
            ], "right sidebar panel tabs")
        rightView.excludes("Text(\"Git Status\")", "git status panel is renamed to changes")

        try SourceContract("Argus/Settings/AppSettings.swift").containsAll(
            ["enum RightSidebarView", "case files", "case changes", "\"Files\"", "\"Changes\""],
            "right sidebar view choices"
        )

        let changesView = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
        changesView.contains("Text(\"Changes\")", "git status header is renamed to changes")
        changesView.excludes("Text(\"Git Status\")", "git status header no longer uses old title")

        try SourceContract("Argus/Views/MainWindowView.swift").containsAll(
            [
                "RightSidebarView()",
                "// Right side panel"
            ], "right sidebar host")
    }

    @Test
    func sidebarsUseOpaqueBlackShellBackgrounds() throws {
        try SourceContract("Argus/Views/ChromeColors.swift").containsAll(
            ["static var shellBackground: Color", "static var shellBackgroundNSColor: NSColor", ".black"],
            "black shell color"
        )
        for path in ["Argus/App/AppDelegate.swift", "Argus/Ghostty/GhosttyApp.swift"] {
            try SourceContract(path).contains(
                "window.backgroundColor = ChromeColors.shellBackgroundNSColor",
                "native window backing must preserve the black shell"
            )
        }

        for path in [
            "Argus/Views/Sidebar/SidebarView+Header.swift",
            "Argus/Views/GitSidebar/RightSidebarView.swift"
        ] {
            let sidebar = try SourceContract(path)
            sidebar.contains(
                ".background(ChromeColors.shellBackground)",
                "sidebars must use the opaque black shell background"
            )
            sidebar.excludes("VisualEffectView(", "sidebars must not use translucent material")
            sidebar.excludes(".behindWindow", "sidebars must not sample content behind the window")
        }
    }

    @Test
    func rightSidebarRefreshUsesEnabledIconActionAffordances() throws {
        let rightView = try SourceContract("Argus/Views/GitSidebar/RightSidebarView.swift")
        let header = try rightView.section(
            after: "private var header: some View",
            before: "private func tabButton")

        for expected in [
            "HoverStateView { isHovered in",
            ".frame(width: 20, height: 20)",
            "canRefresh && isHovered ? ChromeColors.hoveredTabFill : Color.clear",
            ".contentShape(Rectangle())",
            ".disabled(!canRefresh)",
            ".cursor(canRefresh ? .pointingHand : .arrow)",
            ".help(selectedPanel == .files ? \"Refresh files\" : \"Refresh changes\")",
            ".accessibilityLabel(selectedPanel == .files ? \"Refresh files\" : \"Refresh changes\")"
        ] {
            #expect(header.contains(expected))
        }
        rightView.excludes("isRefreshHovered", "Right Sidebar refresh hover state must remain control-local")
    }

    @Test
    func filesPanelReadsWorkspaceDirectoryWithBoundedTraversal() throws {
        try SourceContract("Argus/Views/GitSidebar/RightSidebarView.swift").containsAll(
            [
                "FileManagerWorkspaceFileTreeProvider",
                "loadChildren(",
                "WorkspaceFileTreeSnapshot.displayedEntryLimit",
                "contentsOfDirectory",
                ".skipsPackageDescendants",
                "url.lastPathComponent == \".git\"",
                "showHiddenFiles",
                ".id(request)",
                "snapshot.request == request",
                "expandedDirectoryIds",
                "WorkspaceFileTree.visibleRows("
            ], "files panel traversal")
    }

    @Test
    func filesPanelRowsSupportSelectionOpenAndContextActions() throws {
        let rightView = try SourceContract("Argus/Views/GitSidebar/RightSidebarView.swift")
        assertWorkspaceFileRows(in: rightView)
        assertWorkspaceFileOperations(in: rightView)
        let confirmation = try SourceContract(
            "Argus/Views/GitSidebar/WorkspaceItemDeletionConfirmation.swift"
        )
        confirmation.containsAll(
            ["Button(\"Delete\", action: onConfirm)", ".foregroundStyle(.red)"],
            "in-view Workspace Item deletion confirmation"
        )
        confirmation.excludes("NSAlert", "Workspace Item deletion must not open an AppKit alert")
        confirmation.excludes("runModal()", "Workspace Item deletion must not start a modal run loop")
        try assertFilePanelIntegration()
    }

    @Test
    func deletingWorkspaceItemsPreservesExpandedDirectories() throws {
        let rows = try SourceContract(
            "Argus/Views/GitSidebar/RightSidebarView+WorkspaceFilesRows.swift"
        )
        let deleteBody = try rows.section(
            after: "func deleteWorkspaceItem(",
            before: "func renameWorkspaceItem("
        )
        #expect(
            !deleteBody.contains("expandedDirectoryIds = []"),
            "deleting a Workspace Item must not collapse the Workspace File Tree"
        )
    }

    private func assertWorkspaceFileRows(in rightView: SourceContract) {
        rightView.containsAll(
            [
                "@State private var selectedItemId: String?",
                "private func workspaceDirectoryRow(",
                "let isSelected = selectedItemId == directory.id",
                "HoverStateView { isHovered in",
                "LazyVStack(spacing: 0)",
                "selectDirectory(directory)",
                "toggleWorkspaceDirectory(directory, rootPath: rootPath)",
                "openWorkspaceDirectory(directory, rootPath: rootPath)",
                "copyWorkspaceItem(directory, rootPath: rootPath)",
                "guard let initiatingRequest = request else { return }",
                "initiatingRequest: initiatingRequest",
                "private func workspaceFileRow(",
                "selectFile(file)",
                "let isSelected = selectedItemId == file.id",
                "WorkspaceFileIcon.systemName(for: file.name)",
                "isHovered ? ChromeColors.hoveredTabFill : Color.clear",
                ".simultaneousGesture(",
                "TapGesture(count: 2).onEnded {",
                "openWorkspaceFile(file, rootPath: rootPath)",
                ".contextMenu {",
                "Button(\"Open Folder\")",
                "Button(\"Copy Folder\")",
                "Button(\"Copy Relative Path\")",
                "Button(\"Delete Folder\")",
                "Button(\"Rename Folder\")",
                "Button(\"Open File\")",
                "Button(\"Copy File\")",
                "Button(\"Delete File\")",
                "Button(\"Rename File\")",
                "requestWorkspaceItemDeletion(",
                "WorkspaceItemDeletionConfirmation(",
                "copyWorkspaceItem(file, rootPath: rootPath)",
                "copyWorkspaceItemRelativePath(file)",
                "$0.id == initiatingRequest.workspaceId",
                "sourceWorkspace.openFilePanel("
            ], "files panel row interactions")
        rightView.excludes("hoveredItemId", "Files View row hover state must remain row-local")
    }

    private func assertWorkspaceFileOperations(in rightView: SourceContract) {
        rightView.containsAll(
            [
                "WorkspaceFileOperating",
                "FileManagerWorkspaceFileOperator",
                "WorkspaceRelativePathCopying",
                "PasteboardWorkspaceRelativePathClipboard",
                "NSPasteboard.general",
                "promptRename(currentName: String)",
                "func deleteFile(request: WorkspaceFileTreeRequest, path: String)",
                "func renameFileWithPrompt(request: WorkspaceFileTreeRequest, path: String)",
                "activeRequest == request",
                "viewModel.isCurrent(initiatingRequest)",
                "resolvedItemURL(rootPath: String, path: String)",
                "removeItem(at:",
                "moveItem(at:"
            ], "files panel file operations")
    }

    private func assertFilePanelIntegration() throws {
        try SourceContract("Argus/Models/Panel.swift").containsAll(
            [
                "case file",
                "final class FilePanel",
                "let panelType: PanelType = .file"
            ], "file panel model")
        try SourceContract("Argus/Models/Workspace.swift").containsAll(
            [
                "func openFilePanel(rootPath: String, relativePath: String) -> FilePanel",
                "selectPanel(existing.id)",
                "func updateOpenFilePanel(rootPath: String, oldPath: String, newPath: String)"
            ], "workspace file tab helpers")
        try SourceContract("Argus/Views/Content/ContentAreaView.swift").containsAll(
            [
                "case .file:",
                "FilePanelContentView(",
                "Data(contentsOf: url)",
                "data.contains(0)",
                "FileSyntaxHighlighter.highlightedText",
                "GeometryReader { proxy in",
                "_lineWrapEnabled = State(initialValue: initialPresentation.lineWrapEnabled)",
                "FilePanelPreparedContent",
                "sourceContent(preparedContent.sourceLines)",
                "MarkdownRenderedView(blocks: preparedContent.markdownBlocks, documentTextSize: documentTextSize)",
                "Text(String(number))",
                "ScrollView([.horizontal, .vertical])",
                ".fixedSize(horizontal: false, vertical: true)",
                ".fixedSize(horizontal: true, vertical: true)",
                "minHeight: viewportSize.height",
                "alignment: .topLeading"
            ], "file tab content rendering")
    }

}  // swiftlint:disable:this file_length
