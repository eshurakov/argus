import Foundation
import Testing

@testable import Argus

@Suite
struct PullRequestStatusBatchServiceTests {
    @Test
    func batchesMultiplePullRequestsAcrossRepositoriesInOneHostCommand() async throws {
        let other = RepositoryIdentity(provider: .github, host: "github.example", owner: "true", repositoryName: "123")
        let identities = [knownStatus().identity, PullRequestIdentity(repository: other, number: 7)]
        let json = try batchPayload([
            payload(),
            payload([
                "number": 7, "url": "https://github.example/true/123/pull/7",
                "headRepository": ["name": "123"], "headRepositoryOwner": ["login": "true"]
            ])
        ])
        let (service, runner) = fixtureService(json)
        let batch = try await service.refreshPullRequests(identities, repositoryPath: projectPath)
        #expect(batch.results.count == 2)
        #expect(try batch.results[identities[0]]?.get().identity == identities[0])
        #expect(try batch.results[identities[1]]?.get().identity == identities[1])
        #expect(
            batch.quota
                == PullRequestStatusQuota(
                    cost: 1, remaining: 4_999, resetAt: Date(timeIntervalSince1970: 2_000_000_000)))
        let calls = await runner.calls
        let call = try #require(calls.first)
        #expect(calls.count == 1)
        #expect(
            Array(call.arguments.prefix(6)) == [
                "api", "graphql", "--hostname", "github.example", "--include", "--raw-field"
            ])
        let query = try #require(call.arguments.first { $0.hasPrefix("query=") })
        #expect(query.contains("rateLimit { cost remaining resetAt }"))
        #expect(query.contains("pr0:repository(owner:$owner0,name:$name0)"))
        #expect(query.contains("pr1:repository(owner:$owner1,name:$name1)"))
        #expect(query.contains("commits(last:1)"))
        #expect(query.contains("contexts(first:100)"))
        #expect(query.contains("pageInfo { hasNextPage }"))
        #expect(query.contains("... on CheckRun { status conclusion }"))
        #expect(query.contains("... on StatusContext { state }"))
        #expect(!query.contains("true"))
        #expect(!query.contains("123"))
        #expect(
            Array(call.arguments.suffix(6)) == [
                "--raw-field", "owner1=true", "--raw-field", "name1=123", "--field", "number1=7"
            ])
        #expect(call.workingDirectory == projectPath)
        #expect(call.timeout == 30)
        #expect(call.executableURL.path == "/test/gh")
        #expect(call.environment["GH_CONFIG_DIR"] == "/active-gh")
        #expect(call.environment["GH_DEBUG"] == nil)
        #expect(call.environment["DEBUG"] == nil)
        #expect(call.environment["GH_PROMPT_DISABLED"] == "1")
        #expect(call.environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(call.environment["GH_PAGER"] == "cat")
        #expect(call.environment["NO_COLOR"] == "1")
    }

    @Test
    func rejectsInvalidMixedHostAndOversizedBatchesWithoutACommand() async throws {
        let invalidRepositories = [
            RepositoryIdentity(provider: .github, host: "other.example", owner: "owner", repositoryName: "repo"),
            RepositoryIdentity(
                provider: .github, host: "github.example --verbose", owner: "owner", repositoryName: "repo"),
            RepositoryIdentity(
                provider: .github, host: "github.example", owner: "owner\") { viewer { login } }",
                repositoryName: "repo"),
            RepositoryIdentity(provider: .github, host: "github.example", owner: "owner", repositoryName: "repo\nquery")
        ]
        var requests: [[PullRequestIdentity]] = [
            [], (1...21).map { PullRequestIdentity(repository: statusRepository, number: $0) }
        ]
        requests += invalidRepositories.map { [knownStatus().identity, PullRequestIdentity(repository: $0, number: 1)] }
        requests += [0, -1, Int(Int32.max) + 1].map { [PullRequestIdentity(repository: statusRepository, number: $0)] }
        for identities in requests {
            let runner = StatusCommandRunner([])
            await expectInvalidMetadata {
                _ = try await makeService(runner).refreshPullRequests(identities, repositoryPath: projectPath)
            }
            #expect(await runner.calls.isEmpty)
        }
    }

    @Test
    func supportsTheBatchBoundAndDeduplicatesRepeatedIdentities() async throws {
        let identities = (1...20).map { PullRequestIdentity(repository: statusRepository, number: $0) }
        let (service, runner) = fixtureService(try batchPayload((1...20).map { try payload(["number": $0]) }))
        let batch = try await service.refreshPullRequests(identities + [identities[0]], repositoryPath: projectPath)
        #expect(batch.results.count == 20)
        #expect(await runner.calls.count == 1)
        let query = try #require(await runner.calls.first?.arguments.first { $0.hasPrefix("query=") })
        #expect(query.contains("pr19:repository"))
        #expect(!query.contains("pr20:repository"))
    }

    @Test
    func scopesPartialErrorsToTheirAliasesAndFieldsWithoutFallbacks() async throws {
        let identities = (1...4).map { PullRequestIdentity(repository: statusRepository, number: $0) }
        let errors: [[String: Any]] = [
            [
                "message": "Resource not accessible",
                "path": ["pr0", "pullRequest", "commits", "nodes", 0, "commit", "statusCheckRollup"]
            ],
            ["message": "Resource not accessible", "path": ["pr1", "pullRequest", "reviewDecision"]],
            ["message": "Resource not accessible", "path": ["pr2", "pullRequest", "headRefOid"]]
        ]
        let json = try batchPayload(
            (1...4).map { try payload(["number": $0, "reviewDecision": "APPROVED"]) }, errors: errors)
        let runner = StatusCommandRunner([GitHubCommandResult(stdout: Data(json.utf8), stderr: Data(), exitCode: 1)])
        let result = try await makeService(runner).refreshPullRequests(identities, repositoryPath: projectPath)
        #expect(try result.results[identities[0]]?.get().checks == .unavailable)
        #expect(try result.results[identities[0]]?.get().review == .approved)
        #expect(try result.results[identities[1]]?.get().review == .unavailable)
        #expect(try result.results[identities[1]]?.get().checks == PullRequestChecks())
        await expectInvalidMetadata { _ = try result.results[identities[2]]?.get() }
        #expect(try result.results[identities[3]]?.get().review == .approved)
        #expect(try result.results[identities[3]]?.get().checks == PullRequestChecks())
        #expect(await runner.calls.count == 1)
    }

    @Test
    func nullOrMalformedAliasesDoNotCorruptHealthySiblings() async throws {
        let identity = knownStatus().identity
        let other = PullRequestIdentity(repository: statusRepository, number: 43)
        for unavailable: Any in [NSNull(), ["pullRequest": NSNull()], ["pullRequest": ["number": 42]]] {
            let json = try batchPayload([payload(), payload(["number": 43])])
            var envelope = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            var data = try #require(envelope["data"] as? [String: Any])
            data["pr0"] = unavailable
            envelope["data"] = data
            let runner = StatusCommandRunner([
                GitHubCommandResult(
                    stdout: try JSONSerialization.data(withJSONObject: envelope), stderr: Data(), exitCode: 0)
            ])
            let result = try await makeService(runner).refreshPullRequests(
                [identity, other], repositoryPath: projectPath)
            await expectInvalidMetadata { _ = try result.results[identity]?.get() }
            #expect(try result.results[other]?.get().identity == other)
            #expect(await runner.calls.count == 1)
        }
    }

    @Test
    func missingOrMalformedQuotaIsAnExplicitEnvelopeFailure() async throws {
        let quotas: [[String: Any]?] = [
            nil, [:], ["cost": 1, "remaining": 500],
            ["cost": -1, "remaining": 500, "resetAt": "2033-05-18T03:33:20Z"],
            ["cost": 1, "remaining": -1, "resetAt": "2033-05-18T03:33:20Z"],
            ["cost": 1, "remaining": true, "resetAt": "2033-05-18T03:33:20Z"],
            ["cost": 1, "remaining": 500, "resetAt": "invalid"]
        ]
        for quota in quotas {
            let (service, runner) = fixtureService(try batchPayload([payload()], quota: quota))
            await expectInvalidMetadata { _ = try await refresh(service) }
            #expect(await runner.calls.count == 1)
        }
        for value in ["null", "17", "true", #""budget""#] {
            let (service, runner) = fixtureService("{\"data\":{\"rateLimit\":\(value)}}")
            await expectInvalidMetadata { _ = try await refresh(service) }
            #expect(await runner.calls.count == 1)
        }
    }

    @Test
    func missingInaccessibleAndIncompleteCheckFieldsNeverLookHealthy() async throws {
        let incomplete: [[String: Any]] = [
            [:], ["commits": NSNull()], ["commits": ["nodes": []]], ["commits": ["nodes": [NSNull()]]],
            ["commits": ["nodes": [["commit": [:]]]]],
            ["commits": ["nodes": [["commit": ["statusCheckRollup": [:]]]]]],
            ["commits": ["nodes": [["commit": ["statusCheckRollup": ["contexts": NSNull()]]]]]]
        ]
        for changes in incomplete {
            let json = try payload(changes, removing: ["statusCheckRollup", "reviewDecision"])
            let (service, _) = fixtureService(try batchPayload([json]))
            let status = try await refresh(service)
            #expect(status.checks == .unavailable)
            #expect(status.review == .unavailable)
        }
        for pageInfo: Any in [NSNull(), ["hasNextPage": true], [:]] {
            let commits: [String: Any] = [
                "nodes": [
                    [
                        "commit": [
                            "statusCheckRollup": [
                                "contexts": [
                                    "nodes": [["__typename": "StatusContext", "state": "SUCCESS"]], "pageInfo": pageInfo
                                ]
                            ]
                        ]
                    ]
                ]
            ]
            let (service, _) = try fixtureStatusService(["commits": commits])
            let status = try await refresh(service)
            #expect(status.checks.state == .unknown)
            #expect(!status.checks.isAvailable)
        }
    }

    @Test
    func unscopedOptionalSchemaFailuresCannotTriggerPerPullRequestFallbacks() async throws {
        let json = try batchPayload([payload()], errors: [["message": "Cannot query field reviewDecision"]])
        let (service, runner) = fixtureService(json)
        await expectInvalidMetadata { _ = try await refresh(service) }
        #expect(await runner.calls.count == 1)
    }
}

extension PullRequestStatusBatchServiceTests {
    @Test
    func includedHeadersAreStrippedAndRateDeadlinesArePreservedWithoutReflectingSecrets() async throws {
        let json = try batchPayload([payload()])
        let headers =
            "HTTP/2.0 200 OK\r\nRetry-After: 60\r\nSet-Cookie: opaque-secret\r\nAuthorization: opaque-secret\r\n\r\n"
        let (service, _) = fixtureService(headers + json)
        let started = Date()
        let batch = try await service.refreshPullRequests([knownStatus().identity], repositoryPath: projectPath)
        #expect(try batch.results[knownStatus().identity]?.get().lifecycle == .open)
        let retry = try #require(batch.retryAfter)
        #expect(retry >= started.addingTimeInterval(60))
        #expect(retry <= Date().addingTimeInterval(60))
        let forbiddenHeaders =
            "HTTP/2.0 403 Forbidden\nX-RateLimit-Remaining: 0\nX-RateLimit-Reset: 2000000000\nRetry-After: 60\n\n{}"
        let response = try GitHubStatusResponse(
            GitHubCommandResult(stdout: Data(forbiddenHeaders.utf8), stderr: Data(), exitCode: 1),
            receivedAt: Date(timeIntervalSince1970: 1_000))
        #expect(response.sharedFailure() == .rateLimited(retryAfter: Date(timeIntervalSince1970: 2_000_000_000)))
        let dated = try GitHubStatusResponse(
            success("HTTP/2.0 200 OK\nRetry-After: Wed, 18 May 2033 03:33:20 GMT\n\n{}"))
        #expect(dated.retryAfter == Date(timeIntervalSince1970: 2_000_000_000))
    }

    @Test
    func globalGraphQLAuthenticationAndRateFailuresRemainShared() async throws {
        for (message, type, expected) in [
            ("Bad credentials", "UNAUTHENTICATED", PullRequestStatusError.unauthenticated),
            (
                "API rate limit exceeded", "RATE_LIMITED",
                .rateLimited(retryAfter: Date(timeIntervalSince1970: 2_000_000_000))
            ),
            ("Secondary rate limit exceeded", "RATE_LIMITED", .secondaryRateLimited(retryAfter: nil))
        ] {
            let json = try batchPayload([payload()], errors: [["message": message, "type": type]])
            let runner = StatusCommandRunner([GitHubCommandResult(stdout: Data(json.utf8), stderr: Data(), exitCode: 1)]
            )
            await #expect(throws: expected) { try await refresh(makeService(runner)) }
            #expect(await runner.calls.count == 1)
        }
    }

    @Test(arguments: [false, true])
    func aValidatedPreviousDeletedForkStillRequiresAnyKnownUpstream(hasUpstream: Bool) async throws {
        let fork = RepositoryIdentity(provider: .github, host: "github.example", owner: "fork", repositoryName: "repo")
        let previous = knownStatus(headRepository: fork)
        let json = try payload([
            "headRepository": NSNull(), "headRepositoryOwner": NSNull(), "isCrossRepository": true, "state": "MERGED"
        ])
        let (service, runner) = fixtureService("[\(json)]", try batchPayload([json]))
        let branch = PullRequestBranchContext(
            branchName: previous.headBranchName, headCommitObjectID: nextHead,
            upstreamRepository: hasUpstream ? fork : nil
        )
        if hasUpstream {
            await #expect(throws: PullRequestStatusError.unverifiedAssociation) {
                try await discover(service, branch: branch, previous: previous)
            }
            #expect(await runner.calls.count == 1)
        } else {
            let association = try #require(try await discover(service, branch: branch, previous: previous))
            #expect(association.identity == previous.identity)
            let batch = try await service.refreshPullRequests([association.identity], repositoryPath: projectPath)
            let status = try #require(batch.results[association.identity]).get()
            try PullRequestAssociation(previous).validate(status)
            #expect(status.lifecycle == .merged)
            #expect(status.headRepository == nil)
            #expect(await runner.calls.count == 2)
        }
    }

    @Test
    func quotaFieldErrorsAndInvalidUTF8CannotReportHealthyQuota() async throws {
        let json = try batchPayload(
            [payload()],
            errors: [
                [
                    "message": "Rate metadata unavailable", "path": ["rateLimit", "remaining"]
                ]
            ])
        let (service, _) = fixtureService(json)
        await expectInvalidMetadata { _ = try await refresh(service) }
        let runner = StatusCommandRunner([GitHubCommandResult(stdout: Data([255]), stderr: Data(), exitCode: 0)])
        await expectInvalidMetadata { _ = try await refresh(makeService(runner)) }
    }

    @Test
    func unusableEnvelopesStillHonorExplicitRetryHeaders() async throws {
        for headers in [
            "HTTP/2.0 200 OK\nRetry-After: Wed, 18 May 2033 03:33:20 GMT\n\n",
            "HTTP/2.0 403 Forbidden\nX-RateLimit-Remaining: 0\nX-RateLimit-Reset: 2000000000\n\n"
        ] {
            for body in [Data("{".utf8), Data("{}".utf8), Data(#"{"errors":17}"#.utf8), Data([255])] {
                let runner = StatusCommandRunner([
                    GitHubCommandResult(stdout: Data(headers.utf8) + body, stderr: Data(), exitCode: 0)
                ])
                await #expect(
                    throws: PullRequestStatusError.rateLimited(retryAfter: Date(timeIntervalSince1970: 2_000_000_000))
                ) {
                    try await refresh(makeService(runner))
                }
                #expect(await runner.calls.count == 1)
            }
        }
    }

    @Test(
        arguments: [false, true],
        [
            ("Bad credentials", PullRequestStatusError.unauthenticated),
            ("Secondary rate limit exceeded", .secondaryRateLimited(retryAfter: nil))
        ])
    func invalidUTF8RetainsReadableFailureDiagnostics(
        fromStderr: Bool, diagnostic: (String, PullRequestStatusError)
    ) async throws {
        let bytes = Data([255]) + Data(diagnostic.0.utf8)
        let result = GitHubCommandResult(
            stdout: fromStderr ? Data() : bytes, stderr: fromStderr ? bytes : Data(), exitCode: 1)
        #expect(GitHubStatusResponse.failure(result) == diagnostic.1)
        let runner = StatusCommandRunner([result])
        await #expect(throws: diagnostic.1) { try await refresh(makeService(runner)) }
        #expect(await runner.calls.count == 1)
    }

    @Test
    func generic429UsesSecondaryBackoffWithoutInventingAPrimaryReset() async throws {
        let runner = StatusCommandRunner([failure("HTTP 429: rate limit exceeded")])
        await #expect(throws: PullRequestStatusError.secondaryRateLimited(retryAfter: nil)) {
            try await refresh(makeService(runner))
        }
    }

    @Test
    func primaryExhaustionWithoutResetPausesConservativelyForAnHour() async throws {
        let runner = StatusCommandRunner([failure("API rate limit exceeded")])
        let started = Date()
        do {
            _ = try await refresh(makeService(runner))
            Issue.record("Expected primary rate exhaustion")
        } catch let error as PullRequestStatusError {
            let deadline = try #require(error.pauseDeadline)
            #expect(deadline >= started.addingTimeInterval(3_600))
            #expect(deadline <= Date().addingTimeInterval(3_600))
        }
    }
}
