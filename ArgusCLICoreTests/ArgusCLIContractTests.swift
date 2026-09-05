import ArgumentParser
import ArgusIPC
import Foundation
import Testing

@testable import ArgusCLICore

@Suite
struct ArgusCLIContractTests {
    @Test
    func refusedRequestsAndUnreachableArgusUseDistinctExitCodes() {
        let rejected = ArgusCLIError.rejected(code: "unknown_project", message: "No Project named 'nope'")
        let unavailable = ArgusCLIError.applicationUnavailable("Argus is not running")

        #expect(rejected.exitCode == ExitCode(1))
        #expect(rejected.description == "No Project named 'nope' [unknown_project]")
        #expect(unavailable.exitCode == ExitCode(3))
        #expect(unavailable.description == "Argus is not running. Start Argus and try again.")
        #expect(ArgusCLIError.transport("timed out").exitCode == ExitCode(3))
        #expect(ArgusCLIError.malformedResponse("unreadable").exitCode == ExitCode(1))
    }

    @Test
    func theSocketPathPrefersTheInjectedEnvironment() {
        #expect(
            ArgusSocketClient.resolvedPath(environment: ["ARGUS_SOCKET_PATH": "/tmp/injected.sock"])
                == "/tmp/injected.sock"
        )
        let fallback = ArgusSocketClient.resolvedPath(environment: [:])
        #expect(fallback.hasSuffix("/.argus/argus.sock"))
        #expect(!fallback.hasPrefix("~"))
    }

    @Test
    func createRequestsEncodeTheContractTheApplicationDecodes() throws {
        let request = ArgusSocketRequest(
            id: "create-1",
            method: .workspaceCreate,
            params: WorkspaceCreateParameters(
                project: ".", base: "feature/parent", branch: "feature/child",
                name: "Child", contextWorkspaceId: "workspace-id", contextDirectory: "/tmp"
            )
        )
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(
            ArgusSocketRequest<WorkspaceCreateParameters>.self, from: encoded)

        #expect(decoded.version == ArgusSocketProtocol.version)
        #expect(decoded.method == ArgusSocketMethod.workspaceCreate.rawValue)
        #expect(decoded.id == "create-1")
        #expect(decoded.params?.project == ".")
        #expect(decoded.params?.base == "feature/parent")
        #expect(decoded.params?.contextWorkspaceId == "workspace-id")
    }

    @Test
    func createSummaryReportsAnUnrecordedBase() {
        let workspace = WorkspaceListEntry(
            id: "child", number: 2, title: "feature/child", kind: .worktree, branch: "feature/child",
            root: "/tmp/child", worktreePath: "/tmp/child", isSelected: false, tabCount: 1
        )
        let recorded = WorkspaceCreateResult(
            workspace: workspace, projectId: "project", projectName: "argus", branch: "feature/child",
            baseBranch: "feature/parent", recordedBaseBranch: true
        )
        let unrecorded = WorkspaceCreateResult(
            workspace: workspace, projectId: "project", projectName: "argus", branch: "feature/child",
            baseBranch: "feature/parent", recordedBaseBranch: false
        )

        #expect(
            WorkspaceCreateCommand.summary(for: recorded) == [
                "Created Workspace \"feature/child\" in argus",
                "  branch  feature/child",
                "  base    feature/parent (recorded as the base branch)",
                "  path    /tmp/child"
            ])
        let warning = try? #require(WorkspaceCreateCommand.summary(for: unrecorded).dropFirst(2).first)
        #expect(warning?.contains("not recorded") == true)
    }
}
