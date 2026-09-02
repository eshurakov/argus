import Foundation
import Testing

@testable import Argus

let projectPath = "/Project Repository Root"
let statusHead = String(repeating: "a", count: 40)
let nextHead = String(repeating: "b", count: 40)
let statusRepository = RepositoryIdentity(
    provider: .github, host: "github.example", owner: "owner", repositoryName: "repo")
let discoveryFields =
    "number,title,url,state,isDraft,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository"

func payload(_ changes: [String: Any] = [:], removing: [String] = []) throws -> String {
    let number = changes["number"] as? Int ?? 42
    var fields: [String: Any] = [
        "number": number, "title": "Pull Request title", "url": "https://github.example/owner/repo/pull/\(number)",
        "state": "OPEN", "isDraft": false, "headRefName": "feature/status", "headRefOid": statusHead,
        "headRepository": ["name": "repo"], "headRepositoryOwner": ["login": "owner"], "isCrossRepository": false,
        "baseRefName": "main", "reviewDecision": "", "statusCheckRollup": []
    ]
    fields.merge(changes) { _, new in new }
    for key in removing { fields.removeValue(forKey: key) }
    return String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
}

func batchPayload(
    _ payloads: [String], errors: [[String: Any]] = [],
    quota: [String: Any]? = ["cost": 1, "remaining": 4_999, "resetAt": "2033-05-18T03:33:20Z"]
) throws -> String {
    var data: [String: Any] = [:]
    data["rateLimit"] = quota
    for (index, json) in payloads.enumerated() {
        var fields = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        if let checks = fields.removeValue(forKey: "statusCheckRollup"), fields["commits"] == nil {
            let rollup: Any =
                checks is NSNull
                ? NSNull() : ["contexts": ["nodes": checks, "pageInfo": ["hasNextPage": false]]]
            fields["commits"] = ["nodes": [["commit": ["statusCheckRollup": rollup]]]]
        }
        if var head = fields["headRepository"] as? [String: Any], head["owner"] == nil {
            head["owner"] = fields["headRepositoryOwner"]
            fields["headRepository"] = head
        }
        fields.removeValue(forKey: "headRepositoryOwner")
        data["pr\(index)"] = ["pullRequest": fields]
    }
    let envelope: [String: Any] = ["data": data, "errors": errors]
    return String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
}

func knownStatus(
    branch: String = "feature/status", repository: RepositoryIdentity = statusRepository,
    headRepository: RepositoryIdentity = statusRepository
) -> PullRequestStatus {
    PullRequestStatus(
        identity: PullRequestIdentity(repository: repository, number: 42),
        url: URL(string: "https://github.example/owner/repo/pull/42")!, title: "Pull Request title",
        headBranchName: branch, headCommitObjectID: statusHead, headRepository: headRepository,
        baseBranchName: "main", lifecycle: .open, review: .none, checks: PullRequestChecks()
    )
}

func discover(
    _ service: GitHubPullRequestService,
    branch: PullRequestBranchContext = PullRequestBranchContext(
        branchName: "feature/status", headCommitObjectID: nextHead, upstreamRepository: nil),
    previous: PullRequestStatus? = nil
) async throws -> PullRequestAssociation? {
    try await service.discoverPullRequest(
        repository: statusRepository, branch: branch, previous: previous, repositoryPath: projectPath)
}

func refresh(_ service: GitHubPullRequestService) async throws -> PullRequestStatus {
    let previous = knownStatus()
    let batch = try await service.refreshPullRequests([previous.identity], repositoryPath: projectPath)
    let status = try #require(batch.results[previous.identity]).get()
    try PullRequestAssociation(previous).validate(status)
    return status
}

func success(_ json: String) -> GitHubCommandResult {
    GitHubCommandResult(stdout: Data(json.utf8), stderr: Data(), exitCode: 0)
}

func failure(_ message: String) -> GitHubCommandResult {
    GitHubCommandResult(stdout: Data(), stderr: Data(message.utf8), exitCode: 1)
}

func fixtureService(_ outputs: String...) -> (GitHubPullRequestService, StatusCommandRunner) {
    let runner = StatusCommandRunner(outputs.map(success))
    return (makeService(runner), runner)
}

func fixtureStatusService(_ changes: [String: Any] = [:]) throws -> (GitHubPullRequestService, StatusCommandRunner) {
    fixtureService(try batchPayload([payload(changes)]))
}

func makeService(_ runner: any GitHubCommandRunning) -> GitHubPullRequestService {
    GitHubPullRequestService(
        commandRunner: runner,
        environment: [
            "PATH": "/missing", "GH_CONFIG_DIR": "/active-gh", "GH_HOST": "github.example",
            "GH_PROMPT_DISABLED": "0", "GH_PAGER": "less", "NO_COLOR": "0", "GIT_TERMINAL_PROMPT": "1",
            "GH_DEBUG": "api", "DEBUG": "1"
        ],
        executableURL: URL(fileURLWithPath: "/test/gh")
    )
}

func expectInvalidMetadata(_ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Invalid metadata was accepted")
    } catch let error as PullRequestStatusError {
        if case .invalidMetadata = error { return }
        Issue.record("Expected an invalid metadata error")
    } catch {
        Issue.record("Expected a typed provider error")
    }
}

actor StatusCommandRunner: GitHubCommandRunning {
    struct Call: Sendable {
        let executableURL: URL
        let arguments: [String]
        let workingDirectory: String
        let environment: [String: String]
        let timeout: TimeInterval
    }
    private var results: [GitHubCommandResult]
    private(set) var calls = [Call]()

    init(_ results: [GitHubCommandResult]) { self.results = results }

    func run(
        executableURL: URL, arguments: [String], workingDirectory: String,
        environment: [String: String], timeout: TimeInterval
    ) async throws -> GitHubCommandResult {
        calls.append(
            Call(
                executableURL: executableURL, arguments: arguments, workingDirectory: workingDirectory,
                environment: environment, timeout: timeout))
        guard !results.isEmpty else {
            Issue.record("Unexpected provider command")
            throw GitHubCommandRunnerError.cancelled
        }
        return results.removeFirst()
    }
}
