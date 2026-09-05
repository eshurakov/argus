import ArgusIPC
import Testing

@testable import ArgusCLICore

@Suite
struct WorkspaceListRendererTests {
    @Test
    func stackGroupsRenderAsParentBeforeDependentTrees() {
        let renderer = WorkspaceListRenderer(homeDirectory: "/Users/tester")

        #expect(
            renderer.lines(for: Self.result) == [
                "argus  main  ~/Projects/argus",
                "      stack  base main",
                "  1   feature/parent  [worktree]",
                "        \u{21B3} feature/gap  (branch reference)",
                "  2 *     \u{21B3} Child work  feature/child  [worktree]",
                "  3   scratch  [worktree]",
                "Workspaces",
                "  4   notes  [standalone]  ~/notes"
            ])
    }

    @Test
    func diagnosticsAndEmptyProjectsStayVisible() {
        let renderer = WorkspaceListRenderer(homeDirectory: "/Users/tester")
        let result = WorkspaceListResult(
            selectedWorkspaceId: nil,
            projects: [
                ProjectListEntry(
                    id: "project", name: "argus", isCatchAll: false, repositoryPath: nil,
                    mainBranch: nil, stackDiagnostic: "Conflicting recorded parents for 'x'", items: []
                )
            ]
        )

        #expect(
            renderer.lines(for: result) == [
                "argus",
                "      ! Conflicting recorded parents for 'x'",
                "      (no Workspaces)"
            ])
    }

    @Test
    func aStackWithNoRecordedBaseSaysSo() {
        let renderer = WorkspaceListRenderer(homeDirectory: "/Users/tester")
        let group = StackGroupListEntry(
            id: "stack",
            baseBranch: nil,
            rows: [
                StackRowListEntry(
                    branch: "feature/parent", parentBranch: nil, lane: 0,
                    issue: "Recorded parent cycle", workspace: Self.parent
                )
            ]
        )
        let result = WorkspaceListResult(
            selectedWorkspaceId: nil,
            projects: [
                ProjectListEntry(
                    id: "project", name: "argus", isCatchAll: false, repositoryPath: nil,
                    mainBranch: nil, stackDiagnostic: nil, items: [.stack(group)]
                )
            ]
        )

        #expect(
            renderer.lines(for: result) == [
                "argus",
                "      stack  base not recorded",
                "  1   feature/parent  [worktree]",
                "      ! Recorded parent cycle"
            ])
    }

    private static let parent = WorkspaceListEntry(
        id: "parent", number: 1, title: "feature/parent", kind: .worktree, branch: "feature/parent",
        root: "/tmp/parent", worktreePath: "/tmp/parent", isSelected: false, tabCount: 1
    )

    private static let child = WorkspaceListEntry(
        id: "child", number: 2, title: "Child work", kind: .worktree, branch: "feature/child",
        root: "/tmp/child", worktreePath: "/tmp/child", isSelected: true, tabCount: 2
    )

    private static let scratch = WorkspaceListEntry(
        id: "scratch", number: 3, title: "scratch", kind: .worktree, branch: "scratch",
        root: "/tmp/scratch", worktreePath: "/tmp/scratch", isSelected: false, tabCount: 1
    )

    private static let notes = WorkspaceListEntry(
        id: "notes", number: 4, title: "notes", kind: .standalone, branch: nil,
        root: "/Users/tester/notes", worktreePath: nil, isSelected: false, tabCount: 1
    )

    private static let result = WorkspaceListResult(
        selectedWorkspaceId: "child",
        projects: [
            ProjectListEntry(
                id: "project",
                name: "argus",
                isCatchAll: false,
                repositoryPath: "/Users/tester/Projects/argus",
                mainBranch: "main",
                stackDiagnostic: nil,
                items: [
                    .stack(
                        StackGroupListEntry(
                            id: "stack",
                            baseBranch: "main",
                            rows: [
                                StackRowListEntry(
                                    branch: "feature/parent", parentBranch: "main", lane: 0,
                                    issue: nil, workspace: parent
                                ),
                                StackRowListEntry(
                                    branch: "feature/gap", parentBranch: "feature/parent", lane: 0,
                                    issue: nil, workspace: nil
                                ),
                                StackRowListEntry(
                                    branch: "feature/child", parentBranch: "feature/gap", lane: 0,
                                    issue: nil, workspace: child
                                )
                            ]
                        )),
                    .workspace(scratch)
                ]
            ),
            ProjectListEntry(
                id: "catch-all",
                name: "Workspaces",
                isCatchAll: true,
                repositoryPath: nil,
                mainBranch: nil,
                stackDiagnostic: nil,
                items: [.workspace(notes)]
            )
        ]
    )
}
