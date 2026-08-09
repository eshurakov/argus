import Foundation
import Testing

@testable import Argus

@Suite(.serialized)
struct GitStatusPresentationTests {
    @Test
    func reportsOneRowPerPathWithCombinedState() async throws {
        let repo = try presentationRepository(prefix: "argus-presentation-combined")
        defer { repo.remove() }

        let mixedURL = repo.url.appendingPathComponent("mixed.txt")
        let stagedURL = repo.url.appendingPathComponent("staged.txt")
        let unstagedURL = repo.url.appendingPathComponent("unstaged.txt")
        try "base\n".write(to: mixedURL, atomically: true, encoding: .utf8)
        try "base\n".write(to: stagedURL, atomically: true, encoding: .utf8)
        try "base\n".write(to: unstagedURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "."], in: repo.url)
        try run("/usr/bin/git", ["commit", "-m", "initial"], in: repo.url)

        try "base\nindex\n".write(to: mixedURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "mixed.txt"], in: repo.url)
        try "base\nindex\nworktree\n".write(to: mixedURL, atomically: true, encoding: .utf8)
        try "base\nstaged\n".write(to: stagedURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "staged.txt"], in: repo.url)
        try "base\nunstaged\n".write(to: unstagedURL, atomically: true, encoding: .utf8)
        try "new\n".write(
            to: repo.url.appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        let state = await GitStatusService().status(
            request: GitStatusRequest(
                rootPath: repo.url.path,
                presentation: GitStatusPresentation(combineWorkingChangeSections: true)
            )
        )
        let summary = try loadedPresentationSummary(state)
        assertEqual(summary.sections.map(\.kind), [.uncommitted], "combined mode has one section")
        assertEqual(summary.sections[0].totalCount, 4, "combined section deduplicates paths")
        assertEqual(summary.stagedCount, 2, "combined summary retains staged subset count")
        assertEqual(summary.unstagedCount, 2, "combined summary retains unstaged subset count")
        assertEqual(summary.untrackedCount, 1, "combined summary retains untracked subset count")

        let mixed = try #require(summary.uncommittedFiles.first { $0.path == "mixed.txt" })
        assertEqual(mixed.hasStagedChanges, true, "mixed path retains staged state")
        assertEqual(mixed.hasUnstagedChanges, true, "mixed path retains unstaged state")
        assertEqual(mixed.isUntracked, false, "tracked mixed path is not untracked")
        assertEqual(mixed.additions, 2, "combined stats describe HEAD to worktree")
        assertEqual(mixed.deletions, 0, "combined stats preserve net deletions")
    }

    @Test
    func returnsAllFourPresentationLayouts() async throws {
        let repo = try presentationRepository(prefix: "argus-presentation-layouts")
        defer { repo.remove() }
        let fileURL = repo.url.appendingPathComponent("file.txt")
        try "base\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "file.txt"], in: repo.url)
        try run("/usr/bin/git", ["commit", "-m", "initial"], in: repo.url)
        try run("/usr/bin/git", ["checkout", "-b", "feature"], in: repo.url)
        try "feature\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "file.txt"], in: repo.url)
        try run("/usr/bin/git", ["commit", "-m", "feature"], in: repo.url)
        try "feature\nworking\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let service = GitStatusService()
        let rootPath = repo.url.path
        let basePresentation = GitStatusPresentation(configuredBaseBranch: "main")

        try await assertPresentationLayouts(
            service: service,
            rootPath: rootPath,
            basePresentation: basePresentation
        )
    }

    private func assertPresentationLayouts(
        service: GitStatusService,
        rootPath: String,
        basePresentation: GitStatusPresentation
    ) async throws {

        let classic = try loadedPresentationSummary(
            await service.status(request: GitStatusRequest(rootPath: rootPath))
        )
        assertEqual(
            classic.sections.map(\.kind), [.staged, .unstaged, .untracked],
            "default mode preserves classic section order"
        )

        let combined = try loadedPresentationSummary(
            await service.status(
                request: GitStatusRequest(
                    rootPath: rootPath,
                    presentation: GitStatusPresentation(combineWorkingChangeSections: true)
                )
            )
        )
        assertEqual(combined.sections.map(\.kind), [.uncommitted], "combine-only mode has one section")

        let baseOnly = try loadedPresentationSummary(
            await service.status(
                request: GitStatusRequest(rootPath: rootPath, presentation: presentationWithBase(basePresentation))
            )
        )
        assertEqual(
            baseOnly.sections.map(\.kind), [.staged, .unstaged, .untracked, .againstBase],
            "base-only mode appends Against Base"
        )
        assertEqual(baseOnly.sections.last?.title, "Against main", "base title uses configured branch name")

        let combinedAndBase = try loadedPresentationSummary(
            await service.status(
                request: GitStatusRequest(
                    rootPath: rootPath,
                    presentation: GitStatusPresentation(
                        combineWorkingChangeSections: true,
                        showBaseBranchChanges: true,
                        configuredBaseBranch: "main"
                    )
                )
            )
        )
        assertEqual(
            combinedAndBase.sections.map(\.kind), [.uncommitted, .againstBase],
            "combined and base mode preserves working-before-base order"
        )
        assertEqual(combinedAndBase.isClean, false, "Against Base does not hide working dirtiness")
        assertEqual(combinedAndBase.againstBaseState, .available, "three-dot base comparison is available")
        assertEqual(
            combinedAndBase.againstBaseFiles.contains { $0.path == "file.txt" },
            true,
            "Against Base contains committed branch work"
        )
    }

    @Test
    func resolvesNamedBaseBeforeLocalAndSkipsCurrentStandaloneBranch() async throws {
        let named = try presentationRepository(prefix: "argus-presentation-base-precedence")
        defer { named.remove() }
        let fileURL = named.url.appendingPathComponent("file.txt")
        try "base\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "file.txt"], in: named.url)
        try run("/usr/bin/git", ["commit", "-m", "initial"], in: named.url)
        try run("/usr/bin/git", ["checkout", "-b", "feature"], in: named.url)
        try "feature\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "file.txt"], in: named.url)
        try run("/usr/bin/git", ["commit", "-m", "feature"], in: named.url)
        try run("/usr/bin/git", ["update-ref", "refs/remotes/origin/main", "main"], in: named.url)

        let namedState = await GitStatusService().status(
            request: GitStatusRequest(
                rootPath: named.url.path,
                presentation: GitStatusPresentation(
                    showBaseBranchChanges: true,
                    configuredBaseBranch: "main"
                )
            )
        )
        let namedSummary = try loadedPresentationSummary(namedState)
        let namedFile = try #require(namedSummary.againstBaseFiles.first)
        guard case .againstBase(let baseName, let resolvedRef) = namedFile.diffSource else {
            fail("expected Against Base diff source, got \(namedFile.diffSource)")
        }
        assertEqual(baseName, "main", "named project keeps configured base name")
        assertEqual(resolvedRef, "refs/remotes/origin/main", "origin base ref wins over local branch")

        let standalone = try presentationRepository(prefix: "argus-presentation-current-base")
        defer { standalone.remove() }
        let standaloneFile = standalone.url.appendingPathComponent("file.txt")
        try "main\n".write(to: standaloneFile, atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "file.txt"], in: standalone.url)
        try run("/usr/bin/git", ["commit", "-m", "initial"], in: standalone.url)

        let standaloneState = await GitStatusService().status(
            request: GitStatusRequest(
                rootPath: standalone.url.path,
                presentation: GitStatusPresentation(showBaseBranchChanges: true)
            )
        )
        let standaloneSummary = try loadedPresentationSummary(standaloneState)
        guard case .unavailable(let message) = standaloneSummary.againstBaseState else {
            fail("expected current standalone branch to be rejected as its own base")
        }
        assertEqual(
            message.contains("No base branch"), true,
            "standalone mode does not silently compare the current branch with itself"
        )
    }
}

struct GitStatusPresentationRepository {
    let directory: TestTemporaryDirectory
    var url: URL { directory.url }
    func remove() { directory.remove() }
}

func presentationRepository(prefix: String) throws -> GitStatusPresentationRepository {
    let directory = try TestTemporaryDirectory(prefix: prefix)
    try run("/usr/bin/git", ["init", "-b", "main"], in: directory.url)
    try run("/usr/bin/git", ["config", "user.email", "argus@example.test"], in: directory.url)
    try run("/usr/bin/git", ["config", "user.name", "Argus Test"], in: directory.url)
    return GitStatusPresentationRepository(directory: directory)
}

func loadedPresentationSummary(_ state: GitStatusLoadState) throws -> GitStatusSummary {
    guard case .loaded(let summary) = state else {
        throw NSError(
            domain: "GitStatusPresentationServiceTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "expected loaded status, got \(state)"]
        )
    }
    return summary
}

func presentationWithBase(_ presentation: GitStatusPresentation) -> GitStatusPresentation {
    GitStatusPresentation(
        combineWorkingChangeSections: presentation.combineWorkingChangeSections,
        showBaseBranchChanges: true,
        configuredBaseBranch: presentation.configuredBaseBranch
    )
}

func run(_ executable: String, _ arguments: [String], in directory: URL) throws {
    #expect(executable == "/usr/bin/git", "Git status fixtures must use the system git executable")
    _ = try TestGit.run(arguments, in: directory)
}

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    #expect(actual == expected, Comment(rawValue: message))
}

func fail(_ message: String) -> Never {
    Issue.record(Comment(rawValue: message))
    fatalError(message)
}

typealias TemporaryDirectory = TestTemporaryDirectory
