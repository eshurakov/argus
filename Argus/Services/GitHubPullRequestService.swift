import Darwin
import Foundation

// The command runner and provider service are kept together as one boundary.
// swiftlint:disable file_length

/// Result returned by the bounded GitHub CLI command boundary.
struct GitHubCommandResult: Equatable, Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

enum GitHubCommandRunnerError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut
    case cancelled
    case outputTooLarge
}

protocol GitHubCommandRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: String,
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> GitHubCommandResult
}

/// A closure adapter keeps provider tests small without weakening the
/// production command boundary.
struct ClosureGitHubCommandRunner: GitHubCommandRunning {
    typealias Operation =
        @Sendable (
            _ executableURL: URL,
            _ arguments: [String],
            _ workingDirectory: String,
            _ environment: [String: String],
            _ timeout: TimeInterval
        ) async throws -> GitHubCommandResult

    let operation: Operation

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: String,
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> GitHubCommandResult {
        try await operation(executableURL, arguments, workingDirectory, environment, timeout)
    }
}

/// Production GitHub CLI runner. Both output streams are drained repeatedly,
/// bounded, and never read by waiting for one pipe to close first.
final class ProcessGitHubCommandRunner: GitHubCommandRunning, @unchecked Sendable {
    private static let outputLimit = 1_048_576

    // swiftlint:disable:next function_body_length
    func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: String,
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> GitHubCommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw GitHubCommandRunnerError.launchFailed(error.localizedDescription)
        }
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let reader = BoundedGitHubOutputReader(
            stdout: stdout,
            stderr: stderr,
            limit: Self.outputLimit
        )
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning || !reader.isFinished {
            if Task.isCancelled {
                await stop(process)
                reader.close()
                throw GitHubCommandRunnerError.cancelled
            }

            reader.drain()
            if reader.exceededLimit {
                await stop(process)
                reader.close()
                throw GitHubCommandRunnerError.outputTooLarge
            }
            if Date() >= deadline {
                await stop(process)
                reader.close()
                throw GitHubCommandRunnerError.timedOut
            }

            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                await stop(process)
                reader.close()
                throw GitHubCommandRunnerError.cancelled
            }
        }

        reader.drain()
        let output = reader.output
        reader.close()
        return GitHubCommandResult(
            stdout: output.stdout,
            stderr: output.stderr,
            exitCode: process.terminationStatus
        )
    }

    private func stop(_ process: Process) async {
        if process.isRunning {
            process.terminate()
        }
        let terminationDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < terminationDeadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        while process.isRunning {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}

private final class BoundedGitHubOutputReader {
    private let stdoutReader: BoundedGitHubPipeReader
    private let stderrReader: BoundedGitHubPipeReader

    init(stdout: Pipe, stderr: Pipe, limit: Int) {
        stdoutReader = BoundedGitHubPipeReader(fileHandle: stdout.fileHandleForReading, limit: limit)
        stderrReader = BoundedGitHubPipeReader(fileHandle: stderr.fileHandleForReading, limit: limit)
    }

    var isFinished: Bool {
        stdoutReader.isFinished && stderrReader.isFinished
    }

    var exceededLimit: Bool {
        stdoutReader.exceededLimit || stderrReader.exceededLimit
    }

    func drain() {
        stdoutReader.drain()
        stderrReader.drain()
    }

    func close() {
        stdoutReader.close()
        stderrReader.close()
    }

    var output: (stdout: Data, stderr: Data) {
        (stdoutReader.data, stderrReader.data)
    }
}

private final class BoundedGitHubPipeReader {
    private var fileDescriptor: Int32
    private let limit: Int
    private(set) var data = Data()
    private(set) var isFinished = false
    private(set) var exceededLimit = false

    init(fileHandle: FileHandle, limit: Int) {
        self.limit = limit
        fileDescriptor = Darwin.dup(fileHandle.fileDescriptor)
        try? fileHandle.close()
        guard fileDescriptor >= 0 else {
            isFinished = true
            return
        }

        let flags = Darwin.fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0, Darwin.fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            close()
            return
        }
    }

    deinit {
        close()
    }

    func drain() {
        guard !isFinished else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                let remaining = limit - data.count
                if count > remaining {
                    if remaining > 0 {
                        data.append(buffer, count: remaining)
                    }
                    exceededLimit = true
                } else {
                    data.append(buffer, count: count)
                }
            } else if count == 0 {
                close()
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                close()
                return
            }
        }
    }

    func close() {
        guard !isFinished else { return }
        isFinished = true
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
    }
}

/// Resolves Pull Requests through the active GitHub CLI authentication
/// context. It is deliberately a service rather than a SwiftUI concern.
final class GitHubPullRequestService: Sendable {
    private static let timeout: TimeInterval = 30
    private static let jsonFields =
        "number,title,url,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository"

    let commandRunner: any GitHubCommandRunning
    private let processEnvironment: [String: String]
    private let executableSearchPaths: [URL]
    private let executableURLOverride: URL?

    init(
        commandRunner: any GitHubCommandRunning = ProcessGitHubCommandRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableSearchPaths: [URL]? = nil,
        executableURL: URL? = nil
    ) {
        self.commandRunner = commandRunner
        self.processEnvironment = environment
        self.executableSearchPaths = executableSearchPaths ?? Self.searchPaths(environment: environment)
        self.executableURLOverride = executableURL
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func resolve(
        _ input: PullRequestInput,
        repositoryPath: String
    ) async throws -> PullRequestWorkspaceMetadata {
        guard let requestedNumber = input.number else {
            throw PullRequestWorkspaceError.malformedInput(
                "Use a positive number or an HTTPS GitHub Pull Request URL."
            )
        }
        if Task.isCancelled {
            throw PullRequestWorkspaceError.cancelled
        }

        guard let executableURL = executableURLOverride ?? locateExecutable() else {
            throw PullRequestWorkspaceError.githubCLIUnavailable
        }

        let environment = processEnvironment.merging([
            "GH_PROMPT_DISABLED": "1",
            "GH_PAGER": "cat",
            "NO_COLOR": "1",
            "GIT_TERMINAL_PROMPT": "0"
        ]) { _, new in new }

        let result: GitHubCommandResult
        do {
            result = try await commandRunner.run(
                executableURL: executableURL,
                arguments: [
                    "pr", "view", input.providerArgument,
                    "--json", Self.jsonFields
                ],
                workingDirectory: repositoryPath,
                environment: environment,
                timeout: Self.timeout
            )
        } catch GitHubCommandRunnerError.timedOut {
            throw PullRequestWorkspaceError.providerTimedOut
        } catch GitHubCommandRunnerError.cancelled {
            throw PullRequestWorkspaceError.cancelled
        } catch GitHubCommandRunnerError.outputTooLarge {
            throw PullRequestWorkspaceError.metadataUnavailable(
                "GitHub CLI output exceeded the 1 MiB safety limit."
            )
        } catch GitHubCommandRunnerError.launchFailed {
            throw PullRequestWorkspaceError.githubCLIUnavailable
        } catch {
            throw PullRequestWorkspaceError.providerCommandFailed(
                Self.safeDetail(error.localizedDescription)
            )
        }

        guard result.stdout.count <= 1_048_576, result.stderr.count <= 1_048_576 else {
            throw PullRequestWorkspaceError.metadataUnavailable(
                "GitHub CLI output exceeded the 1 MiB safety limit."
            )
        }

        guard result.exitCode == 0 else {
            throw Self.classifyFailure(
                input: input,
                stderr: result.stderr,
                stdout: result.stdout
            )
        }

        let response: GitHubPullRequestResponse
        do {
            response = try JSONDecoder().decode(
                GitHubPullRequestResponse.self,
                from: result.stdout
            )
        } catch {
            throw PullRequestWorkspaceError.metadataUnavailable(
                "The GitHub CLI returned malformed JSON."
            )
        }

        guard response.number == requestedNumber else {
            throw PullRequestWorkspaceError.invalidMetadata(
                "The returned Pull Request number did not match the request."
            )
        }

        let canonicalURL: URL
        guard let url = URL(string: response.url) else {
            throw PullRequestWorkspaceError.invalidMetadata(
                "The returned Pull Request URL is invalid."
            )
        }
        canonicalURL = url

        guard let baseRepository = RepositoryIdentity.github(fromPullRequestURL: canonicalURL),
            let metadataInput = try? PullRequestInput.parse(canonicalURL.absoluteString),
            metadataInput.number == response.number
        else {
            throw PullRequestWorkspaceError.invalidMetadata(
                "The returned Pull Request URL is not a canonical HTTPS GitHub Pull Request URL."
            )
        }

        if let requestedRepository = input.repositoryIdentity,
            requestedRepository != baseRepository
        {
            throw PullRequestWorkspaceError.invalidMetadata(
                "The returned Pull Request belongs to a different repository than the URL input."
            )
        }

        let headRepository = Self.headRepositoryIdentity(from: response, host: baseRepository.host)
        let pullRequest = PullRequestIdentity(
            repository: baseRepository,
            number: response.number
        )
        return try PullRequestWorkspaceMetadata(
            pullRequest: pullRequest,
            canonicalURL: canonicalURL,
            title: response.title,
            baseRepository: baseRepository,
            headRepository: headRepository,
            headBranchName: response.headRefName,
            headCommitObjectID: response.headRefOid,
            isCrossRepository: response.isCrossRepository
        )
    }

    private func locateExecutable() -> URL? {
        executableSearchPaths.first { path in
            FileManager.default.isExecutableFile(atPath: path.path)
        }
    }

    private static func searchPaths(environment: [String: String]) -> [URL] {
        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { entry in
                let directory = entry.isEmpty ? "." : String(entry)
                return URL(fileURLWithPath: directory).appendingPathComponent("gh")
            }
        var candidates =
            pathEntries + [
                URL(fileURLWithPath: "/opt/homebrew/bin/gh"),
                URL(fileURLWithPath: "/usr/local/bin/gh")
            ]
        var seen = Set<String>()
        candidates.removeAll { !seen.insert($0.standardizedFileURL.path).inserted }
        return candidates
    }

    private static func classifyFailure(
        input: PullRequestInput,
        stderr: Data,
        stdout: Data
    ) -> PullRequestWorkspaceError {
        let rawDetail =
            String(data: stderr, encoding: .utf8)
            ?? String(data: stdout, encoding: .utf8)
            ?? ""
        let detail = safeDetail(rawDetail)
        let lowercased = detail.lowercased()

        if lowercased.contains("not logged in")
            || lowercased.contains("not authenticated")
            || lowercased.contains("authentication required")
            || lowercased.contains("authentication failed")
            || lowercased.contains("gh auth login")
        {
            return .unauthenticated(host: input.hostHint)
        }

        if input.number != nil,
            lowercased.contains("default repository")
                || lowercased.contains("could not determine repository")
                || lowercased.contains("ambiguous")
                || lowercased.contains("multiple repositories")
        {
            return .ambiguousDefaultRepository
        }

        return .providerCommandFailed(
            detail.isEmpty ? "The GitHub CLI returned a non-zero exit status." : detail
        )
    }

    private static func headRepositoryIdentity(
        from response: GitHubPullRequestResponse,
        host: String
    ) -> RepositoryIdentity? {
        guard let repositoryName = response.headRepository?.value,
            let owner = response.headRepositoryOwner?.value
                ?? response.headRepository?.owner?.value,
            !repositoryName.isEmpty,
            !owner.isEmpty
        else { return nil }
        return RepositoryIdentity(
            provider: .github,
            host: host,
            owner: owner,
            repositoryName: repositoryName
        )
    }

    private static func safeDetail(_ raw: String) -> String {
        let lines =
            raw
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { line in
                let lowercased = line.lowercased()
                return !lowercased.contains("authorization")
                    && !lowercased.contains("password")
                    && !lowercased.contains("environment")
            }
        var detail = lines.joined(separator: " ")
        for prefix in ["ghp_", "gho_", "ghs_", "ghu_", "ghr_", "github_pat_"] {
            while let range = detail.range(of: prefix) {
                let suffix = detail[range.upperBound...]
                let tokenEnd = suffix.firstIndex(where: { $0.isWhitespace }) ?? suffix.endIndex
                detail.replaceSubrange(range.lowerBound..<tokenEnd, with: "[redacted]")
            }
        }
        return String(detail.prefix(500))
    }
}

private struct GitHubPullRequestResponse: Decodable {
    let number: Int
    let title: String
    let url: String
    let headRefName: String
    let headRefOid: String
    let headRepository: GitHubNamedValue?
    let headRepositoryOwner: GitHubNamedValue?
    let isCrossRepository: Bool
}

private struct GitHubNamedValue: Decodable {
    let name: String?
    let login: String?
    let owner: GitHubOwnerValue?

    var value: String? { name ?? login }

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            name = nil
            login = nil
            owner = nil
            return
        }
        if let value = try? single.decode(String.self) {
            name = value
            login = value
            owner = nil
            return
        }

        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        name = try keyed.decodeIfPresent(String.self, forKey: .name)
        login = try keyed.decodeIfPresent(String.self, forKey: .login)
        owner = try keyed.decodeIfPresent(GitHubOwnerValue.self, forKey: .owner)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case login
        case owner
    }
}

private struct GitHubOwnerValue: Decodable {
    let name: String?
    let login: String?

    var value: String? { name ?? login }

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            name = nil
            login = nil
            return
        }
        if let value = try? single.decode(String.self) {
            name = value
            login = value
            return
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        name = try keyed.decodeIfPresent(String.self, forKey: .name)
        login = try keyed.decodeIfPresent(String.self, forKey: .login)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case login
    }
}
