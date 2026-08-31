import Foundation
import Testing

@testable import Argus

@Suite
struct SessionReconciliationTests {
    @Test
    func restoreReconciliationRepairsMembershipAndIsIdempotent() throws {
        let ids = ReconciliationIDs()
        let reconciled = makeSnapshot(ids: ids).reconciledForRestore()

        assertReconciliation(reconciled, ids: ids)
    }

    @Test
    @MainActor
    func restoreRejectsDuplicateIdentitiesWithoutReconcilingThem() throws {
        let workspaceId = UUID()
        let projectId = UUID()
        let workspace = self.workspace(
            id: workspaceId,
            projectId: projectId,
            branchName: "main",
            type: .mainCheckout,
            directory: "/repo"
        )
        let project = ProjectSnapshot(
            id: projectId,
            repositoryPath: "/repo",
            isCatchAll: false,
            displayName: "Repo",
            mainBranch: "main",
            workspaceIds: [workspaceId],
            isExpanded: true,
            color: nil
        )
        let malformed = ArgusSessionSnapshot(
            selectedWorkspaceId: workspaceId,
            projects: [project, project],
            workspaces: [workspace, workspace]
        )
        let serialized = try JSONEncoder().encode(malformed)
        let decoded = try JSONDecoder().decode(ArgusSessionSnapshot.self, from: serialized)
        let defaults = try #require(UserDefaults(suiteName: "ArgusDuplicateRestore-\(UUID().uuidString)"))
        let manager = WorkspaceManager(
            settings: AppSettings(defaults: defaults),
            environment: ["ARGUS_UNDER_TEST": "1"]
        )

        #expect(!decoded.isValidForRestore(maxWorkspaces: WorkspaceManager.maxWorkspaces))
        #expect(!manager.restoreSession(from: decoded))
    }

    @Test
    func decoderBoundsLegacyPanelMetadataWithoutDiscardingTheWorkspace() throws {
        let directories = (0..<129).map { "\"/tmp/\($0)\"" }.joined(separator: ",")
        let titles = (0..<129).map { "\"Tab \($0)\"" }.joined(separator: ",")
        let json = """
            {
              "id":"11111111-1111-1111-1111-111111111111",
              "workspaceType":"external",
              "title":"Legacy",
              "currentDirectory":"/tmp",
              "panelCount":129,
              "terminalDirectories":[\(directories)],
              "terminalCustomTitles":[\(titles)]
            }
            """

        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8))

        #expect(decoded.panelCount == WorkspaceSnapshot.maximumTerminalPanels)
        #expect(decoded.terminalDirectories.count == WorkspaceSnapshot.maximumTerminalPanels)
        #expect(decoded.terminalCustomTitles.count == WorkspaceSnapshot.maximumTerminalPanels)
        #expect(decoded.terminalDirectories.last == "/tmp/127")
    }

    @Test
    @MainActor
    func restoreValidationAllowsTheMaximumNamedProjectsPlusCatchAll() {
        let workspace = workspace(
            id: UUID(),
            projectId: nil,
            branchName: nil,
            type: .external,
            directory: "/tmp"
        )
        let projects = (0...WorkspaceManager.maxWorkspaces).map { index in
            ProjectSnapshot(
                id: UUID(),
                repositoryPath: "/tmp/repo-\(index)",
                isCatchAll: false,
                displayName: "Repo \(index)",
                mainBranch: "main",
                workspaceIds: [],
                isExpanded: true,
                color: nil
            )
        }
        let snapshot = ArgusSessionSnapshot(
            selectedWorkspaceId: workspace.id,
            projects: projects,
            workspaces: [workspace]
        )

        #expect(snapshot.isValidForRestore(maxWorkspaces: WorkspaceManager.maxWorkspaces))

        let excessive = ArgusSessionSnapshot(
            selectedWorkspaceId: workspace.id,
            projects: projects + [
                ProjectSnapshot(
                    id: UUID(),
                    repositoryPath: "/tmp/excessive-repo",
                    isCatchAll: false,
                    displayName: "Excessive Repo",
                    mainBranch: "main",
                    workspaceIds: [],
                    isExpanded: true,
                    color: nil
                )
            ],
            workspaces: [workspace]
        )
        #expect(!excessive.isValidForRestore(maxWorkspaces: WorkspaceManager.maxWorkspaces))
    }

    private func makeSnapshot(ids: ReconciliationIDs) -> ArgusSessionSnapshot {
        ArgusSessionSnapshot(
            selectedWorkspaceId: ids.invalidProjectWorkspace,
            projects: makeProjects(ids: ids),
            workspaces: makeWorkspaces(ids: ids)
        )
    }

    private func makeProjects(ids: ReconciliationIDs) -> [ProjectSnapshot] {
        let project = ProjectSnapshot(
            id: ids.project,
            repositoryPath: "/repo",
            isCatchAll: false,
            displayName: "Repo",
            mainBranch: "main",
            workspaceIds: [ids.staleWorkspace, ids.validWorkspace],
            isExpanded: true,
            color: nil
        )
        let catchAll = ProjectSnapshot(
            id: ids.catchAll,
            repositoryPath: "",
            isCatchAll: true,
            displayName: "Workspaces",
            mainBranch: "",
            workspaceIds: [],
            isExpanded: true,
            color: nil
        )
        let duplicateCatchAll = ProjectSnapshot(
            id: ids.duplicateCatchAll,
            repositoryPath: "",
            isCatchAll: true,
            displayName: "Old Workspaces",
            mainBranch: "",
            workspaceIds: [ids.staleWorkspace],
            isExpanded: false,
            color: nil
        )
        return [project, catchAll, duplicateCatchAll]
    }

    private func makeWorkspaces(ids: ReconciliationIDs) -> [WorkspaceSnapshot] {
        let validWorkspace = workspace(
            id: ids.validWorkspace,
            projectId: ids.project,
            branchName: "main",
            type: .mainCheckout,
            directory: "/repo"
        )
        let invalidProjectWorkspace = workspace(
            id: ids.invalidProjectWorkspace,
            projectId: ids.invalidProject,
            branchName: nil,
            type: .external,
            directory: "/tmp/invalid"
        )
        let missingProjectWorkspace = workspace(
            id: ids.missingProjectWorkspace,
            projectId: nil,
            branchName: nil,
            type: .external,
            directory: "/tmp/missing"
        )
        return [validWorkspace, invalidProjectWorkspace, missingProjectWorkspace]
    }

    private func assertReconciliation(
        _ reconciled: ArgusSessionSnapshot,
        ids: ReconciliationIDs
    ) {
        let catchAllProjects = reconciled.projects.filter(\.isCatchAll)
        assertEqual(catchAllProjects.count, 1, "restore has exactly one catch-all")
        assertEqual(catchAllProjects[0].id, ids.catchAll, "first catch-all identity is preserved")

        let restoredProject = reconciled.projects.first { $0.id == ids.project }!
        assertEqual(
            restoredProject.workspaceIds, [ids.validWorkspace],
            "stale refs are removed and valid order is preserved")

        let restoredCatchAll = catchAllProjects[0]
        assertEqual(
            restoredCatchAll.workspaceIds,
            [ids.invalidProjectWorkspace, ids.missingProjectWorkspace],
            "invalid or missing workspace project IDs are attached to catch-all"
        )

        assertEqual(
            reconciled.workspaces.first { $0.id == ids.invalidProjectWorkspace }?.projectId,
            ids.catchAll,
            "invalid project ID is rewritten to catch-all"
        )
        assertEqual(
            reconciled.workspaces.first { $0.id == ids.missingProjectWorkspace }?.projectId,
            ids.catchAll,
            "missing project ID is rewritten to catch-all"
        )

        let rereconciled = reconciled.reconciledForRestore()
        assertEqual(
            rereconciled.projects.map(\.workspaceIds), reconciled.projects.map(\.workspaceIds),
            "reconciliation is idempotent for project membership")
        assertEqual(
            rereconciled.workspaces.map(\.projectId), reconciled.workspaces.map(\.projectId),
            "reconciliation is idempotent for workspace membership")
    }

    private func workspace(
        id: UUID,
        projectId: UUID?,
        branchName: String?,
        type: WorkspaceType,
        directory: String
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            id: id,
            projectId: projectId,
            branchName: branchName,
            workspaceType: type,
            worktreePath: type == .worktree ? directory : nil,
            title: branchName ?? "Terminal",
            customTitle: nil,
            currentDirectory: directory,
            panelCount: 1
        )
    }

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }
}

private struct ReconciliationIDs {
    let project = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let catchAll = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    let duplicateCatchAll = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
    let invalidProject = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
    let validWorkspace = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let invalidProjectWorkspace = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let missingProjectWorkspace = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let staleWorkspace = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
}
