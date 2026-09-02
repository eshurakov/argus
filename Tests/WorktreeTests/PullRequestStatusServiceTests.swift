import Foundation
import Testing

@testable import Argus

@Suite
struct PullRequestStatusServiceTests {
    @Test(arguments: [
        "https://GITHUB.example/OWNER/REPO.git", "ssh://git@github.example/owner/repo.git",
        "git@github.example:owner/repo.git"
    ])
    func resolvesActiveRepositoryAgainstFetchURLs(remoteURL: String) async throws {
        let (service, runner) = fixtureService(
            #"{"nameWithOwner":"Owner/Repo","url":"https://GITHUB.example/Owner/Repo"}"#)
        let repository = try await service.resolveRepository(
            repositoryPath: projectPath,
            fetchRemotes: [
                GitFetchRemote(name: "origin", fetchURLs: ["https://github.example/other/repo.git"]),
                GitFetchRemote(name: "upstream", fetchURLs: [remoteURL])
            ])
        #expect(repository == statusRepository)
        let calls = await runner.calls
        #expect(calls.count == 1)
        #expect(calls[0].arguments == ["repo", "view", "--json", "nameWithOwner,url"])
    }

    @Test
    func rejectsUnmatchedDefaultAndInconsistentRepositoryMetadata() async throws {
        let (service, _) = fixtureService(#"{"nameWithOwner":"owner/repo","url":"https://github.example/owner/repo"}"#)
        do {
            _ = try await service.resolveRepository(
                repositoryPath: projectPath,
                fetchRemotes: [
                    GitFetchRemote(name: "push-only", fetchURLs: [])
                ])
            Issue.record("An unverified repository must not resolve")
        } catch let error as PullRequestStatusError {
            guard case .repositoryUnavailable = error else {
                Issue.record("Wrong repository error")
                return
            }
        }
        let (invalid, _) = fixtureService(#"{"nameWithOwner":"other/repo","url":"https://github.example/owner/repo"}"#)
        await expectInvalidMetadata {
            _ = try await invalid.resolveRepository(repositoryPath: projectPath, fetchRemotes: [])
        }
    }

    @Test
    func discoveryUsesBoundedExplicitQueriesAndPreservesActiveEnvironment() async throws {
        let (service, runner) = fixtureService(
            "[\(try payload(["state": "MERGED", "number": 41])),\(try payload())]"
        )
        let association = try #require(try await discover(service))
        #expect(association.identity.number == 42)
        #expect(association.headRepository == statusRepository)
        let calls = await runner.calls
        #expect(
            calls.map(\.arguments) == [
                [
                    "pr", "list", "--repo", "github.example/owner/repo", "--head", "feature/status",
                    "--state", "all", "--limit", "50", "--json", discoveryFields
                ]
            ])
        for call in calls {
            #expect(call.executableURL.path == "/test/gh")
            #expect(call.workingDirectory == projectPath)
            #expect(call.timeout == 30)
            #expect(call.environment["GH_PROMPT_DISABLED"] == "1")
            #expect(call.environment["GH_PAGER"] == "cat")
            #expect(call.environment["NO_COLOR"] == "1")
            #expect(call.environment["GIT_TERMINAL_PROMPT"] == "0")
            #expect(call.environment["GH_CONFIG_DIR"] == "/active-gh")
            #expect(call.environment["GH_HOST"] == "github.example")
        }
    }

    @Test(arguments: [
        ("OPEN", false, PullRequestLifecycle.open), ("OPEN", true, .draft),
        ("MERGED", true, .merged), ("CLOSED", true, .closed)
    ])
    func terminalLifecycleOverridesDraft(state: String, draft: Bool, expected: PullRequestLifecycle) async throws {
        let (service, _) = try fixtureStatusService(["state": state, "isDraft": draft])
        #expect(try await refresh(service).lifecycle == expected)
    }

    @Test(arguments: [
        ("APPROVED", PullRequestReviewDecision.approved), ("CHANGES_REQUESTED", .changesRequested),
        ("REVIEW_REQUIRED", .required), ("", .none), ("FUTURE", .unavailable)
    ])
    func normalizesReviewDecision(value: String, expected: PullRequestReviewDecision) async throws {
        let (service, _) = try fixtureStatusService(["reviewDecision": value])
        #expect(try await refresh(service).review == expected)
    }

    @Test
    func normalizesBothCheckFormsWithoutFalseSuccess() async throws {
        var checks: [[String: Any]] = [
            "SUCCESS", "FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE",
            "NEUTRAL", "SKIPPED", "FUTURE"
        ].map { ["__typename": "CheckRun", "status": "COMPLETED", "conclusion": $0] }
        checks += ["SUCCESS", "ERROR", "FAILURE", "PENDING", "FUTURE"].map {
            ["__typename": "StatusContext", "state": $0]
        }
        checks += [
            ["__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": "SUCCESS"],
            ["__typename": "CheckRun", "conclusion": "SUCCESS"],
            ["__typename": "CheckRun", "status": "COMPLETED"], ["__typename": "FutureCheck", "state": "SUCCESS"]
        ]
        let (service, _) = try fixtureStatusService(["statusCheckRollup": checks])
        let status = try await refresh(service)
        #expect(status.checks == PullRequestChecks(passed: 2, failed: 8, pending: 2, skipped: 2, unknown: 5))
        #expect(status.checks.state == .failed)
        #expect(PullRequestChecks(passed: 1, pending: 1, unknown: 1).state == .pending)
        #expect(PullRequestChecks(passed: 1, unknown: 1).state == .unknown)
        #expect(PullRequestChecks(passed: 1).state == .passed)
        #expect(PullRequestChecks(skipped: 2).state == .none)
        #expect(PullRequestChecks(skipped: 2).summary == "2 skipped/neutral")
    }

    @Test
    func distinguishesNoChecksFromUnavailableAndIncompleteRollups() async throws {
        for (rollup, expected) in [
            (NSNull() as Any, PullRequestChecks()), ([], PullRequestChecks()),
            ([NSNull()], PullRequestChecks(unknown: 1)),
            (
                Array(repeating: ["__typename": "StatusContext", "state": "SUCCESS"], count: 100),
                PullRequestChecks(passed: 100, isAvailable: false)
            )
        ] {
            let (service, _) = try fixtureStatusService(["reviewDecision": NSNull(), "statusCheckRollup": rollup])
            let status = try await refresh(service)
            #expect(status.review == .none)
            #expect(status.checks == expected)
        }
        #expect(PullRequestChecks().summary == "No checks")
        #expect(PullRequestChecks.unavailable.state == .unknown)
    }
}

extension PullRequestStatusServiceTests {
    @Test(arguments: [
        "upstream", "exactHead", "previous", "unverified", "wrongPreviousBranch", "wrongPreviousRepository"
    ])
    func verifiesForkAssociation(scenario: String) async throws {
        let fork = RepositoryIdentity(provider: .github, host: "github.example", owner: "fork", repositoryName: "repo")
        let output = try payload([
            "headRepositoryOwner": ["login": "fork", "name": "Display Name"], "isCrossRepository": true
        ])
        let (service, runner) = fixtureService("[\(output)]", output)
        let previous =
            scenario.contains("Previous") || scenario == "previous"
            ? knownStatus(
                branch: scenario == "wrongPreviousBranch" ? "different" : "feature/status",
                repository: scenario == "wrongPreviousRepository" ? fork : statusRepository, headRepository: fork)
            : nil
        let branch = PullRequestBranchContext(
            branchName: "feature/status", headCommitObjectID: scenario == "exactHead" ? statusHead : nextHead,
            upstreamRepository: scenario == "upstream" ? fork : nil
        )
        if ["unverified", "wrongPreviousBranch", "wrongPreviousRepository"].contains(scenario) {
            await #expect(throws: PullRequestStatusError.unverifiedAssociation) {
                try await discover(service, branch: branch, previous: previous)
            }
            #expect(await runner.calls.count == 1)
        } else {
            #expect(try await discover(service, branch: branch, previous: previous)?.headRepository == fork)
        }
    }

    @Test(arguments: ["closed", "merged", "previous", "reused", "ambiguous", "newOpen"])
    func selectsTerminalCandidatesWithoutAttachingReusedBranches(scenario: String) async throws {
        let terminal = try payload(["state": scenario == "closed" ? "CLOSED" : "MERGED"])
        let extra =
            scenario == "ambiguous" || scenario == "newOpen"
            ? ",\(try payload(["number": 43, "state": scenario == "newOpen" ? "OPEN" : "CLOSED"]))" : ""
        let (service, _) = fixtureService(
            "[\(terminal)\(extra)]", scenario == "newOpen" ? try payload(["number": 43]) : terminal)
        let branch = PullRequestBranchContext(
            branchName: "feature/status",
            headCommitObjectID: scenario == "reused" || scenario == "previous" ? nextHead : statusHead,
            upstreamRepository: nil
        )
        let previous = ["previous", "newOpen"].contains(scenario) ? knownStatus() : nil
        if scenario == "ambiguous" || scenario == "reused" {
            await #expect(throws: scenario == "ambiguous" ? PullRequestStatusError.ambiguous : .unverifiedAssociation) {
                try await discover(service, branch: branch, previous: previous)
            }
        } else {
            #expect(
                try await discover(service, branch: branch, previous: previous)?.identity.number
                    == (scenario == "newOpen" ? 43 : 42))
        }
    }

    @Test
    func rejectsMultipleOpenCandidatesAndTruncatedDiscovery() async throws {
        let (service, _) = fixtureService("[\(try payload()),\(try payload(["number": 43, "isDraft": true]))]")
        await #expect(throws: PullRequestStatusError.ambiguous) { try await discover(service) }
        for count in [50, 51] {
            let list = try (1...count).map { try payload(["number": $0]) }.joined(separator: ",")
            let (limited, runner) = fixtureService("[\(list)]")
            await #expect(throws: PullRequestStatusError.lookupLimit) { try await discover(limited) }
            #expect(await runner.calls.count == 1)
        }
    }

    @Test
    func completeNonmatchesNeverIssueAViewQuery() async throws {
        for output in ["[]", "[\(try payload(["headRefName": "other-branch"]))]"] {
            let (service, runner) = fixtureService(output)
            #expect(try await discover(service, previous: knownStatus()) == nil)
            #expect(await runner.calls.count == 1)
        }
        let (service, _) = fixtureService("[\(try payload())]")
        let other = RepositoryIdentity(
            provider: .github, host: "github.example", owner: "other", repositoryName: "repo")
        let branch = PullRequestBranchContext(
            branchName: "feature/status", headCommitObjectID: statusHead, upstreamRepository: other)
        #expect(try await discover(service, branch: branch) == nil)
    }

    @Test
    func validatesCoreMetadataAndPinsRefreshedIdentityAndBranch() async throws {
        for changes: [String: Any] in [
            ["number": 43], ["number": 0], ["number": -1], ["state": "FUTURE"], ["state": NSNull()], ["title": " "],
            ["url": "https://github.example/other/repo/pull/42"],
            ["url": "https://secret@github.example/owner/repo/pull/42"],
            ["url": "https://github.example/owner/repo/pull/42?token=secret"], ["headRefName": "other"],
            ["headRefOid": "not-a-commit"], ["baseRefName": "bad branch"],
            ["headRepository": ["name": "other"]], ["headRepository": ["name": "repo", "nameWithOwner": "other/repo"]]
        ] {
            let (service, _) = try fixtureStatusService(changes)
            await expectInvalidMetadata {
                _ = try await refresh(service)
            }
        }
        let (service, _) = fixtureService("[\(try payload(["url": "https://github.example/other/repo/pull/42"]))]")
        await expectInvalidMetadata { _ = try await discover(service) }
        let (changed, _) = try fixtureStatusService(["headRefName": "different"])
        await expectInvalidMetadata { _ = try await refresh(changed) }
        let (pushed, _) = try fixtureStatusService(["headRefOid": nextHead])
        let refreshed = try await refresh(pushed)
        #expect(refreshed.headCommitObjectID == nextHead)
    }
}

extension PullRequestStatusServiceTests {
    @Test(arguments: ["reviewDecision", "commits"])
    func optionalFieldErrorsDoNotIssueFallbackRequests(field: String) async throws {
        let json = try batchPayload(
            [payload(["reviewDecision": "APPROVED"])],
            errors: [["message": "Resource not accessible by integration", "path": ["pr0", "pullRequest", field]]]
        )
        let runner = StatusCommandRunner([
            GitHubCommandResult(stdout: Data(json.utf8), stderr: Data(), exitCode: 1)
        ])
        let status = try await refresh(makeService(runner))
        #expect(status.review == (field == "reviewDecision" ? .unavailable : .approved))
        #expect(status.checks == (field == "commits" ? .unavailable : PullRequestChecks()))
        #expect(await runner.calls.count == 1)
    }

    @Test(arguments: [
        ("HTTP 401: Bad credentials", PullRequestStatusError.unauthenticated),
        (
            "API rate limit exceeded\nX-RateLimit-Reset: 2000000000",
            .rateLimited(retryAfter: Date(timeIntervalSince1970: 2_000_000_000))
        ),
        ("error connecting to host", .providerFailed("The GitHub CLI returned a non-zero exit status.")),
        (
            "Unknown JSON field: \"title\". Available fields: reviewDecision,statusCheckRollup",
            .providerFailed("The GitHub CLI returned a non-zero exit status.")
        ),
        (
            "error connecting to host: Resource not accessible (repository.pullRequest.statusCheckRollup)",
            .providerFailed("The GitHub CLI returned a non-zero exit status.")
        )
    ])
    func failuresNeverBecomeSuccessfulFallbacks(message: String, expected: PullRequestStatusError) async throws {
        let runner = StatusCommandRunner([failure(message)])
        await #expect(throws: expected) {
            try await refresh(makeService(runner))
        }
        #expect(await runner.calls.count == 1)
    }

    @Test
    func respectsRetryAfterAndNeverReflectsProviderSecrets() async throws {
        let runner = StatusCommandRunner([failure("HTTP 429: rate limit exceeded\nRetry-After: 60")])
        let started = Date()
        do {
            _ = try await refresh(makeService(runner))
            Issue.record("Expected rate limiting")
        } catch let error as PullRequestStatusError {
            guard let deadline = error.pauseDeadline else {
                Issue.record("Missing retry deadline")
                return
            }
            #expect(deadline >= started.addingTimeInterval(60))
            #expect(deadline <= Date().addingTimeInterval(60))
        }
        let secret =
            "Authorization: Bearer opaque-secret\nCookie: opaque-secret\nGH_TOKEN=opaque-secret\nghp_test-secret"
        let secretRunner = StatusCommandRunner([
            GitHubCommandResult(stdout: Data(secret.utf8), stderr: Data(), exitCode: 1)
        ])
        await #expect(throws: PullRequestStatusError.providerFailed("The GitHub CLI returned a non-zero exit status."))
        {
            try await discover(makeService(secretRunner))
        }
        let (malformed, _) = fixtureService(secret)
        await expectInvalidMetadata { _ = try await discover(malformed) }
    }

    @Test
    func enforcesStreamBoundsAndRunnerFailureCategories() async throws {
        for oversizedStdout in [true, false] {
            let huge = Data(repeating: 65, count: 1_048_577)
            let runner = StatusCommandRunner([
                GitHubCommandResult(
                    stdout: oversizedStdout ? huge : Data("[]".utf8), stderr: oversizedStdout ? Data() : huge,
                    exitCode: 0
                )
            ])
            await expectInvalidMetadata { _ = try await discover(makeService(runner)) }
        }
        for (failure, expected) in [
            (GitHubCommandRunnerError.timedOut, PullRequestStatusError.providerTimedOut),
            (.launchFailed("opaque-secret"), .githubCLIUnavailable),
            (.outputTooLarge, .invalidMetadata("GitHub CLI output exceeded the 1 MiB safety limit."))
        ] {
            let runner = ClosureGitHubCommandRunner { _, _, _, _, _ in throw failure }
            await #expect(throws: expected) { try await discover(makeService(runner)) }
        }
    }

    @Test
    func missingCLIAndCancellationDoNotPublishNoMatch() async throws {
        let runner = StatusCommandRunner([])
        let missing = GitHubPullRequestService(
            commandRunner: runner, executableSearchPaths: [URL(fileURLWithPath: "/missing/gh")])
        await #expect(throws: PullRequestStatusError.githubCLIUnavailable) { try await discover(missing) }
        #expect(await runner.calls.isEmpty)
        for preCancelled in [true, false] {
            let task = Task {
                if preCancelled { withUnsafeCurrentTask { $0?.cancel() } }
                let cancelling = ClosureGitHubCommandRunner { _, _, _, _, _ in
                    #expect(!preCancelled)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return success("[]")
                }
                return try await discover(makeService(cancelling))
            }
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        let cancelled = ClosureGitHubCommandRunner { _, _, _, _, _ in throw GitHubCommandRunnerError.cancelled }
        await #expect(throws: CancellationError.self) { try await discover(makeService(cancelled)) }
    }

    @Test
    func sharedBoundaryPreservesIntake() async throws {
        let (service, runner) = fixtureService(try payload())
        let metadata = try await service.resolve(.number(42), repositoryPath: projectPath)
        #expect(metadata.headCommitObjectID == statusHead)
        #expect(metadata.headBranchName == "feature/status")
        #expect(
            await runner.calls.first?.arguments == [
                "pr", "view", "42", "--json",
                "number,title,url,headRefName,headRefOid,headRepository,headRepositoryOwner,isCrossRepository"
            ])
    }
}
