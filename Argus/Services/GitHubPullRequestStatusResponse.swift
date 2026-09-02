import Foundation

struct GitHubStatusResponse {
    let body: Data
    let exitCode: Int32
    let statusCode: Int?
    let retryAfter: Date?
    let resetAt: Date?
    let remaining: Int?
    private let diagnostic: String
    private let receivedAt: Date

    init(_ result: GitHubCommandResult, receivedAt: Date = Date()) throws {
        var content = result.stdout
        var headers: [String: String] = [:]
        var statusCode: Int?
        while content.starts(with: Data("HTTP/".utf8)) {
            let boundaries = [content.range(of: Data("\r\n\r\n".utf8)), content.range(of: Data("\n\n".utf8))]
                .compactMap { $0 }
            guard let boundary = boundaries.min(by: { $0.lowerBound < $1.lowerBound }),
                let block = String(data: content[..<boundary.lowerBound], encoding: .utf8)
            else { throw PullRequestStatusError.invalidMetadata("The GitHub response headers are incomplete.") }
            let lines = block.split(whereSeparator: \.isNewline)
            guard let first = lines.first,
                let code = first.split(separator: " ").dropFirst().first.flatMap({ Int($0) }),
                (100...599).contains(code)
            else { throw PullRequestStatusError.invalidMetadata("The GitHub response status is invalid.") }
            statusCode = code
            headers = Self.rateHeaders(block)
            content = Data(content[boundary.upperBound...])
        }
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        let diagnosticHeaders = Self.rateHeaders(stderr)
        let retries = [headers["retry-after"], diagnosticHeaders["retry-after"]]
            .compactMap { $0.flatMap { Self.retryDate($0, receivedAt: receivedAt) } }
        let resets = [headers["x-ratelimit-reset"], diagnosticHeaders["x-ratelimit-reset"]]
            .compactMap { $0.flatMap(Self.epochDate) }
        body = content
        exitCode = result.exitCode
        self.statusCode = statusCode
        retryAfter = retries.max()
        resetAt = resets.max()
        remaining = (headers["x-ratelimit-remaining"] ?? diagnosticHeaders["x-ratelimit-remaining"]).flatMap(Int.init)
        diagnostic = stderr
        self.receivedAt = receivedAt
    }

    func sharedFailure(messages: [String] = [], quotaReset: Date? = nil) -> PullRequestStatusError? {
        let detail = ([diagnostic] + messages).joined(separator: "\n").lowercased()
        if exitCode == 4 || statusCode == 401
            || [
                "not logged in", "not authenticated", "authentication required", "authentication failed",
                "unauthenticated", "gh auth login", "http 401", "bad credentials"
            ].contains(where: detail.contains)
        {
            return .unauthenticated
        }
        let limited = ["rate limit", "rate-limit", "rate_limited", "http 429"].contains(where: detail.contains)
        let exhausted = remaining == 0 && (exitCode != 0 || statusCode == 403 || statusCode == 429)
        if limited || exhausted || statusCode == 429 {
            let deadline = [retryAfter, resetAt].compactMap { $0 }.max()
            if !exhausted,
                detail.contains("secondary") || detail.contains("abuse")
                    || ((statusCode == 429 || detail.contains("http 429"))
                        && !detail.contains("api rate limit exceeded"))
            {
                return .secondaryRateLimited(retryAfter: deadline)
            }
            return .rateLimited(
                retryAfter: [deadline, quotaReset].compactMap { $0 }.max()
                    ?? receivedAt.addingTimeInterval(3_600)
            )
        }
        return nil
    }

    func decodingFailure(_ detail: String) -> PullRequestStatusError {
        sharedFailure() ?? retryPause ?? .invalidMetadata(detail)
    }

    private var retryPause: PullRequestStatusError? {
        guard let retryAfter, retryAfter > receivedAt else { return nil }
        return .rateLimited(retryAfter: max(retryAfter, resetAt ?? .distantPast))
    }

    func failure(messages: [String] = []) -> PullRequestStatusError {
        if let shared = sharedFailure(messages: messages) ?? retryPause { return shared }
        let detail = ([diagnostic] + messages).joined(separator: "\n").lowercased()
        if statusCode == 404
            || [
                "default repository", "could not determine repository", "could not resolve to a repository",
                "repository not found", "not a github repository", "not a git repository", "no git remotes",
                "none of the git remotes", "multiple repositories", "ambiguous", "http 404"
            ].contains(where: detail.contains)
        {
            return .repositoryUnavailable(
                "Check repository access and run gh repo set-default <remote> in the Project Repository Root."
            )
        }
        return .providerFailed("The GitHub CLI returned a non-zero exit status.")
    }

    static func failure(_ result: GitHubCommandResult) -> PullRequestStatusError {
        do {
            let response = try GitHubStatusResponse(result)
            return response.failure(messages: [String(decoding: response.body, as: UTF8.self)])
        } catch let error as PullRequestStatusError {
            return error
        } catch {
            return .invalidMetadata("The GitHub response could not be decoded.")
        }
    }

    private static func rateHeaders(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard ["retry-after", "x-ratelimit-reset", "x-ratelimit-remaining"].contains(name) else { continue }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return headers
    }

    private static func epochDate(_ value: String) -> Date? {
        guard let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func retryDate(_ value: String, receivedAt: Date) -> Date? {
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return receivedAt.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}
