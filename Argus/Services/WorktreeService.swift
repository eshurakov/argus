import Foundation

// MARK: - Error Type

/// Errors originating from git worktree operations.
enum WorktreeError: LocalizedError {
    case notAGitRepository(String)
    case branchAlreadyExists(String)
    case worktreeCreationFailed(String)
    case worktreeRemovalFailed(String)
    case baseBranchRecordingFailed(String)
    case mainBranchDetectionFailed
    case gitCommandFailed(String, Int32)
    case gitCommandTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .notAGitRepository(let path):
            "Not a git repository: \(path)"
        case .branchAlreadyExists(let branch):
            "Branch already exists: \(branch)"
        case .worktreeCreationFailed(let detail):
            "Worktree creation failed: \(detail)"
        case .worktreeRemovalFailed(let detail):
            "Worktree removal failed: \(detail)"
        case .baseBranchRecordingFailed(let detail):
            "Recording the base branch failed: \(detail)"
        case .mainBranchDetectionFailed:
            "Could not detect the main branch of the repository"
        case .gitCommandFailed(let command, let exitCode):
            "Git command failed (exit \(exitCode)): \(command)"
        case .gitCommandTimedOut(let command):
            "Git command timed out: \(command)"
        }
    }
}

// MARK: - Supporting Types

/// Information about an existing git worktree, parsed from `git worktree list --porcelain`.
struct WorktreeInfo: Sendable {
    let path: String
    let branch: String
    let commitHash: String
    let isHead: Bool
}

/// An orphaned worktree on disk that has no corresponding workspace.
struct OrphanedWorktreeInfo: Identifiable, Sendable {
    let id = UUID()
    let path: String
    let branchName: String?
    let projectId: UUID
}

// MARK: - WorktreeService

/// Manages git worktrees via the git CLI (`/usr/bin/git`).
///
/// All git operations are performed by spawning `Process` instances.
/// This service is intentionally NOT `@MainActor` — git commands run
/// on background threads to avoid blocking the UI.
///
/// Worktree storage: `~/.argus/worktrees/<project-uuid>/<branch-slug>/`
final class WorktreeService: Sendable {

    // MARK: - Constants

    /// Interactive git operations must eventually return control to the UI.
    private let gitCommandTimeout: TimeInterval

    /// Removal deletes every file in a worktree, so it is allowed to take much
    /// longer than a query. A short budget is worse than a slow delete here: an
    /// interrupted removal leaves a worktree Git itself can no longer remove.
    static let worktreeRemovalTimeout: TimeInterval = 300

    /// Base directory for all Argus-managed worktrees.
    static let worktreeBaseURL: URL = {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".argus/worktrees", isDirectory: true)
    }()

    /// Path to the git binary.
    private static let gitPath = "/usr/bin/git"
    let managedWorktreeBaseURL: URL

    init(
        gitCommandTimeout: TimeInterval = 30,
        worktreeBaseURL: URL = WorktreeService.worktreeBaseURL
    ) {
        self.gitCommandTimeout = gitCommandTimeout
        self.managedWorktreeBaseURL = worktreeBaseURL.standardizedFileURL
    }
    // MARK: - Private Helpers

    /// Runs a git command and returns the trimmed stdout output.
    ///
    /// - Parameters:
    ///   - args: Arguments to pass to git (e.g. `["status", "--porcelain"]`).
    ///   - workingDirectory: Optional working directory for the process.
    /// - Throws: `WorktreeError.gitCommandFailed` on non-zero exit code.
    /// - Returns: The trimmed standard output of the command.
    func runGit(
        args: [String],
        workingDirectory: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> String {
        try await runProcess(
            executableURL: URL(fileURLWithPath: Self.gitPath),
            args: args,
            workingDirectory: workingDirectory,
            environment: GitCommandEnvironment.standard,
            timeout: timeout,
            commandDescription: "git \(args.joined(separator: " "))"
        )
    }
    /// Runs a subprocess while draining both output pipes. The timeout covers
    /// the launched process only. Descendants that inherit pipe handles after
    /// the parent exits must not keep the caller waiting.
    func runProcess(
        executableURL: URL,
        args: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil,
        commandDescription: String
    ) async throws -> String {
        let result: ExternalProcessResult
        do {
            result = try await ExternalProcess.run(
                executableURL: executableURL,
                arguments: args,
                workingDirectory: workingDirectory,
                environment: environment,
                timeout: timeout ?? gitCommandTimeout,
                commandDescription: commandDescription
            )
        } catch let error as ExternalProcessError {
            switch error {
            case .timedOut(let command):
                throw WorktreeError.gitCommandTimedOut(command)
            }
        }

        let output =
            String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard result.terminationStatus == 0 else {
            let errorOutput =
                String(data: result.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = errorOutput.isEmpty ? output : errorOutput
            throw WorktreeError.gitCommandFailed(
                "\(commandDescription): \(detail)",
                result.terminationStatus
            )
        }
        return output
    }
    /// Runs a git command and returns whether it succeeded (exit code 0).
    func runGitQuiet(
        args: [String],
        workingDirectory: String? = nil
    ) async -> Bool {
        do {
            _ = try await runGit(args: args, workingDirectory: workingDirectory)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Slug Generation

    /// Converts a branch name into a filesystem-safe, git-compatible slug.
    ///
    /// Rules: lowercase, `/` and spaces become `-`, non-alphanumeric/non-hyphen
    /// characters are stripped, consecutive hyphens collapsed, leading/trailing
    /// hyphens trimmed.
    func slugify(_ branchName: String) -> String {
        var slug = branchName.lowercased()

        // Replace `/` and spaces with hyphens.
        slug = slug.replacingOccurrences(of: "/", with: "-")
        slug = slug.replacingOccurrences(of: " ", with: "-")

        // Strip characters that are not alphanumeric or hyphens.
        slug = String(
            slug.unicodeScalars.filter { scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
            })

        // Collapse consecutive hyphens into a single hyphen.
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }
        // Trim leading and trailing hyphens.
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return slug.isEmpty ? "workspace" : slug
    }

    /// Returns a unique slug for the given branch name under the project's
    /// worktree directory, appending `-1`, `-2`, etc. if needed.
    func uniqueSlug(_ branchName: String, projectId: UUID) -> String {
        let base = slugify(branchName)
        let projectDir =
            managedWorktreeBaseURL
            .appendingPathComponent(projectId.uuidString, isDirectory: true)

        let fm = FileManager.default

        // Fast path: no collision.
        let candidatePath = projectDir.appendingPathComponent(base).path
        if !fm.fileExists(atPath: candidatePath) {
            return base
        }
        // Append numeric suffix until unique.
        var counter = 1
        while true {
            let candidate = "\(base)-\(counter)"
            let path = projectDir.appendingPathComponent(candidate).path
            if !fm.fileExists(atPath: path) {
                return candidate
            }
            counter += 1
        }
    }

    // MARK: - Main Branch Detection

    /// Detects the main branch of a repository using a cascading strategy.
    ///
    /// 1. Symbolic ref `refs/remotes/origin/HEAD` → parse branch name
    /// 2. `git show-ref --verify refs/heads/main` → "main"
    /// 3. `git show-ref --verify refs/heads/master` → "master"
    /// 4. `git rev-parse --abbrev-ref HEAD` → current branch
    /// 5. Throw `mainBranchDetectionFailed`
    ///
    /// Spec §Projects rule 4: try symbolic references first, then common
    /// branch names, then current HEAD.
    func detectMainBranch(repositoryPath: String) async throws -> String {
        // Strategy 1: symbolic-ref for origin/HEAD.
        if let output = try? await runGit(
            args: ["symbolic-ref", "refs/remotes/origin/HEAD"],
            workingDirectory: repositoryPath
        ) {
            // Output is e.g. "refs/remotes/origin/main" — extract the branch name.
            let components = output.split(separator: "/")
            if let branchName = components.last, !branchName.isEmpty {
                return String(branchName)
            }
        }
        // Strategy 2: check for refs/heads/main.
        if await runGitQuiet(
            args: ["show-ref", "--verify", "refs/heads/main"],
            workingDirectory: repositoryPath
        ) {
            return "main"
        }
        // Strategy 3: check for refs/heads/master.
        if await runGitQuiet(
            args: ["show-ref", "--verify", "refs/heads/master"],
            workingDirectory: repositoryPath
        ) {
            return "master"
        }
        // Strategy 4: current HEAD branch name.
        if let output = try? await runGit(
            args: ["rev-parse", "--abbrev-ref", "HEAD"],
            workingDirectory: repositoryPath
        ), !output.isEmpty, output != "HEAD" {
            return output
        }

        // Spec §Error Handling rule 3: return a specific error rather than
        // silently defaulting.
        throw WorktreeError.mainBranchDetectionFailed
    }

    /// Returns the repository's currently checked-out branch, or `(detached)`
    /// when HEAD is detached.
    func currentBranchName(repositoryPath: String) async throws -> String {
        let output = try await runGit(
            args: ["rev-parse", "--abbrev-ref", "HEAD"],
            workingDirectory: repositoryPath
        )
        return output == "HEAD" ? "(detached)" : output
    }

    // MARK: - Repository Validation

    /// Returns `true` if the given path is inside a git repository.
    func isGitRepository(path: String) async -> Bool {
        await runGitQuiet(
            args: ["-C", path, "rev-parse", "--git-dir"]
        )
    }

    /// Resolves any path inside a git repository to the canonical repository root.
    func canonicalRepositoryRoot(for path: String) async throws -> String {
        do {
            let root = try await runGit(
                args: ["-C", path, "rev-parse", "--show-toplevel"],
                workingDirectory: path
            )
            return URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        } catch {
            throw WorktreeError.notAGitRepository(path)
        }
    }

}
