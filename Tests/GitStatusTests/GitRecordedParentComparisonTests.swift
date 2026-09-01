import Foundation
import Testing

@testable import Argus

extension GitStatusPresentationTests {
    @Test(arguments: ["configuration", "graphite", "gh-stack"])
    func recordedParentWithIntermediateTrailingDotExcludesParentCommits(source: String) async throws {
        let repo = try stackedRepository(prefix: "argus-base-intermediate-dot")
        defer { repo.remove() }
        let parent = "feature./base"
        try TestGit.run(["branch", "-m", Self.parentBranch, parent], in: repo.url)
        switch source {
        case "configuration":
            try TestGit.run(["config", "branch.\(Self.childBranch).base", parent], in: repo.url)
        case "graphite":
            try writeBranchMetadata(
                repo: repo, branch: Self.childBranch,
                payload: #"{"parentBranchName":"\#(parent)"}"#
            )
        case "gh-stack":
            try writeGhStackMetadata(
                in: repo.url.appendingPathComponent(".git"), trunk: "main",
                branches: [parent, Self.childBranch]
            )
        default:
            Issue.record("Unexpected Recorded Base Branch source: \(source)")
            return
        }

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")

        #expect(summary.againstBaseState == .available)
        #expect(summary.sections.last?.title == "Against \(parent)")
        #expect(summary.againstBaseFiles.map(\.path) == ["child.txt"])
        #expect(
            summary.againstBaseFiles.first?.diffSource
                == .againstBase(baseName: parent, resolvedRef: "refs/heads/\(parent)"))
    }

    @Test(arguments: [
        ".", "..", "feature/base.", "feature./base.", "feature../base", "feature/.base",
        "feature/./base", "feature/../base", "feature.lock/base", "feature/base.lock"
    ])
    func branchValidationRejectsTrailingDotsAndInvalidComponents(name: String) {
        #expect(!GitReferenceValidation.isValidBranchName(name))
    }

    @Test(arguments: [false, true])
    func ghStackParentComparesOnlyCurrentBranchCommits(inSiblingWorktree: Bool) async throws {
        let repo = try stackedRepository(prefix: "argus-base-gh-stack")
        defer { repo.remove() }
        let sibling = try TestTemporaryDirectory(prefix: "argus-base-gh-stack-sibling")
        defer { sibling.remove() }
        var gitDirectory = repo.url.appendingPathComponent(".git")
        if inSiblingWorktree {
            try TestGit.run(["worktree", "add", "--detach", sibling.url.path, "main"], in: repo.url)
            gitDirectory = URL(fileURLWithPath: try TestGit.run(["rev-parse", "--absolute-git-dir"], in: sibling.url))
        }
        try writeGhStackMetadata(in: gitDirectory, trunk: "main", branches: [Self.parentBranch, Self.childBranch])

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")

        #expect(summary.sections.last?.title == "Against \(Self.parentBranch)")
        #expect(summary.againstBaseFiles.map(\.path) == ["child.txt"])
        #expect(summary.againstBaseState == .available)
    }

    @Test(arguments: [false, true])
    func matchingToolParentsCoalesce(withExplicitConfiguration: Bool) async throws {
        let repo = try stackedRepository(prefix: "argus-base-matching-parents")
        defer { repo.remove() }
        try writeBranchMetadata(
            repo: repo, branch: Self.childBranch,
            payload: #"{"parentBranchName":"\#(Self.parentBranch)"}"#
        )
        try writeGhStackMetadata(
            in: repo.url.appendingPathComponent(".git"), trunk: "main",
            branches: [Self.parentBranch, Self.childBranch]
        )
        if withExplicitConfiguration {
            try TestGit.run(["config", "branch.\(Self.childBranch).base", Self.parentBranch], in: repo.url)
        }

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")

        #expect(summary.againstBaseState == .available)
        #expect(summary.againstBaseFiles.map(\.path) == ["child.txt"])
    }

    @Test
    func explicitConfigurationOverridesConflictingToolParents() async throws {
        let repo = try stackedRepository(prefix: "argus-base-config-over-conflict")
        defer { repo.remove() }
        try writeConflictingCurrentBranchParents(repo: repo)
        let conflicting = try RecordedBaseBranchReader().read(repositoryPath: repo.url.path)
        #expect(conflicting.conflicts[Self.childBranch] != nil)
        try TestGit.run(["config", "branch.\(Self.childBranch).base", Self.parentBranch], in: repo.url)

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")

        #expect(summary.againstBaseState == .available)
        #expect(summary.sections.last?.title == "Against \(Self.parentBranch)")
        #expect(summary.againstBaseFiles.map(\.path) == ["child.txt"])
    }

    @Test(arguments: [false, true])
    func currentBranchConflictKeepsWorkingChangesActionable(combined: Bool) async throws {
        let repo = try stackedRepository(prefix: "argus-base-current-conflict")
        defer { repo.remove() }
        try writeConflictingCurrentBranchParents(repo: repo)
        let metadata = try RecordedBaseBranchReader().read(repositoryPath: repo.url.path)
        let conflict = try #require(metadata.conflicts[Self.childBranch])
        try "working\n".write(to: repo.url.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repo.url.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let request = GitStatusRequest(
            rootPath: repo.url.path,
            presentation: GitStatusPresentation(
                combineWorkingChangeSections: combined, showBaseBranchChanges: true, configuredBaseBranch: "main"
            )
        )
        let service = GitStatusService()

        let summary = try loadedPresentationSummary(await service.status(request: request))

        guard case .unavailable(let message) = summary.againstBaseState else {
            Issue.record("A current-branch conflict must make Against Base unavailable")
            return
        }
        #expect(message == conflict)
        #expect(summary.againstBaseFiles.isEmpty)
        #expect(summary.sections.dropLast().allSatisfy { $0.state.isAvailable })
        #expect(summary.unstagedCount == 1)
        #expect(summary.untrackedCount == 1)
        #expect(!summary.isClean)

        let staged = try loadedPresentationSummary(
            await service.performFileOperation(.stage, request: request, path: "base.txt")
        )
        #expect(staged.stagedCount == 1)
        #expect(staged.unstagedCount == 0)
        #expect(staged.untrackedCount == 1)
        #expect(staged.againstBaseState == summary.againstBaseState)
    }

    @Test(arguments: [false, true])
    func unrelatedConflictDoesNotBlockCurrentParent(withExplicitConfiguration: Bool) async throws {
        let repo = try stackedRepository(prefix: "argus-base-unrelated-conflict")
        defer { repo.remove() }
        try TestGit.run(["branch", "unrelated", "main"], in: repo.url)
        try writeBranchMetadata(repo: repo, branch: "unrelated", payload: #"{"parentBranchName":"main"}"#)
        try writeGhStackMetadata(
            in: repo.url.appendingPathComponent(".git"), trunk: Self.parentBranch, branches: ["unrelated"]
        )
        if withExplicitConfiguration {
            try TestGit.run(["config", "branch.\(Self.childBranch).base", Self.parentBranch], in: repo.url)
        } else {
            try writeBranchMetadata(
                repo: repo, branch: Self.childBranch,
                payload: #"{"parentBranchName":"\#(Self.parentBranch)"}"#
            )
        }
        let metadata = try RecordedBaseBranchReader().read(repositoryPath: repo.url.path)
        #expect(metadata.conflicts["unrelated"] != nil)

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")

        #expect(summary.againstBaseState == .available)
        #expect(summary.againstBaseFiles.map(\.path) == ["child.txt"])
    }

    @Test
    func validConfigurationSurvivesMalformedGraphite() async throws {
        let repo = try stackedRepository(prefix: "argus-base-config-malformed-provider")
        defer { repo.remove() }
        try TestGit.run(["config", "branch.\(Self.childBranch).base", Self.parentBranch], in: repo.url)
        try writeBranchMetadata(repo: repo, branch: Self.childBranch, payload: "not JSON")

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")

        #expect(summary.againstBaseState == .available)
        #expect(summary.againstBaseFiles.map(\.path) == ["child.txt"])
    }

    @Test(arguments: [false, true])
    func ghStackParentUsesLocalFirstThenOrigin(originOnly: Bool) async throws {
        let repo = try stackedRepository(prefix: "argus-base-gh-stack-ref-order")
        defer { repo.remove() }
        try writeGhStackMetadata(
            in: repo.url.appendingPathComponent(".git"), trunk: "main",
            branches: [Self.parentBranch, Self.childBranch]
        )
        try TestGit.run(
            [
                "update-ref", "refs/remotes/origin/\(Self.parentBranch)",
                originOnly ? Self.parentBranch : "\(Self.parentBranch)~1"
            ],
            in: repo.url
        )
        if originOnly { try TestGit.run(["branch", "-D", Self.parentBranch], in: repo.url) }

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")

        let file = try #require(summary.againstBaseFiles.first)
        let expectedRef = originOnly ? "refs/remotes/origin/\(Self.parentBranch)" : "refs/heads/\(Self.parentBranch)"
        #expect(file.diffSource == .againstBase(baseName: Self.parentBranch, resolvedRef: expectedRef))
        #expect(summary.againstBaseFiles.map(\.path) == ["child.txt"])
    }

    @Test(arguments: [false, true])
    func noRecordedParentKeepsProjectAndStandaloneFallback(namedProject: Bool) async throws {
        let repo = try stackedRepository(prefix: "argus-base-no-parent")
        defer { repo.remove() }
        try TestGit.run(["update-ref", "refs/remotes/origin/main", "main"], in: repo.url)

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: namedProject ? "main" : nil)

        #expect(summary.sections.last?.title == "Against main")
        #expect(summary.againstBaseFiles.map(\.path) == ["child.txt", "parent.txt"])
        #expect(
            summary.againstBaseFiles.first?.diffSource
                == .againstBase(baseName: "main", resolvedRef: "refs/remotes/origin/main"))
    }

    @Test(arguments: [
        "", "   ", "sticky-slider~1", "sticky-slider^", "sticky-slider^{commit}", "sticky-slider@{0}", "HEAD"
    ])
    func invalidRecordedParentNeverBecomesARevisionExpression(parent: String) async throws {
        let repo = try stackedRepository(prefix: "argus-base-invalid-parent")
        defer { repo.remove() }
        try TestGit.run(["config", "branch.\(Self.childBranch).base", parent], in: repo.url)

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")

        #expect(summary.sections.last?.title == "Against main")
        #expect(summary.againstBaseState == .available)
        #expect(summary.againstBaseFiles.map(\.path) == ["child.txt", "parent.txt"])
    }

    @Test
    func packedGraphiteRefStillSuppliesTheRecordedParent() async throws {
        let repo = try stackedRepository(prefix: "argus-base-packed-graphite")
        defer { repo.remove() }
        try writeBranchMetadata(
            repo: repo, branch: Self.childBranch,
            payload: #"{"parentBranchName":"\#(Self.parentBranch)"}"#
        )
        try TestGit.run(["pack-refs", "--all", "--prune"], in: repo.url)
        #expect(
            !FileManager.default.fileExists(
                atPath: repo.url.appendingPathComponent(".git/refs/branch-metadata/\(Self.childBranch)").path))

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")

        #expect(summary.sections.last?.title == "Against \(Self.parentBranch)")
        #expect(summary.againstBaseFiles.map(\.path) == ["child.txt"])
    }

    @Test
    func cyclicCurrentBranchParentDoesNotFallBackToMain() async throws {
        let repo = try stackedRepository(prefix: "argus-base-cycle")
        defer { repo.remove() }
        try TestGit.run(["config", "branch.\(Self.childBranch).base", Self.parentBranch], in: repo.url)
        try TestGit.run(["config", "branch.\(Self.parentBranch).base", Self.childBranch], in: repo.url)

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")

        #expect(!summary.againstBaseState.isAvailable)
        #expect(summary.againstBaseFiles.isEmpty)
        #expect(summary.sections.dropLast().allSatisfy { $0.state.isAvailable })
    }

    @Test
    func recordedMetadataReadFailureIsContainedInsideAgainstBase() throws {
        let directory = try TestTemporaryDirectory(prefix: "argus-base-reader-failure")
        defer { directory.remove() }

        let result = buildAgainstBase(
            rootPath: directory.url.path,
            presentation: GitStatusPresentation(showBaseBranchChanges: true, configuredBaseBranch: "main"),
            currentBranch: Self.childBranch
        )

        guard case .unavailable(let message) = result.state else {
            Issue.record("A metadata read failure must make Against Base unavailable")
            return
        }
        #expect(message.contains("Could not read the recorded base branch"))
        #expect(result.files.isEmpty)
    }

    private func writeConflictingCurrentBranchParents(repo: GitStatusPresentationRepository) throws {
        try writeBranchMetadata(
            repo: repo, branch: Self.childBranch,
            payload: #"{"parentBranchName":"\#(Self.parentBranch)"}"#
        )
        try writeGhStackMetadata(
            in: repo.url.appendingPathComponent(".git"), trunk: "main", branches: [Self.childBranch])
    }

    private func writeGhStackMetadata(in gitDirectory: URL, trunk: String, branches: [String]) throws {
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "stacks": [["trunk": ["branch": trunk], "branches": branches.map { ["branch": $0] }]]
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: gitDirectory.appendingPathComponent("gh-stack"))
    }
}
