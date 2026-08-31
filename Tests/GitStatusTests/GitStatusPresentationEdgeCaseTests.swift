import Foundation
import Testing

@testable import Argus

extension GitStatusPresentationTests {
    @Test
    func keepsWorkingChangesWhenBaseIsUnavailable() async throws {
        let repo = try presentationRepository(prefix: "argus-presentation-base-unavailable")
        defer { repo.remove() }
        let fileURL = repo.url.appendingPathComponent("file.txt")
        try "base\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "file.txt"], in: repo.url)
        try run("/usr/bin/git", ["commit", "-m", "initial"], in: repo.url)
        try "working\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let summary = try loadedPresentationSummary(
            await GitStatusService().status(
                request: GitStatusRequest(
                    rootPath: repo.url.path,
                    presentation: GitStatusPresentation(
                        showBaseBranchChanges: true,
                        configuredBaseBranch: "does-not-exist"
                    )
                )
            )
        )
        assertEqual(summary.unstagedCount, 1, "working changes remain loaded on base failure")
        assertEqual(summary.isClean, false, "base failure does not change working cleanliness")
        assertEqual(summary.sections.count, 4, "unavailable base remains a visible section")
        guard case .unavailable(let message) = summary.sections.last?.state else {
            fail("expected an unavailable Against Base section")
        }
        assertEqual(message.contains("does-not-exist"), true, "base failure names the configured branch")
        assertEqual(summary.sections.last?.files.isEmpty, true, "unavailable base has no rows")
    }

    @Test
    func preservesUnmergedStateInCombinedRows() async throws {
        let repo = try presentationRepository(prefix: "argus-presentation-unmerged")
        defer { repo.remove() }
        let fileURL = repo.url.appendingPathComponent("file.txt")
        try "base\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "file.txt"], in: repo.url)
        try run("/usr/bin/git", ["commit", "-m", "initial"], in: repo.url)
        try run("/usr/bin/git", ["checkout", "-b", "other"], in: repo.url)
        try "other\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["commit", "-am", "other"], in: repo.url)
        try run("/usr/bin/git", ["checkout", "main"], in: repo.url)
        try "main\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["commit", "-am", "main"], in: repo.url)
        try? run("/usr/bin/git", ["merge", "other"], in: repo.url)

        let summary = try loadedPresentationSummary(
            await GitStatusService().status(
                request: GitStatusRequest(
                    rootPath: repo.url.path,
                    presentation: GitStatusPresentation(combineWorkingChangeSections: true)
                )
            )
        )
        let file = try #require(summary.uncommittedFiles.first)
        assertEqual(file.status, .unmerged, "combined rows preserve porcelain unmerged status")
        assertEqual(file.hasUnstagedChanges, true, "combined unmerged row retains worktree state")
    }

    @Test
    func resolvesStandaloneOriginHeadAndKeepsItsRef() async throws {
        let repo = try presentationRepository(prefix: "argus-presentation-origin-head")
        defer { repo.remove() }
        let fileURL = repo.url.appendingPathComponent("file.txt")
        try "main\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "file.txt"], in: repo.url)
        try run("/usr/bin/git", ["commit", "-m", "initial"], in: repo.url)
        try run("/usr/bin/git", ["checkout", "-b", "feature"], in: repo.url)
        try "feature\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "file.txt"], in: repo.url)
        try run("/usr/bin/git", ["commit", "-m", "feature"], in: repo.url)
        try run("/usr/bin/git", ["update-ref", "refs/remotes/origin/main", "refs/heads/main"], in: repo.url)
        try run(
            "/usr/bin/git",
            ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"],
            in: repo.url
        )

        let summary = try loadedPresentationSummary(
            await GitStatusService().status(
                request: GitStatusRequest(
                    rootPath: repo.url.path,
                    presentation: GitStatusPresentation(showBaseBranchChanges: true)
                )
            )
        )
        let file = try #require(summary.againstBaseFiles.first)
        guard case .againstBase(let baseName, let resolvedRef) = file.diffSource else {
            fail("expected an Against Base diff source, got \(file.diffSource)")
        }
        assertEqual(baseName, "main", "Standalone origin HEAD supplies the base name")
        assertEqual(
            resolvedRef,
            "refs/remotes/origin/HEAD",
            "Standalone origin HEAD remains the resolved comparison ref"
        )
    }

    @Test
    func handlesCombinedAndPreviewChangesBeforeTheFirstCommit() async throws {
        let repo = try presentationRepository(prefix: "argus-presentation-unborn")
        defer { repo.remove() }
        let stagedURL = repo.url.appendingPathComponent("staged.txt")
        try "staged\n".write(to: stagedURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "staged.txt"], in: repo.url)
        try "working\n".write(to: stagedURL, atomically: true, encoding: .utf8)
        try "untracked\n".write(
            to: repo.url.appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        let summary = try loadedPresentationSummary(
            await GitStatusService().status(
                request: GitStatusRequest(
                    rootPath: repo.url.path,
                    presentation: GitStatusPresentation(combineWorkingChangeSections: true)
                )
            )
        )
        let staged = try #require(summary.uncommittedFiles.first { $0.path == "staged.txt" })
        assertEqual(staged.additions, 1, "unborn staged additions get empty-old-content stats")
        assertEqual(staged.isNetDiffEmpty, false, "unborn staged additions are not canceled net diffs")
        assertEqual(summary.uncommittedCount, 2, "unborn combined status keeps staged and untracked rows")

        let preview = await GitPreviewService().preview(
            kind: .diff,
            rootPath: repo.url.path,
            file: staged
        )
        guard case .loaded(let loaded) = preview,
            case .diff(let diff) = loaded.content
        else {
            fail("expected unborn combined preview, got \(preview)")
        }
        assertEqual(diff.oldContent, "", "unborn combined preview has an empty old side")
        assertEqual(diff.newContent, "working\n", "unborn combined preview reads the working tree")
    }

    @Test
    func retainsCanceledNetChanges() async throws {
        let repo = try presentationRepository(prefix: "argus-presentation-canceled")
        defer { repo.remove() }
        let fileURL = repo.url.appendingPathComponent("file.txt")
        try "base\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "file.txt"], in: repo.url)
        try run("/usr/bin/git", ["commit", "-m", "initial"], in: repo.url)
        try "staged\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "file.txt"], in: repo.url)
        try "base\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let summary = try loadedPresentationSummary(
            await GitStatusService().status(
                request: GitStatusRequest(
                    rootPath: repo.url.path,
                    presentation: GitStatusPresentation(combineWorkingChangeSections: true)
                )
            )
        )
        let file = try #require(summary.uncommittedFiles.first)
        assertEqual(file.hasStagedChanges, true, "canceled path retains staged state")
        assertEqual(file.hasUnstagedChanges, true, "canceled path retains unstaged state")
        assertEqual(file.additions, 0, "canceled path reports zero net additions")
        assertEqual(file.deletions, 0, "canceled path reports zero net deletions")
        assertEqual(file.isNetDiffEmpty, true, "canceled path is marked for explanatory preview")
    }

    @Test
    func scopesCombinedSectionOperations() async throws {
        let repo = try presentationRepository(prefix: "argus-presentation-operations")
        defer { repo.remove() }
        let trackedURL = repo.url.appendingPathComponent("tracked.txt")
        try "base\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "tracked.txt"], in: repo.url)
        try run("/usr/bin/git", ["commit", "-m", "initial"], in: repo.url)
        try "index\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "tracked.txt"], in: repo.url)
        try "index\nworktree\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try "scratch\n".write(
            to: repo.url.appendingPathComponent("scratch.txt"),
            atomically: true,
            encoding: .utf8
        )
        let request = GitStatusRequest(
            rootPath: repo.url.path,
            presentation: GitStatusPresentation(combineWorkingChangeSections: true)
        )

        let staged = try loadedPresentationSummary(
            await GitStatusService().performSectionFileOperation(
                .stage, request: request, sectionKind: .uncommitted
            )
        )
        assertEqual(staged.stagedCount, 2, "combined Stage All includes untracked paths")
        assertEqual(staged.unstagedCount, 0, "combined Stage All stages tracked worktree changes")
        assertEqual(staged.untrackedCount, 0, "combined Stage All removes untracked state")

        try "index\nworktree again\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        let discarded = try loadedPresentationSummary(
            await GitStatusService().performSectionFileOperation(
                .discard, request: request, sectionKind: .uncommitted
            )
        )
        assertEqual(discarded.stagedCount, 2, "Discard All Unstaged preserves staged changes")
        assertEqual(discarded.unstagedCount, 0, "Discard All Unstaged clears only worktree changes")
    }
}
