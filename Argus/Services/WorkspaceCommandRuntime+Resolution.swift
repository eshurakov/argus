import Foundation

/// Everything a Workspace Command needs about its target Project, captured on
/// the MainActor before any Git work suspends the caller.
struct WorkspaceCreationContext: Sendable {
    let projectId: UUID
    let projectName: String
    let repositoryPath: String
    /// Branch the new branch starts from and is recorded against, when the
    /// request stacks onto another Workspace.
    let baseBranch: String?
}

extension WorkspaceCommandRuntime {
    /// Reference meaning "the Project or Workspace this terminal belongs to".
    static let contextReference = "."

    func resolveCreationContext(
        _ parameters: WorkspaceCreateParameters
    ) -> Result<WorkspaceCreationContext, WorkspaceCommandRejection> {
        let contextWorkspace = normalized(parameters.contextWorkspaceId)
            .flatMap(UUID.init(uuidString:))
            .flatMap { id in workspaceManager.workspaces.first { $0.id == id } }

        var baseWorkspace: Workspace?
        if let reference = normalized(parameters.base) {
            switch resolveWorkspace(reference: reference, contextWorkspace: contextWorkspace) {
            case .success(let resolved):
                baseWorkspace = resolved
            case .failure(let rejection):
                return .failure(rejection)
            }
        }

        let project: Project
        switch resolveProject(
            reference: normalized(parameters.project),
            baseWorkspace: baseWorkspace,
            contextWorkspace: contextWorkspace,
            contextDirectory: normalized(parameters.contextDirectory)
        ) {
        case .success(let resolved):
            project = resolved
        case .failure(let rejection):
            return .failure(rejection)
        }

        return baseBranch(of: baseWorkspace, in: project).map { baseBranch in
            WorkspaceCreationContext(
                projectId: project.id,
                projectName: project.displayName,
                repositoryPath: project.repositoryPath,
                baseBranch: baseBranch
            )
        }
    }

    private func baseBranch(
        of baseWorkspace: Workspace?,
        in project: Project
    ) -> Result<String?, WorkspaceCommandRejection> {
        guard let baseWorkspace else { return .success(nil) }
        guard project.containsWorkspace(baseWorkspace.id) else {
            return .failure(
                WorkspaceCommandRejection(
                    code: .invalidBaseWorkspace,
                    message: "Workspace '\(baseWorkspace.displayTitle)' does not belong to Project "
                        + "'\(project.displayName)'"
                )
            )
        }
        guard let branch = normalized(baseWorkspace.branchName),
            branch != "(detached)",
            GitReferenceValidation.isValidBranchName(branch)
        else {
            return .failure(
                WorkspaceCommandRejection(
                    code: .invalidBaseWorkspace,
                    message: "Workspace '\(baseWorkspace.displayTitle)' has no branch to stack onto"
                )
            )
        }
        return .success(branch)
    }

    // MARK: - Project references

    private func resolveProject(
        reference: String?,
        baseWorkspace: Workspace?,
        contextWorkspace: Workspace?,
        contextDirectory: String?
    ) -> Result<Project, WorkspaceCommandRejection> {
        if let reference, reference != Self.contextReference {
            return namedProject(matching: reference)
        }
        let implied =
            baseWorkspace.flatMap { workspaceManager.project(for: $0.id) }
            ?? contextWorkspace.flatMap { workspaceManager.project(for: $0.id) }
            ?? contextDirectory.flatMap(project(containingDirectory:))
        guard let implied else {
            return .failure(
                WorkspaceCommandRejection(
                    code: .unknownProject,
                    message: "No Project matches this context. Pass --project with a Project name or ID."
                )
            )
        }
        return named(implied)
    }

    private func namedProject(matching reference: String) -> Result<Project, WorkspaceCommandRejection> {
        if let id = UUID(uuidString: reference) {
            guard let project = workspaceManager.projects.first(where: { $0.id == id }) else {
                return .failure(
                    WorkspaceCommandRejection(
                        code: .unknownProject,
                        message: "No Project has ID \(reference)"
                    )
                )
            }
            return named(project)
        }

        let candidates = workspaceManager.namedProjects.filter { $0.displayName == reference }
        let matches =
            candidates.isEmpty
            ? workspaceManager.namedProjects.filter { $0.displayName.lowercased() == reference.lowercased() }
            : candidates
        if matches.count == 1, let project = matches.first {
            return .success(project)
        }
        if matches.isEmpty {
            return .failure(
                WorkspaceCommandRejection(
                    code: .unknownProject,
                    message: "No Project named '\(reference)'"
                )
            )
        }
        return .failure(
            WorkspaceCommandRejection(
                code: .ambiguousProject,
                message: "Several Projects are named '\(reference)': "
                    + Self.candidateList(matches.map { "\($0.displayName) (\($0.id.uuidString))" })
            )
        )
    }

    private func named(_ project: Project) -> Result<Project, WorkspaceCommandRejection> {
        guard !project.isCatchAll else {
            return .failure(
                WorkspaceCommandRejection(
                    code: .unknownProject,
                    message: "'\(project.displayName)' holds Standalone Workspaces and cannot own a "
                        + "Worktree Workspace. Pass --project with a Named Project."
                )
            )
        }
        return .success(project)
    }

    /// Longest matching Workspace Root, Managed Worktree path, or Project
    /// Repository Root containing `path`, so a nested worktree wins over the
    /// repository it belongs to.
    private func project(containingDirectory path: String) -> Project? {
        let target = Self.canonicalPath(path)
        var best: (length: Int, project: Project)?
        for project in workspaceManager.namedProjects {
            for root in roots(of: project) {
                guard target == root || target.hasPrefix(root + "/") else { continue }
                if best == nil || root.count > (best?.length ?? 0) {
                    best = (root.count, project)
                }
            }
        }
        return best?.project
    }

    private func roots(of project: Project) -> [String] {
        var paths = [project.repositoryPath]
        for workspaceId in project.workspaceIds {
            guard let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId }) else { continue }
            paths.append(workspace.worktreePath ?? workspace.currentDirectory)
        }
        return paths.compactMap(normalized).map(Self.canonicalPath)
    }

    // MARK: - Workspace references

    private func resolveWorkspace(
        reference: String,
        contextWorkspace: Workspace?
    ) -> Result<Workspace, WorkspaceCommandRejection> {
        if reference == Self.contextReference {
            guard let contextWorkspace else {
                return .failure(
                    WorkspaceCommandRejection(
                        code: .unknownWorkspace,
                        message: "'.' needs a Workspace context. Run this from an Argus terminal or "
                            + "pass a Workspace name, branch, or ID."
                    )
                )
            }
            return .success(contextWorkspace)
        }
        if let id = UUID(uuidString: reference) {
            guard let workspace = workspaceManager.workspaces.first(where: { $0.id == id }) else {
                return .failure(
                    WorkspaceCommandRejection(
                        code: .unknownWorkspace,
                        message: "No Workspace has ID \(reference)"
                    )
                )
            }
            return .success(workspace)
        }
        return workspace(matchingName: reference)
    }

    private func workspace(matchingName reference: String) -> Result<Workspace, WorkspaceCommandRejection> {
        let candidateGroups = [
            workspaceManager.workspaces.filter { $0.branchName == reference },
            workspaceManager.workspaces.filter { $0.displayTitle == reference },
            workspaceManager.workspaces.filter { $0.branchName?.lowercased() == reference.lowercased() },
            workspaceManager.workspaces.filter { $0.displayTitle.lowercased() == reference.lowercased() }
        ]
        for matches in candidateGroups {
            if matches.count == 1, let workspace = matches.first {
                return .success(workspace)
            }
            if matches.count > 1 {
                return .failure(
                    WorkspaceCommandRejection(
                        code: .ambiguousWorkspace,
                        message: "Several Workspaces match '\(reference)': "
                            + Self.candidateList(matches.map { Self.candidateLabel($0) })
                    )
                )
            }
        }
        return .failure(
            WorkspaceCommandRejection(
                code: .unknownWorkspace,
                message: "No Workspace matches '\(reference)'"
            )
        )
    }

    private static func candidateLabel(_ workspace: Workspace) -> String {
        let branch = workspace.branchName.map { " on \($0)" } ?? ""
        return "\(workspace.displayTitle)\(branch) (\(workspace.id.uuidString))"
    }

    private static func candidateList(_ candidates: [String]) -> String {
        let shown = candidates.sorted().prefix(5)
        let remainder = candidates.count - shown.count
        let suffix = remainder > 0 ? ", and \(remainder) more" : ""
        return shown.joined(separator: ", ") + suffix
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }
}
