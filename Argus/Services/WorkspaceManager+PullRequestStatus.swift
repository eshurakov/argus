import AppKit
import Foundation

extension WorkspaceManager {
    var pullRequestStatusTargets: [WorkspacePullRequestTarget] {
        workspaces.compactMap { workspace in
            guard workspace.workspaceType == .worktree,
                let projectId = workspace.projectId,
                let project = projects.first(where: { $0.id == projectId && !$0.isCatchAll }),
                project.workspaceIds.contains(workspace.id),
                let path = workspace.worktreePath, !path.isEmpty
            else { return nil }
            return WorkspacePullRequestTarget(
                workspaceID: workspace.id,
                projectID: project.id,
                repositoryPath: project.repositoryPath,
                worktreePath: path
            )
        }
    }

    @discardableResult
    func openPullRequest(
        _ status: PullRequestStatus,
        in workspaceId: UUID,
        openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Bool {
        guard pullRequestStatusTargets.contains(where: { $0.workspaceID == workspaceId }),
            RepositoryIdentity.github(fromPullRequestURL: status.url) == status.identity.repository,
            let input = try? PullRequestInput.parse(status.url.absoluteString),
            input.number == status.identity.number
        else { return false }

        return openURL(status.url)
    }
}
