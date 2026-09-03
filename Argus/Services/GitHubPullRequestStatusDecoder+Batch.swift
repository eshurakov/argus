import Foundation

extension GitHubPullRequestStatusDecoder {
    static func batch(
        _ response: GitHubStatusResponse, identities: [PullRequestIdentity]
    ) throws -> PullRequestStatusBatch {
        let envelope = try batchEnvelope(response)
        let errors: [GraphQLFieldError]
        do {
            errors = try envelope["errors"].map { try decodeObject([GraphQLFieldError].self, $0) } ?? []
        } catch {
            throw response.decodingFailure("The GraphQL error envelope is malformed.")
        }
        let data = envelope["data"] as? [String: Any]
        let quota = data?["rateLimit"].flatMap { try? decodeObject(GraphQLQuota.self, $0).value }
        let messages = errors.flatMap { [$0.message, $0.type ?? "", $0.extensions?.code ?? ""] }
        if let error = response.sharedFailure(messages: messages, quotaReset: quota?.resetAt) { throw error }
        if response.statusCode.map({ !(200..<300).contains($0) }) == true
            || (response.exitCode != 0 && errors.isEmpty)
        {
            throw response.failure(messages: messages)
        }
        guard let data, let quota, !errors.contains(where: { $0.path?.first?.field == "rateLimit" }) else {
            throw response.decodingFailure("The GraphQL response has no usable rate-limit metadata.")
        }
        let aliases = Set(identities.indices.map { "pr\($0)" })
        let unscoped = errors.contains { error in
            guard let alias = error.path?.first?.field else { return true }
            return !aliases.contains(alias)
        }
        var results: [PullRequestIdentity: Result<PullRequestStatus, PullRequestStatusError>] = [:]
        for (index, identity) in identities.enumerated() {
            let alias = "pr\(index)"
            results[identity] = batchResult(
                data[alias], identity: identity, errors: errors.filter { $0.path?.first?.field == alias },
                unscoped: unscoped)
        }
        let remaining = response.remaining.flatMap { $0 >= 0 ? min($0, quota.remaining) : nil } ?? quota.remaining
        return PullRequestStatusBatch(
            results: results,
            quota: PullRequestStatusQuota(
                cost: quota.cost, remaining: remaining, resetAt: max(quota.resetAt, response.resetAt ?? .distantPast)
            ),
            retryAfter: response.retryAfter
        )
    }

    private static func batchEnvelope(_ response: GitHubStatusResponse) throws -> [String: Any] {
        do {
            guard let value = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
                throw PullRequestStatusError.invalidMetadata("The GraphQL response is not an object.")
            }
            return value
        } catch {
            if response.exitCode != 0 || response.statusCode.map({ $0 >= 400 }) == true {
                throw response.failure(messages: [GitHubStatusResponse.diagnosticText(response.body)])
            }
            throw response.decodingFailure("The GitHub CLI returned malformed GraphQL JSON.")
        }
    }

    private static func batchResult(
        _ object: Any?, identity: PullRequestIdentity, errors: [GraphQLFieldError], unscoped: Bool
    ) -> Result<PullRequestStatus, PullRequestStatusError> {
        do {
            guard !unscoped else {
                throw PullRequestStatusError.invalidMetadata("The GraphQL query has unscoped field errors.")
            }
            let unavailable = try unavailableFields(errors)
            guard let repository = object as? [String: Any],
                var fields = repository["pullRequest"] as? [String: Any], fields["headRepository"] != nil
            else {
                throw PullRequestStatusError.invalidMetadata("The requested Pull Request fields are unavailable.")
            }
            for field in unavailable { fields.removeValue(forKey: field) }
            return .success(try status(from: JSONSerialization.data(withJSONObject: fields), identity: identity))
        } catch {
            return .failure(
                error as? PullRequestStatusError ?? .invalidMetadata("The Pull Request response is malformed."))
        }
    }

    private static func unavailableFields(_ errors: [GraphQLFieldError]) throws -> Set<String> {
        var fields = Set<String>()
        for error in errors {
            guard let path = error.path, path.count >= 3, path[1].field == "pullRequest",
                let field = path[2].field, ["reviewDecision", "commits"].contains(field)
            else {
                throw PullRequestStatusError.invalidMetadata("Required Pull Request fields are unavailable.")
            }
            fields.insert(field)
        }
        return fields
    }

    private static func decodeObject<Value: Decodable>(_ type: Value.Type, _ object: Any) throws -> Value {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed))
    }
}

private struct GraphQLQuota: Decodable {
    let value: PullRequestStatusQuota

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let cost = try values.decode(Int.self, forKey: .cost)
        let remaining = try values.decode(Int.self, forKey: .remaining)
        let reset = try values.decode(String.self, forKey: .resetAt)
        let formatter = ISO8601DateFormatter()
        var resetAt = formatter.date(from: reset)
        if resetAt == nil {
            formatter.formatOptions.insert(.withFractionalSeconds)
            resetAt = formatter.date(from: reset)
        }
        guard (0...Int(Int32.max)).contains(cost), (0...Int(Int32.max)).contains(remaining),
            let resetAt, resetAt.timeIntervalSince1970.isFinite, resetAt.timeIntervalSince1970 > 0
        else { throw PullRequestStatusError.invalidMetadata("The GraphQL rate-limit metadata is invalid.") }
        value = PullRequestStatusQuota(cost: cost, remaining: remaining, resetAt: resetAt)
    }

    private enum CodingKeys: CodingKey {
        case cost
        case remaining
        case resetAt
    }
}

private struct GraphQLFieldError: Decodable {
    let message: String
    let type: String?
    let path: [GraphQLPathComponent]?
    let extensions: Extensions?

    struct Extensions: Decodable {
        let code: String?
    }
}

private enum GraphQLPathComponent: Decodable {
    case field(String)
    case index(Int)

    var field: String? {
        if case .field(let field) = self { return field }
        return nil
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let field = try? value.decode(String.self) {
            self = .field(field)
        } else {
            self = .index(try value.decode(Int.self))
        }
    }
}
