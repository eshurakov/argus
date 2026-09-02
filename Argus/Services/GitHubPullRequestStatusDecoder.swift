import Foundation

enum GitHubPullRequestStatusDecoder {
    struct Candidate {
        let metadata: PullRequestWorkspaceMetadata
        let lifecycle: PullRequestLifecycle

        var isOpen: Bool { lifecycle == .open || lifecycle == .draft }
    }

    static func repository(from data: Data) throws -> RepositoryIdentity {
        let response = try decode(RepositoryResponse.self, from: data)
        let (identity, _) = try canonicalURL(response.url, number: nil)
        let names = response.nameWithOwner.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard names.count == 2, validName(names[0]), validName(names[1]),
            identity
                == RepositoryIdentity(
                    provider: .github, host: identity.host, owner: names[0], repositoryName: names[1]
                )
        else { throw invalid("The repository name and URL do not agree.") }
        return identity
    }

    static func candidates(from data: Data, repository: RepositoryIdentity) throws -> [Candidate] {
        let responses = try decode([CoreResponse].self, from: data)
        guard responses.count < 50 else { throw PullRequestStatusError.lookupLimit }
        let candidates = try responses.map { try candidate($0, repository: repository) }
        let identities = Set(candidates.map(\.metadata.pullRequest))
        guard identities.count == candidates.count else {
            throw invalid("The candidate list contains duplicate Pull Request identities.")
        }
        return candidates
    }

    static func status(from data: Data, identity: PullRequestIdentity) throws -> PullRequestStatus {
        let response = try decode(StatusResponse.self, from: data)
        let candidate = try candidate(response.core, repository: identity.repository)
        let metadata = candidate.metadata
        guard metadata.pullRequest == identity else {
            throw invalid("The returned Pull Request identity did not match the request.")
        }
        guard GitReferenceValidation.isValidBranchName(response.baseRefName) else {
            throw invalid("The base branch name is invalid.")
        }
        return PullRequestStatus(
            identity: metadata.pullRequest,
            url: metadata.canonicalURL,
            title: metadata.title,
            headBranchName: metadata.headBranchName,
            headCommitObjectID: metadata.headCommitObjectID,
            headRepository: metadata.headRepository,
            baseBranchName: response.baseRefName,
            lifecycle: candidate.lifecycle,
            review: response.review,
            checks: response.checks
        )
    }

    static func repositoryArgument(_ repository: RepositoryIdentity) throws -> String {
        let labels = repository.host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty,
            labels.allSatisfy({ label in
                !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                    && label.utf8.allSatisfy { asciiAlphaNumeric($0) || $0 == 45 }
            }),
            validName(repository.owner), validName(repository.repositoryName)
        else { throw invalid("The Repository Identity is invalid.") }
        return "\(repository.host)/\(repository.owner)/\(repository.repositoryName)"
    }

    static func validateBranch(_ branch: PullRequestBranchContext) throws {
        guard GitReferenceValidation.isValidBranchName(branch.branchName),
            [40, 64].contains(branch.headCommitObjectID.utf8.count),
            branch.headCommitObjectID.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            })
        else { throw invalid("The local branch or HEAD is invalid.") }
        if let upstream = branch.upstreamRepository {
            _ = try repositoryArgument(upstream)
        }
    }

    private static func candidate(_ response: CoreResponse, repository: RepositoryIdentity) throws -> Candidate {
        let (baseRepository, url) = try canonicalURL(response.url, number: response.number)
        guard baseRepository == repository else {
            throw invalid("The returned Pull Request belongs to a different repository.")
        }
        let lifecycle: PullRequestLifecycle
        switch response.state {
        case "OPEN": lifecycle = response.isDraft ? .draft : .open
        case "MERGED": lifecycle = .merged
        case "CLOSED": lifecycle = .closed
        default: throw invalid("The Pull Request lifecycle is missing or unknown.")
        }
        let headRepository = try headRepository(response, baseRepository: repository)
        do {
            let metadata = try PullRequestWorkspaceMetadata(
                pullRequest: PullRequestIdentity(repository: repository, number: response.number),
                canonicalURL: url,
                title: response.title,
                baseRepository: repository,
                headRepository: headRepository,
                headBranchName: response.headRefName,
                headCommitObjectID: response.headRefOid,
                isCrossRepository: response.isCrossRepository
            )
            return Candidate(metadata: metadata, lifecycle: lifecycle)
        } catch {
            throw invalid("The Pull Request title, head branch, or head commit is invalid.")
        }
    }

    private static func headRepository(
        _ response: CoreResponse,
        baseRepository: RepositoryIdentity
    ) throws -> RepositoryIdentity? {
        let owner = response.headRepositoryOwner?.value
        if let owner, !validName(owner) { throw invalid("The head repository owner is invalid.") }
        guard let head = response.headRepository else {
            if !response.isCrossRepository, let owner, owner.lowercased() != baseRepository.owner {
                throw invalid("The head repository metadata is inconsistent.")
            }
            return response.isCrossRepository ? nil : baseRepository
        }
        let names = head.nameWithOwner?.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if let names, names.count != 2 { throw invalid("The head repository name is invalid.") }
        let owners = [owner, head.owner?.value, names?.first].compactMap { $0 }
        let repositoryNames = [head.name, names?.last].compactMap { $0 }
        guard let resolvedOwner = owners.first, let name = repositoryNames.first,
            owners.allSatisfy({ validName($0) && $0.lowercased() == resolvedOwner.lowercased() }),
            repositoryNames.allSatisfy({ validName($0) && $0.lowercased() == name.lowercased() })
        else { throw invalid("The head Repository Identity is missing or inconsistent.") }
        let identity = RepositoryIdentity(
            provider: .github, host: baseRepository.host, owner: resolvedOwner, repositoryName: name
        )
        guard response.isCrossRepository == (identity != baseRepository) else {
            throw invalid("The head repository and fork metadata do not agree.")
        }
        return identity
    }

    private static func canonicalURL(_ value: String, number: Int?) throws -> (RepositoryIdentity, URL) {
        guard let components = URLComponents(string: value), components.scheme?.lowercased() == "https",
            let host = components.host, components.user == nil, components.password == nil,
            components.port == nil, components.query == nil, components.fragment == nil,
            components.percentEncodedPath == components.path
        else { throw invalid("The provider URL is not a canonical HTTPS URL.") }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard path.count == (number == nil ? 3 : 5), path[0].isEmpty else {
            throw invalid("The provider URL path is invalid.")
        }
        if let number {
            guard number > 0, path[3] == "pull", path[4] == String(number) else {
                throw invalid("The Pull Request number and URL do not agree.")
            }
        }
        let identity = RepositoryIdentity(provider: .github, host: host, owner: path[1], repositoryName: path[2])
        let argument = try repositoryArgument(identity)
        let suffix = number.map { "/pull/\($0)" } ?? ""
        guard let url = URL(string: "https://\(argument)\(suffix)") else {
            throw invalid("The provider URL is invalid.")
        }
        return (identity, url)
    }

    private static func validName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && value.utf8.allSatisfy { asciiAlphaNumeric($0) || [45, 46, 95].contains($0) }
    }

    private static func asciiAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw invalid("The GitHub CLI returned malformed or incomplete JSON.")
        }
    }

    private static func invalid(_ detail: String) -> PullRequestStatusError {
        .invalidMetadata(detail)
    }
}

private struct RepositoryResponse: Decodable {
    let nameWithOwner: String
    let url: String
}

private struct CoreResponse: Decodable {
    let number: Int
    let title: String
    let url: String
    let state: String
    let isDraft: Bool
    let headRefName: String
    let headRefOid: String
    let headRepository: HeadRepository?
    let headRepositoryOwner: Owner?
    let isCrossRepository: Bool
}

private struct HeadRepository: Decodable {
    let name: String?
    let nameWithOwner: String?
    let owner: Owner?
}

private struct Owner: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let value = try? single.decode(String.self) {
            self.value = value
        } else {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            value =
                try values.decodeIfPresent(String.self, forKey: .login)
                ?? values.decodeIfPresent(String.self, forKey: .name)
        }
    }

    private enum CodingKeys: CodingKey {
        case login
        case name
    }
}

private struct StatusResponse: Decodable {
    let core: CoreResponse
    let baseRefName: String
    let review: PullRequestReviewDecision
    let checks: PullRequestChecks

    init(from decoder: Decoder) throws {
        core = try CoreResponse(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseRefName = try values.decode(String.self, forKey: .baseRefName)
        if values.contains(.reviewDecision), (try? values.decodeNil(forKey: .reviewDecision)) == true {
            review = .none
        } else {
            switch try? values.decode(String.self, forKey: .reviewDecision) {
            case "APPROVED": review = .approved
            case "CHANGES_REQUESTED": review = .changesRequested
            case "REVIEW_REQUIRED": review = .required
            case "": review = .none
            default: review = .unavailable
            }
        }
        let commits = try? values.decode(Commits.self, forKey: .commits)
        if let commits, commits.nodes.count == 1, let node = commits.nodes[0] {
            checks = node.commit?.checks ?? .unavailable
        } else {
            checks = .unavailable
        }
    }

    private enum CodingKeys: CodingKey {
        case baseRefName
        case reviewDecision
        case commits
    }

    private struct Commits: Decodable {
        let nodes: [CommitNode?]
    }

    private struct CommitNode: Decodable {
        let commit: Commit?
    }

    private struct Commit: Decodable {
        let checks: PullRequestChecks

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard values.contains(.statusCheckRollup) else {
                checks = .unavailable
                return
            }
            if try values.decodeNil(forKey: .statusCheckRollup) {
                checks = PullRequestChecks()
                return
            }
            let rollup = try values.decode(Rollup.self, forKey: .statusCheckRollup)
            if let contexts = rollup.contexts, let nodes = contexts.nodes {
                checks = normalizeChecks(nodes, isComplete: contexts.pageInfo?.hasNextPage == false)
            } else {
                checks = .unavailable
            }
        }

        private enum CodingKeys: CodingKey {
            case statusCheckRollup
        }
    }

    private struct Rollup: Decodable {
        let contexts: Contexts?
    }

    private struct Contexts: Decodable {
        let nodes: [Check?]?
        let pageInfo: PageInfo?
    }

    private struct PageInfo: Decodable {
        let hasNextPage: Bool
    }

    private static func normalizeChecks(_ checks: [Check?], isComplete: Bool) -> PullRequestChecks {
        var passed = 0
        var failed = 0
        var pending = 0
        var skipped = 0
        var unknown = 0
        for check in checks {
            switch check?.state ?? .unknown {
            case .passed: passed += 1
            case .failed: failed += 1
            case .pending: pending += 1
            case .none: skipped += 1
            case .unknown: unknown += 1
            }
        }
        return PullRequestChecks(
            passed: passed, failed: failed, pending: pending, skipped: skipped, unknown: unknown,
            isAvailable: isComplete && checks.count < 100
        )
    }
}

private struct Check: Decodable {
    let typename: String?
    let status: String?
    let conclusion: String?
    let contextState: String?

    var state: PullRequestCheckState {
        switch typename {
        case "CheckRun":
            switch status {
            case "QUEUED", "IN_PROGRESS", "PENDING", "WAITING", "REQUESTED", "EXPECTED": return .pending
            case "COMPLETED":
                switch conclusion {
                case "SUCCESS": return .passed
                case "FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE": return .failed
                case "SKIPPED", "NEUTRAL": return .none
                default: return .unknown
                }
            default: return .unknown
            }
        case "StatusContext":
            switch contextState {
            case "SUCCESS": return .passed
            case "ERROR", "FAILURE": return .failed
            case "PENDING", "EXPECTED": return .pending
            default: return .unknown
            }
        default: return .unknown
        }
    }

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case status
        case conclusion
        case contextState = "state"
    }
}
