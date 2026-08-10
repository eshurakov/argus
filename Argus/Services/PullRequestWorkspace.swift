import Foundation

/// Hosting providers understood by Pull Request intake.
enum RepositoryProvider: String, Equatable, Hashable, Sendable {
    case github
}

/// A provider-qualified identity for one hosted repository.
struct RepositoryIdentity: Equatable, Hashable, Sendable, CustomStringConvertible {
    let provider: RepositoryProvider
    let host: String
    let owner: String
    let repositoryName: String

    init(
        provider: RepositoryProvider,
        host: String,
        owner: String,
        repositoryName: String
    ) {
        self.provider = provider
        self.host = host.lowercased()
        self.owner = owner.lowercased()
        self.repositoryName = Self.normalizedRepositoryName(repositoryName)
    }

    var description: String {
        provider.rawValue + "://" + host + "/" + owner + "/" + repositoryName
    }

    /// The canonical GitHub identity in a Pull Request URL.
    static func github(fromPullRequestURL url: URL) -> RepositoryIdentity? {
        guard url.scheme?.lowercased() == "https",
            url.user == nil,
            url.password == nil,
            let host = url.host,
            !host.isEmpty
        else { return nil }

        let components = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count >= 4,
            components[0].isEmpty == false,
            components[1].isEmpty == false,
            components[2].lowercased() == "pull",
            Self.isPositiveASCIINumber(components[3])
        else { return nil }

        return RepositoryIdentity(
            provider: .github,
            host: host,
            owner: components[0],
            repositoryName: components[1]
        )
    }

    /// Normalizes a GitHub fetch URL from the supported HTTPS, SSH, and SCP
    /// forms. Non-GitHub and push-only URL handling stays outside this type.
    static func github(fromFetchRemoteURL rawURL: String) -> RepositoryIdentity? {
        let value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let host: String
        let path: String
        if !value.contains("://"),
            let atIndex = value.firstIndex(of: "@"),
            let colon = value[atIndex...].firstIndex(of: ":"),
            colon > atIndex
        {
            host = String(value[value.index(after: atIndex)..<colon])
            path = String(value[value.index(after: colon)...])
        } else {
            guard let url = URL(string: value),
                let scheme = url.scheme?.lowercased(),
                scheme == "https" || scheme == "ssh",
                let urlHost = url.host,
                !urlHost.isEmpty
            else { return nil }
            host = urlHost
            path = url.path
        }

        let components =
            path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count == 2,
            !components[0].isEmpty,
            !components[1].isEmpty
        else { return nil }

        return RepositoryIdentity(
            provider: .github,
            host: host,
            owner: components[0],
            repositoryName: components[1]
        )
    }

    private static func normalizedRepositoryName(_ name: String) -> String {
        let normalized = name.lowercased()
        return normalized.hasSuffix(".git")
            ? String(normalized.dropLast(4))
            : normalized
    }

    private static func isPositiveASCIINumber(_ value: String) -> Bool {
        guard !value.isEmpty,
            value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            let number = Int(value)
        else { return false }
        return number > 0
    }
}

/// A provider-qualified Pull Request identity.
struct PullRequestIdentity: Equatable, Hashable, Sendable {
    let repository: RepositoryIdentity
    let number: Int
}

/// Errors exposed by Pull Request intake. The cases intentionally keep UI
/// mapping stable while preserving the useful boundary that failed.
enum PullRequestWorkspaceError: LocalizedError, Equatable, Sendable {
    case emptyInput
    case malformedInput(String)
    case githubCLIUnavailable
    case unauthenticated(host: String?)
    case ambiguousDefaultRepository
    case metadataUnavailable(String)
    case invalidMetadata(String)
    case baseRepositoryMismatch(RepositoryIdentity)
    case unavailableHead(String)
    case conflictingLocalBranch(name: String, existingCommit: String, fetchedCommit: String)
    case providerTimedOut
    case cancelled
    case providerCommandFailed(String)
    case gitFetchFailed(String)
    case worktreeCreationFailed(String)
    case worktreeCleanupFailed(String)
    case projectUnavailable
    case catchAllProject
    case workspaceLimitReached
    case projectChanged

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            "Enter a Pull Request URL or number."
        case .malformedInput(let detail):
            "Invalid Pull Request input. " + detail
        case .githubCLIUnavailable:
            "The GitHub CLI (gh) is not installed. Install it with: brew install gh"
        case .unauthenticated(let host):
            if let host, !host.isEmpty {
                "The GitHub CLI is not authenticated for " + host
                    + ". Run: gh auth login --hostname " + host
            } else {
                "The GitHub CLI is not authenticated. Run: gh auth login"
            }
        case .ambiguousDefaultRepository:
            "GitHub CLI could not choose a default repository for this Pull Request number. "
                + "Run gh repo set-default <remote> in the Project Repository Root."
        case .metadataUnavailable(let detail):
            "GitHub Pull Request metadata is unavailable. " + detail
        case .invalidMetadata(let detail):
            "GitHub returned invalid Pull Request metadata. " + detail
        case .baseRepositoryMismatch(let identity):
            "This Pull Request belongs to " + identity.description
                + ", which is not represented by a fetch remote of the selected Named Project."
        case .unavailableHead(let detail):
            "The Pull Request head is unavailable. " + detail
        case .conflictingLocalBranch(let name, let existingCommit, let fetchedCommit):
            "Local branch '" + name + "' already points to " + existingCommit
                + ", but the Pull Request head is " + fetchedCommit
                + ". Argus will not reset or rename the branch."
        case .providerTimedOut:
            "The GitHub CLI timed out while resolving the Pull Request."
        case .cancelled:
            "Pull Request creation was cancelled."
        case .providerCommandFailed(let detail):
            "GitHub CLI could not resolve the Pull Request. " + detail
        case .gitFetchFailed(let detail):
            "Fetching the Pull Request head failed. " + detail
        case .worktreeCreationFailed(let detail):
            "Creating the Pull Request Worktree Workspace failed. " + detail
        case .worktreeCleanupFailed(let detail):
            "Cleaning up the Pull Request Worktree failed. " + detail
        case .projectUnavailable:
            "The selected Named Project is no longer available."
        case .catchAllProject:
            "Pull Request intake is available only for a Named Project."
        case .workspaceLimitReached:
            "Argus cannot create another Workspace because the 128-Workspace limit has been reached."
        case .projectChanged:
            "The selected Named Project changed while the Pull Request was being prepared. No Workspace was created."
        }
    }
}

/// Parsed input accepted by the New Workspace sheet.
enum PullRequestInput: Equatable, Sendable {
    case number(Int)
    case url(URL)

    static func parse(_ rawValue: String) throws -> PullRequestInput {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw PullRequestWorkspaceError.emptyInput }

        if value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) {
            guard let number = Int(value), number > 0 else {
                throw PullRequestWorkspaceError.malformedInput(
                    "Use a positive integer or an HTTPS GitHub Pull Request URL."
                )
            }
            return .number(number)
        }

        guard let url = URL(string: value),
            RepositoryIdentity.github(fromPullRequestURL: url) != nil,
            Self.number(from: url) != nil
        else {
            throw PullRequestWorkspaceError.malformedInput(
                "Use a positive number or an HTTPS URL shaped like https://host/owner/repository/pull/123."
            )
        }
        return .url(url)
    }

    var number: Int? {
        switch self {
        case .number(let number): return number
        case .url(let url): return Self.number(from: url)
        }
    }

    var repositoryIdentity: RepositoryIdentity? {
        switch self {
        case .number: return nil
        case .url(let url): return RepositoryIdentity.github(fromPullRequestURL: url)
        }
    }

    var hostHint: String? {
        repositoryIdentity?.host
    }

    var providerArgument: String {
        switch self {
        case .number(let number): return String(number)
        case .url(let url): return url.absoluteString
        }
    }

    private static func number(from url: URL) -> Int? {
        let components = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count >= 4,
            components[2].lowercased() == "pull",
            components[3].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            let number = Int(components[3]),
            number > 0
        else { return nil }
        return number
    }
}

/// Metadata needed to turn one Pull Request into a local Worktree Workspace.
struct PullRequestWorkspaceMetadata: Equatable, Sendable {
    let pullRequest: PullRequestIdentity
    let canonicalURL: URL
    let title: String
    let baseRepository: RepositoryIdentity
    let headRepository: RepositoryIdentity?
    let headBranchName: String
    let headCommitObjectID: String
    let isCrossRepository: Bool

    init(
        pullRequest: PullRequestIdentity,
        canonicalURL: URL,
        title: String,
        baseRepository: RepositoryIdentity,
        headRepository: RepositoryIdentity?,
        headBranchName: String,
        headCommitObjectID: String,
        isCrossRepository: Bool
    ) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PullRequestWorkspaceError.invalidMetadata("The Pull Request title is empty.")
        }
        guard GitReferenceValidation.isValidBranchName(headBranchName) else {
            throw PullRequestWorkspaceError.invalidMetadata(
                "GitHub returned an invalid head branch name."
            )
        }
        guard Self.isValidCommitObjectID(headCommitObjectID) else {
            throw PullRequestWorkspaceError.invalidMetadata(
                "GitHub returned a malformed head commit object ID."
            )
        }
        guard pullRequest.number > 0,
            pullRequest.repository == baseRepository,
            let parsedURLInput = try? PullRequestInput.parse(canonicalURL.absoluteString),
            parsedURLInput.number == pullRequest.number,
            parsedURLInput.repositoryIdentity == baseRepository
        else {
            throw PullRequestWorkspaceError.invalidMetadata(
                "The Pull Request URL and repository metadata do not agree."
            )
        }

        self.pullRequest = pullRequest
        self.canonicalURL = canonicalURL
        self.title = title
        self.baseRepository = baseRepository
        self.headRepository = headRepository
        self.headBranchName = headBranchName
        self.headCommitObjectID = headCommitObjectID.lowercased()
        self.isCrossRepository = isCrossRepository
    }

    var number: Int { pullRequest.number }
    var baseRepositoryIdentity: RepositoryIdentity { baseRepository }
    var headRepositoryIdentity: RepositoryIdentity? { headRepository }
    var localBranchName: String { headBranchName }
    var headCommit: String { headCommitObjectID }

    private static func isValidCommitObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57)
                    || (byte >= 65 && byte <= 70)
                    || (byte >= 97 && byte <= 102)
            }
    }
}

/// The small subset of Git ref validation needed before a Git process is run.
/// WorktreeService still runs `git check-ref-format --branch` as the final
/// authority immediately before changing repository state.
enum GitReferenceValidation {
    static func isValidBranchName(_ value: String) -> Bool {
        guard !value.isEmpty,
            value != ".",
            value != "..",
            !value.hasPrefix("-"),
            !value.hasPrefix("/"),
            !value.hasSuffix("/"),
            !value.contains("//"),
            !value.contains(".."),
            !value.contains("@{"),
            !value.hasSuffix(".lock")
        else { return false }

        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\")
        guard
            value.unicodeScalars.allSatisfy({ scalar in
                !CharacterSet.controlCharacters.contains(scalar)
                    && !forbidden.contains(scalar)
            })
        else { return false }

        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            let component = String(component)
            return component != "."
                && component != ".."
                && !component.hasPrefix(".")
                && !component.hasSuffix(".")
                && !component.hasSuffix(".lock")
        }
    }
}

/// A fetch remote and every URL Git reports for its fetch direction.
struct GitFetchRemote: Equatable, Sendable {
    let name: String
    let fetchURLs: [String]
}

/// Result of Pull Request head preparation.
struct PullRequestWorktreeResolution: Equatable, Sendable {
    let branchName: String
    let worktreePath: String
    let fetchedHeadObjectID: String
    let reusedExistingWorktree: Bool

    var localBranchName: String { branchName }
    var canonicalWorktreePath: String { worktreePath }
    var fetchedHead: String { fetchedHeadObjectID }
}
