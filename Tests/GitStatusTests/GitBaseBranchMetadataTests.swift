import Foundation
import Testing

@testable import Argus

extension GitStatusPresentationTests {
    @Test
    func recordedStackBaseComparesAgainstTheParentBranchOnly() async throws {
        let repo = try stackedRepository(prefix: "argus-presentation-stack-config")
        defer { repo.remove() }
        try run(
            "/usr/bin/git",
            ["config", "branch.\(Self.childBranch).base", Self.parentBranch],
            in: repo.url
        )

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")

        assertEqual(summary.sections.last?.title, "Against \(Self.parentBranch)", "recorded base names the section")
        assertEqual(
            summary.againstBaseFiles.map(\.path),
            ["child.txt"],
            "Against Base excludes the parent branch's own commits"
        )
        let file = try #require(summary.againstBaseFiles.first)
        guard case .againstBase(let baseName, let resolvedRef) = file.diffSource else {
            fail("expected an Against Base diff source, got \(file.diffSource)")
        }
        assertEqual(baseName, Self.parentBranch, "recorded base supplies the base name")
        assertEqual(
            resolvedRef,
            "refs/heads/\(Self.parentBranch)",
            "a recorded stack parent resolves to its local branch"
        )
    }

    @Test
    func recordedStackBasePrefersTheLocalBranchOverAStaleOriginRef() async throws {
        let repo = try stackedRepository(prefix: "argus-presentation-stack-stale-origin")
        defer { repo.remove() }
        try run(
            "/usr/bin/git",
            ["config", "branch.\(Self.childBranch).base", Self.parentBranch],
            in: repo.url
        )
        try run(
            "/usr/bin/git",
            ["update-ref", "refs/remotes/origin/\(Self.parentBranch)", "\(Self.parentBranch)~1"],
            in: repo.url
        )

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")

        let file = try #require(summary.againstBaseFiles.first)
        guard case .againstBase(_, let resolvedRef) = file.diffSource else {
            fail("expected an Against Base diff source, got \(file.diffSource)")
        }
        assertEqual(
            resolvedRef,
            "refs/heads/\(Self.parentBranch)",
            "a restacked parent's local branch wins over its origin-tracking ref"
        )
        assertEqual(
            summary.againstBaseFiles.map(\.path),
            ["child.txt"],
            "the stale origin ref would have pulled the parent's later commit back in"
        )
    }

    @Test
    func unresolvableRecordedStackBaseFallsBackToTheConfiguredBase() async throws {
        let repo = try stackedRepository(prefix: "argus-presentation-stack-unresolvable")
        defer { repo.remove() }
        try run(
            "/usr/bin/git",
            ["config", "branch.\(Self.childBranch).base", "merged-and-deleted"],
            in: repo.url
        )

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")

        assertEqual(summary.sections.last?.title, "Against main", "an unresolvable recorded base is ignored")
        assertEqual(
            summary.againstBaseFiles.map(\.path),
            ["child.txt", "parent.txt"],
            "the configured base comparison keeps the parent branch's commits"
        )
    }

    @Test
    func recordedStackBaseNamingItsOwnBranchIsIgnored() async throws {
        let repo = try stackedRepository(prefix: "argus-presentation-stack-self")
        defer { repo.remove() }
        try run(
            "/usr/bin/git",
            ["config", "branch.\(Self.childBranch).base", Self.childBranch],
            in: repo.url
        )

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")

        assertEqual(summary.sections.last?.title, "Against main", "a branch is never its own base")
    }

    /// The `parentBranchName` key is Graphite's recorded branch-metadata layout
    /// as documented at the time of writing, not a layout this repository can
    /// verify against a real Graphite checkout. Reading it wrong costs a
    /// fallthrough, which the next test pins.
    @Test
    func graphiteBranchMetadataNamingAParentBranchResolvesIt() async throws {
        let repo = try stackedRepository(prefix: "argus-presentation-stack-graphite")
        defer { repo.remove() }
        try writeBranchMetadata(
            repo: repo,
            branch: Self.childBranch,
            payload: #"{"parentBranchName":"\#(Self.parentBranch)","parentBranchRevision":"unused"}"#
        )

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")

        assertEqual(
            summary.sections.last?.title,
            "Against \(Self.parentBranch)",
            "branch metadata supplies the recorded base name"
        )
        assertEqual(
            summary.againstBaseFiles.map(\.path),
            ["child.txt"],
            "branch metadata scopes Against Base to the branch's own commits"
        )
    }

    @Test
    func unreadableGraphiteBranchMetadataFallsThroughWithoutFailing() async throws {
        let repo = try stackedRepository(prefix: "argus-presentation-stack-graphite-unreadable")
        defer { repo.remove() }
        try writeBranchMetadata(repo: repo, branch: Self.childBranch, payload: "not json at all")

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")

        assertEqual(summary.sections.last?.title, "Against main", "unreadable metadata is ignored")
        assertEqual(summary.sections.last?.state.isAvailable, true, "unreadable metadata is not a base failure")
    }

    @Test
    func recordedStackBaseOutranksTheConfiguredProjectBase() async throws {
        let repo = try stackedRepository(prefix: "argus-presentation-stack-precedence")
        defer { repo.remove() }
        try run(
            "/usr/bin/git",
            ["config", "branch.\(Self.childBranch).base", Self.parentBranch],
            in: repo.url
        )
        try run("/usr/bin/git", ["update-ref", "refs/remotes/origin/main", "refs/heads/main"], in: repo.url)
        try run(
            "/usr/bin/git",
            ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"],
            in: repo.url
        )

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")

        assertEqual(
            summary.sections.last?.title,
            "Against \(Self.parentBranch)",
            "the branch's own recorded base outranks the configured project base and origin HEAD"
        )
    }

    /// Every Worktree Workspace resolves its Git Status Root to a linked
    /// worktree path, while a stacking tool records the key in the repository's
    /// shared configuration. The recorded read has to cross that boundary.
    @Test
    func recordedStackBaseIsReadFromALinkedWorktree() async throws {
        let repo = try stackedRepository(prefix: "argus-presentation-stack-worktree")
        defer { repo.remove() }
        let worktreeParent = try TestTemporaryDirectory(prefix: "argus-presentation-stack-worktree-linked")
        defer { worktreeParent.remove() }
        let worktreeURL = worktreeParent.url.appendingPathComponent("linked", isDirectory: true)
        try run("/usr/bin/git", ["checkout", "main"], in: repo.url)
        try run(
            "/usr/bin/git",
            ["worktree", "add", worktreeURL.path, Self.childBranch],
            in: repo.url
        )
        defer { try? run("/usr/bin/git", ["worktree", "remove", "--force", worktreeURL.path], in: repo.url) }
        try run(
            "/usr/bin/git",
            ["config", "branch.\(Self.childBranch).base", Self.parentBranch],
            in: repo.url
        )

        let summary = try loadedPresentationSummary(
            await GitStatusService().status(
                request: GitStatusRequest(
                    rootPath: worktreeURL.path,
                    presentation: GitStatusPresentation(
                        showBaseBranchChanges: true,
                        configuredBaseBranch: "main"
                    )
                )
            )
        )

        assertEqual(
            summary.sections.last?.title,
            "Against \(Self.parentBranch)",
            "a linked worktree reads the recorded base from the shared configuration"
        )
        assertEqual(
            summary.againstBaseFiles.map(\.path),
            ["child.txt"],
            "a linked worktree scopes Against Base to the branch's own commits"
        )
    }

    static var parentBranch: String { "sticky-slider" }
    static var childBranch: String { "eshurakov/silver-atlas" }

    /// main -> `sticky-slider` (two commits) -> `eshurakov/silver-atlas` (one
    /// commit), the shape of a stacked pull request. The child branch name keeps
    /// its slash so recorded lookups are exercised against a real branch name.
    private func stackedRepository(prefix: String) throws -> GitStatusPresentationRepository {
        let repo = try presentationRepository(prefix: prefix)
        try "base\n".write(
            to: repo.url.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "base.txt"], in: repo.url)
        try run("/usr/bin/git", ["commit", "-m", "base"], in: repo.url)

        try run("/usr/bin/git", ["checkout", "-b", Self.parentBranch], in: repo.url)
        let parentURL = repo.url.appendingPathComponent("parent.txt")
        try "parent\n".write(to: parentURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "parent.txt"], in: repo.url)
        try run("/usr/bin/git", ["commit", "-m", "parent one"], in: repo.url)
        try "parent\nparent again\n".write(to: parentURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["commit", "-am", "parent two"], in: repo.url)

        try run("/usr/bin/git", ["checkout", "-b", Self.childBranch], in: repo.url)
        try "child\n".write(
            to: repo.url.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "child.txt"], in: repo.url)
        try run("/usr/bin/git", ["commit", "-m", "child"], in: repo.url)
        return repo
    }

    private func stackedSummary(
        repo: GitStatusPresentationRepository,
        configuredBaseBranch: String?
    ) async throws -> GitStatusSummary {
        try loadedPresentationSummary(
            await GitStatusService().status(
                request: GitStatusRequest(
                    rootPath: repo.url.path,
                    presentation: GitStatusPresentation(
                        showBaseBranchChanges: true,
                        configuredBaseBranch: configuredBaseBranch
                    )
                )
            )
        )
    }

    /// Writes a branch-metadata blob the way a stacking tool does, keeping the
    /// payload out of the working tree so the fixture stays clean.
    private func writeBranchMetadata(
        repo: GitStatusPresentationRepository,
        branch: String,
        payload: String
    ) throws {
        let payloadDirectory = try TestTemporaryDirectory(prefix: "argus-branch-metadata")
        defer { payloadDirectory.remove() }
        let payloadURL = payloadDirectory.url.appendingPathComponent("metadata.json")
        try payload.write(to: payloadURL, atomically: true, encoding: .utf8)
        let blob = try TestGit.run(["hash-object", "-w", payloadURL.path], in: repo.url)
        try run("/usr/bin/git", ["update-ref", "refs/branch-metadata/\(branch)", blob], in: repo.url)
    }
}
