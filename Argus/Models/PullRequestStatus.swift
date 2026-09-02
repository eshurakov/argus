import Foundation

enum PullRequestLifecycle: Equatable, Sendable {
    case open
    case draft
    case merged
    case closed

    var label: String {
        switch self {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }
}

enum PullRequestReviewDecision: Equatable, Sendable {
    case approved
    case changesRequested
    case required
    case none
    case unavailable

    var label: String {
        switch self {
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .required: "Review required"
        case .none: "No review decision"
        case .unavailable: "Review unavailable"
        }
    }
}

enum PullRequestCheckState: Equatable, Sendable {
    case passed
    case failed
    case pending
    case none
    case unknown
}

struct PullRequestChecks: Equatable, Sendable {
    let passed: Int
    let failed: Int
    let pending: Int
    let skipped: Int
    let unknown: Int
    let isAvailable: Bool

    init(
        passed: Int = 0,
        failed: Int = 0,
        pending: Int = 0,
        skipped: Int = 0,
        unknown: Int = 0,
        isAvailable: Bool = true
    ) {
        self.passed = passed
        self.failed = failed
        self.pending = pending
        self.skipped = skipped
        self.unknown = unknown
        self.isAvailable = isAvailable
    }

    static let unavailable = PullRequestChecks(isAvailable: false)

    var state: PullRequestCheckState {
        if failed > 0 { return .failed }
        if pending > 0 { return .pending }
        if !isAvailable || unknown > 0 { return .unknown }
        return passed > 0 ? .passed : .none
    }

    var summary: String {
        var parts = [String]()
        for (count, label) in [
            (failed, "failed"), (pending, "pending"), (unknown, "unknown"),
            (passed, "passed"), (skipped, "skipped/neutral")
        ] where count > 0 {
            parts.append("\(count) \(label)")
        }
        if !isAvailable { parts.append("Checks unavailable") }
        return parts.isEmpty ? "No checks" : parts.joined(separator: " · ")
    }
}

struct PullRequestStatus: Equatable, Sendable {
    let identity: PullRequestIdentity
    let url: URL
    let title: String
    let headBranchName: String
    let headCommitObjectID: String
    let headRepository: RepositoryIdentity?
    let baseBranchName: String
    let lifecycle: PullRequestLifecycle
    let review: PullRequestReviewDecision
    let checks: PullRequestChecks
}

struct PullRequestAssociation: Equatable, Sendable {
    let identity: PullRequestIdentity
    let headBranchName: String
    let headRepository: RepositoryIdentity?

    init(identity: PullRequestIdentity, headBranchName: String, headRepository: RepositoryIdentity?) {
        self.identity = identity
        self.headBranchName = headBranchName
        self.headRepository = headRepository
    }

    init(_ status: PullRequestStatus) {
        self.init(
            identity: status.identity, headBranchName: status.headBranchName, headRepository: status.headRepository
        )
    }

    func validate(_ status: PullRequestStatus) throws {
        guard status.identity == identity, status.headBranchName == headBranchName,
            headRepository == nil || status.headRepository == nil || status.headRepository == headRepository
        else {
            throw PullRequestStatusError.invalidMetadata(
                "The returned Pull Request identity, branch, or head repository changed during the lookup."
            )
        }
    }
}

struct PullRequestStatusQuota: Equatable, Sendable {
    let cost: Int
    let remaining: Int
    let resetAt: Date
}

struct PullRequestStatusBatch: Sendable {
    static let limit = 20

    let results: [PullRequestIdentity: Result<PullRequestStatus, PullRequestStatusError>]
    let quota: PullRequestStatusQuota
    var retryAfter: Date?
}

struct PullRequestBranchContext: Equatable, Sendable {
    let branchName: String
    let headCommitObjectID: String
    let upstreamRepository: RepositoryIdentity?
}

enum PullRequestStatusError: Error, LocalizedError, Equatable, Sendable {
    case githubCLIUnavailable
    case unauthenticated
    case repositoryUnavailable(String)
    case ambiguous
    case lookupLimit
    case unverifiedAssociation
    case invalidMetadata(String)
    case providerTimedOut
    case providerFailed(String)
    case rateLimited(retryAfter: Date?)
    case secondaryRateLimited(retryAfter: Date?)
    case quotaPaused(until: Date)

    var pauseDeadline: Date? {
        switch self {
        case .rateLimited(let deadline), .secondaryRateLimited(let deadline): deadline
        case .quotaPaused(let deadline): deadline
        default: nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .githubCLIUnavailable:
            "The GitHub CLI (gh) is not installed. Install it with: brew install gh"
        case .unauthenticated:
            "The GitHub CLI is not authenticated. Run: gh auth login"
        case .repositoryUnavailable(let detail):
            "The GitHub repository is unavailable. " + detail
        case .ambiguous:
            "Multiple matching Pull Requests were found."
        case .lookupLimit:
            "Pull Request lookup limit reached. The candidate list may be incomplete."
        case .unverifiedAssociation:
            "The Pull Request association could not be verified for the current branch and HEAD."
        case .invalidMetadata(let detail):
            "GitHub returned invalid Pull Request status metadata. " + detail
        case .providerTimedOut:
            "The GitHub CLI timed out while loading Pull Request status."
        case .providerFailed(let detail):
            "GitHub CLI could not load Pull Request status. " + detail
        case .rateLimited, .secondaryRateLimited:
            "GitHub rate limited Pull Request status requests. " + pauseExplanation
        case .quotaPaused:
            "Pull Request status refresh is paused to conserve GitHub quota. " + pauseExplanation
        }
    }

    private var pauseExplanation: String {
        if let pauseDeadline {
            return "Automatic and manual refresh can resume at "
                + pauseDeadline.formatted(date: .abbreviated, time: .standard) + "."
        }
        return "Automatic and manual refresh will resume after the limit resets."
    }
}

protocol PullRequestStatusProviding: Sendable {
    func resolveRepository(repositoryPath: String, fetchRemotes: [GitFetchRemote]) async throws -> RepositoryIdentity
    func discoverPullRequest(
        repository: RepositoryIdentity,
        branch: PullRequestBranchContext,
        previous: PullRequestStatus?,
        repositoryPath: String
    ) async throws -> PullRequestAssociation?
    func refreshPullRequests(
        _ identities: [PullRequestIdentity], repositoryPath: String
    ) async throws -> PullRequestStatusBatch
}
