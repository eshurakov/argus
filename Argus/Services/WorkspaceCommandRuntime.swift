import Foundation

/// A Companion CLI Workspace Command accepted by the Socket Server.
enum WorkspaceCommandRequest: Sendable {
    case list
    case create(WorkspaceCreateParameters)
}

/// Result of one Workspace Command.
enum WorkspaceCommandOutcome: Sendable {
    case list(WorkspaceListResult)
    case created(WorkspaceCreateResult)
    case rejected(code: ArgusSocketErrorCode, message: String)
}

/// A refused Workspace Command, carried by internal resolution steps before
/// it becomes an outcome.
struct WorkspaceCommandRejection: Error, Sendable {
    let code: ArgusSocketErrorCode
    let message: String
}

/// MainActor boundary between Socket input and Workspace organization state.
///
/// The Companion CLI sends unresolved references. This runtime owns every
/// identity decision — which Project, which base Workspace, which branch name
/// — and reuses the same Workspace creation path as the in-app New Workspace
/// sheet so revalidation and persistence behavior cannot drift.
@MainActor
final class WorkspaceCommandRuntime {
    let workspaceManager: WorkspaceManager

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    func receive(_ request: WorkspaceCommandRequest) async -> WorkspaceCommandOutcome {
        switch request {
        case .list:
            return .list(listResult())
        case .create(let parameters):
            return await create(parameters)
        }
    }

    private func create(_ parameters: WorkspaceCreateParameters) async -> WorkspaceCommandOutcome {
        let context: WorkspaceCreationContext
        switch resolveCreationContext(parameters) {
        case .success(let resolved):
            context = resolved
        case .failure(let rejection):
            return .rejected(code: rejection.code, message: rejection.message)
        }

        guard workspaceManager.workspaces.count < WorkspaceManager.maxWorkspaces else {
            return .rejected(
                code: .workspaceLimitReached,
                message: "Argus already holds \(WorkspaceManager.maxWorkspaces) Workspaces"
            )
        }

        let branchName: String
        switch await resolveNewBranchName(parameters.branch, repositoryPath: context.repositoryPath) {
        case .success(let resolved):
            branchName = resolved
        case .failure(let rejection):
            return .rejected(code: rejection.code, message: rejection.message)
        }

        if let rejection = await validateBaseBranchExists(context) {
            return .rejected(code: rejection.code, message: rejection.message)
        }

        return await attach(context, branchName: branchName, customTitle: normalized(parameters.name))
    }

    private func attach(
        _ context: WorkspaceCreationContext,
        branchName: String,
        customTitle: String?
    ) async -> WorkspaceCommandOutcome {
        let workspace = await workspaceManager.addWorkspaceToProject(
            context.projectId,
            branchName: branchName,
            createNewBranch: true,
            customTitle: customTitle,
            startPoint: context.baseBranch,
            selectsNewWorkspace: false
        )
        guard let workspace else {
            let rejection = creationRejection()
            return .rejected(code: rejection.code, message: rejection.message)
        }

        var recordedBaseBranch = false
        if let baseBranch = context.baseBranch {
            recordedBaseBranch = await recordBaseBranch(
                baseBranch,
                forBranch: branchName,
                in: context.projectId
            )
        }

        return .created(
            WorkspaceCreateResult(
                workspace: entry(for: workspace, numbers: workspaceNumbers()),
                projectId: context.projectId.uuidString,
                projectName: currentProjectName(context),
                branch: branchName,
                baseBranch: context.baseBranch,
                recordedBaseBranch: recordedBaseBranch
            )
        )
    }

    /// Records the parent so the new Workspace joins its Stack Group.
    ///
    /// The Managed Worktree already exists at this point, so a failed record
    /// is reported rather than treated as a failed creation.
    private func recordBaseBranch(
        _ baseBranch: String,
        forBranch branch: String,
        in projectId: UUID
    ) async -> Bool {
        guard let project = workspaceManager.projects.first(where: { $0.id == projectId }),
            !project.isCatchAll
        else { return false }
        do {
            try await workspaceManager.worktreeService.recordBaseBranch(
                baseBranch,
                forBranch: branch,
                repositoryPath: project.repositoryPath
            )
        } catch {
            print("Failed to record the base branch: \(error.localizedDescription)")
            return false
        }
        workspaceManager.refreshWorkspaceStacks(in: projectId)
        return true
    }

    private func validateBaseBranchExists(
        _ context: WorkspaceCreationContext
    ) async -> WorkspaceCommandRejection? {
        guard let baseBranch = context.baseBranch else { return nil }
        let exists = await workspaceManager.worktreeService.localBranchExists(
            baseBranch,
            repositoryPath: context.repositoryPath
        )
        guard !exists else { return nil }
        return WorkspaceCommandRejection(
            code: .invalidBaseWorkspace,
            message: "Base branch '\(baseBranch)' does not exist in this repository"
        )
    }

    private func resolveNewBranchName(
        _ requested: String?,
        repositoryPath: String
    ) async -> Result<String, WorkspaceCommandRejection> {
        if let requested = normalized(requested) {
            guard GitReferenceValidation.isValidBranchName(requested) else {
                return .failure(
                    WorkspaceCommandRejection(
                        code: .invalidParameters,
                        message: "'\(requested)' is not a valid branch name"
                    )
                )
            }
            return .success(requested)
        }
        let prefix = workspaceManager.settings.newBranchPrefix
        let candidate = RandomBranchNameGenerator.generate(prefix: prefix)
        let suggested = try? await workspaceManager.worktreeService.suggestAvailableBranchName(
            preferring: candidate,
            prefix: prefix,
            repositoryPath: repositoryPath
        )
        return .success(suggested ?? candidate)
    }

    private func creationRejection() -> WorkspaceCommandRejection {
        switch workspaceManager.lastWorkspaceCreationError {
        case .branchAlreadyExists(let branch):
            WorkspaceCommandRejection(
                code: .branchAlreadyExists,
                message: "Branch '\(branch)' already exists"
            )
        case .some(let error):
            WorkspaceCommandRejection(
                code: .workspaceCreationFailed,
                message: error.localizedDescription
            )
        case nil:
            WorkspaceCommandRejection(
                code: .workspaceCreationFailed,
                message: "Could not create the Workspace"
            )
        }
    }

    private func currentProjectName(_ context: WorkspaceCreationContext) -> String {
        workspaceManager.projects
            .first { $0.id == context.projectId }?
            .displayName ?? context.projectName
    }

    func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
