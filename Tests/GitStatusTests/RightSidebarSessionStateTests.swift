import Foundation
import Testing

@testable import Argus

@Suite
struct RightSidebarSessionStateTests {
    @Test @MainActor
    func filesExpansionIsIndependentPerWorkspaceAndRoot() {
        let state = RightSidebarSessionState()
        let first = UUID()
        let second = UUID()

        state.expandDirectory("directory:Sources", workspaceId: first, rootPath: "/repo-a")
        state.expandDirectory("directory:Docs", workspaceId: first, rootPath: "/repo-b")
        state.expandDirectory("directory:Tests", workspaceId: second, rootPath: "/repo-a")

        #expect(
            state.expandedDirectoryIds(workspaceId: first, rootPath: "/repo-a")
                == ["directory:Sources"]
        )
        #expect(
            state.expandedDirectoryIds(workspaceId: first, rootPath: "/repo-b")
                == ["directory:Docs"]
        )
        #expect(
            state.expandedDirectoryIds(workspaceId: second, rootPath: "/repo-a")
                == ["directory:Tests"]
        )
    }

    @Test @MainActor
    func changesExpansionIsIndependentPerWorkspace() {
        let state = RightSidebarSessionState()
        let first = UUID()
        let second = UUID()

        state.setSectionExpanded(.staged, isExpanded: false, workspaceId: first)
        state.toggleCollapsedDirectory("staged:directory:Sources", workspaceId: first)

        #expect(!state.expandedSectionKinds(for: first).contains(.staged))
        #expect(state.expandedSectionKinds(for: second).contains(.staged))
        #expect(state.collapsedDirectoryIds(for: first) == ["staged:directory:Sources"])
        #expect(state.collapsedDirectoryIds(for: second).isEmpty)
    }

    @Test @MainActor
    func retainWorkspacesDropsClosedWorkspaceState() {
        let state = RightSidebarSessionState()
        let kept = UUID()
        let closed = UUID()

        state.expandDirectory("directory:Sources", workspaceId: kept, rootPath: "/repo")
        state.expandDirectory("directory:Docs", workspaceId: closed, rootPath: "/repo")
        state.setSectionExpanded(.unstaged, isExpanded: false, workspaceId: closed)
        state.toggleCollapsedDirectory("unstaged:directory:Docs", workspaceId: closed)

        state.retainWorkspaces([kept])

        #expect(
            state.expandedDirectoryIds(workspaceId: kept, rootPath: "/repo")
                == ["directory:Sources"]
        )
        #expect(state.expandedDirectoryIds(workspaceId: closed, rootPath: "/repo").isEmpty)
        #expect(state.expandedSectionKinds(for: closed) == RightSidebarSessionState.defaultExpandedSectionKinds)
        #expect(state.collapsedDirectoryIds(for: closed).isEmpty)
    }

    @Test
    func expandedDirectoryIdsRestoreParentsBeforeChildren() {
        let paths = WorkspaceFileTree.directoryPaths(
            fromExpandedIds: [
                "directory:Sources/Nested",
                "file:README.md",
                "directory:Sources",
                "directory:"
            ]
        )

        #expect(paths == ["Sources", "Sources/Nested"])
    }
}
