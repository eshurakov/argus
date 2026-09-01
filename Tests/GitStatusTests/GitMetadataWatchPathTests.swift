import Foundation
import Testing

@testable import Argus

// Each case creates multiple real Git worktrees with synchronous subprocesses.
@Suite(.serialized)
struct GitMetadataWatchPathTests {
    @Test(arguments: GitMetadataRepositoryLayout.allCases)
    func watchesActualGitDirectoriesIncludingCommonAndSiblingAdministration(
        layout: GitMetadataRepositoryLayout
    ) throws {
        let fixture = try GitMetadataRefreshRepository(layout: layout)
        defer { fixture.directory.remove() }
        var expected = [fixture.root.path]
        if layout != .normal { expected.append(fixture.commonDirectory.path) }
        if layout == .split { expected.append(fixture.gitDirectory.path) }

        #expect(GitStatusAutoRefreshController.watchedPaths(for: fixture.root.path) == expected)
        #expect(expected.contains { GitMetadataEventPath.relativePath(fixture.siblingDirectory.path, in: $0) != nil })
    }

    @Test
    func gitDirectoryWithoutCommondirIsWatchedAsItsOwnCommonDirectory() throws {
        let fixture = try GitMetadataRefreshRepository(layout: .separate)
        defer { fixture.directory.remove() }
        let paths = GitMetadataWatchPaths(rootPath: fixture.root.path)

        #expect(paths.gitDirectory == fixture.gitDirectory.path)
        #expect(paths.commonDirectory == fixture.gitDirectory.path)
        #expect(paths.watchedPaths == [fixture.root.path, fixture.gitDirectory.path])
    }

    @Test(
        arguments: ["git data\nwith newline", "git data with trailing spaces  ", "git data\r\nwith spaces "],
        [false, true])
    func preservesOddGitDirectoryPathRecords(directoryName: String, linked: Bool) throws {
        let fixture = try GitMetadataRefreshRepository(layout: .separate, commonDirectoryName: directoryName)
        defer { fixture.directory.remove() }
        let checkout =
            linked ? fixture.directory.url.appendingPathComponent("sibling", isDirectory: true) : fixture.root
        let gitDirectory = linked ? fixture.siblingDirectory : fixture.gitDirectory
        let record = try Data(contentsOf: checkout.appendingPathComponent(".git"))
        #expect(record.starts(with: "gitdir: ".utf8))
        #expect(record.last == 0x0A)
        #expect(record.range(of: Data(directoryName.utf8)) != nil)
        for ending in ["\n", "\r\n", ""] {
            try "gitdir: \(gitDirectory.path)\(ending)".write(
                to: checkout.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
            if linked {
                try "\(fixture.commonDirectory.path)\(ending)".write(
                    to: gitDirectory.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
            }
            #expect(try TestGit.run(["rev-parse", "--is-inside-work-tree"], in: checkout) == "true")

            let paths = GitMetadataWatchPaths(rootPath: checkout.path)

            #expect(paths.gitDirectory == gitDirectory.path)
            #expect(paths.commonDirectory == fixture.commonDirectory.path)
            #expect(paths.watchedPaths == [checkout.path, fixture.commonDirectory.path])
        }
    }

    @Test(arguments: [
        "gitdir: \n", "gitdir: \0invalid\n", "invalid\n", "gitdir:/external", "gitdir:\t/external",
        "\ngitdir: /external\n", "gitdir: " + String(repeating: "x", count: 4_096)
    ])
    func malformedOrOversizedGitPointerDoesNotAddAWatch(contents: String) throws {
        let directory = try TestTemporaryDirectory(prefix: "argus-watch-invalid-gitdir")
        defer { directory.remove() }
        try contents.write(to: directory.url.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        #expect(GitStatusAutoRefreshController.watchedPaths(for: directory.url.path) == [directory.url.path])
    }

    @Test(arguments: ["", "\0invalid", String(repeating: "x", count: 4_097)])
    func malformedOrOversizedCommondirKeepsTheGitDirectoryWatch(contents: String) throws {
        let fixture = try GitMetadataRefreshRepository(layout: .separate)
        defer { fixture.directory.remove() }
        try contents.write(
            to: fixture.gitDirectory.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)

        #expect(
            GitStatusAutoRefreshController.watchedPaths(for: fixture.root.path) == [
                fixture.root.path, fixture.gitDirectory.path
            ])
    }

    @Test
    func symlinkedCheckoutResolvesRelativePointersAgainstTheCheckout() throws {
        let fixture = try GitMetadataRefreshRepository(layout: .linked)
        defer { fixture.directory.remove() }
        try "gitdir: ../repository/.git/worktrees/selected\n".write(
            to: fixture.root.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let aliasDirectory = fixture.directory.url.appendingPathComponent("aliases", isDirectory: true)
        try FileManager.default.createDirectory(at: aliasDirectory, withIntermediateDirectories: true)
        let alias = aliasDirectory.appendingPathComponent("checkout")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        let paths = GitMetadataWatchPaths(rootPath: alias.path)

        #expect(paths.gitDirectory == fixture.gitDirectory.path)
        #expect(paths.commonDirectory == fixture.commonDirectory.path)
        #expect(paths.watchedPaths == [alias.path, fixture.commonDirectory.path])
    }

    @Test
    func repositoryConfigIncludesDoNotAddBroadWatchRoots() throws {
        let fixture = try GitMetadataRefreshRepository(layout: .normal)
        defer { fixture.directory.remove() }
        let config = fixture.directory.url.appendingPathComponent("included.config")
        try "[branch \"feature\"]\nbase = main\n".write(to: config, atomically: true, encoding: .utf8)
        try TestGit.run(["config", "include.path", config.path], in: fixture.root)

        #expect(GitStatusAutoRefreshController.watchedPaths(for: fixture.root.path) == [fixture.root.path])
    }

    @Test
    func removedMetadataSubtreesStillResolveThroughSymlinkedAncestors() throws {
        let fixture = try GitMetadataRefreshRepository(layout: .separate)
        defer { fixture.directory.remove() }
        let alias = fixture.directory.url.appendingPathComponent("metadata-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.commonDirectory)
        let relativePath = "refs/branch-metadata/feature/child"
        let metadata = fixture.commonDirectory.appendingPathComponent(relativePath)
        let parent = metadata.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try "parent".write(to: metadata, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: parent)

        #expect(
            GitMetadataEventPath.relativePath(
                alias.appendingPathComponent(relativePath).path, in: fixture.commonDirectory.path) == relativePath)
    }

    @Test
    func relativeMetadataPathsRespectDirectoryBoundariesAndDeletedFiles() throws {
        let fixture = try GitMetadataRefreshRepository(layout: .separate)
        defer { fixture.directory.remove() }
        let metadata = fixture.commonDirectory.appendingPathComponent("gh-stack")
        try "{}".write(to: metadata, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: metadata)

        #expect(GitMetadataEventPath.relativePath(metadata.path, in: fixture.commonDirectory.path) == "gh-stack")
        #expect(
            GitMetadataEventPath.relativePath(
                fixture.commonDirectory.path + "-other/config", in: fixture.commonDirectory.path) == nil)
        #expect(GitMetadataEventPath.relativePath(fixture.commonDirectory.path, in: fixture.commonDirectory.path) == "")
        #expect(!GitMetadataEventPath.isRelevant(""))
    }
}

enum GitMetadataRepositoryLayout: CaseIterable, Sendable {
    case normal
    case linked
    case separate
    case split
}

struct GitMetadataRefreshRepository {
    let directory: TestTemporaryDirectory
    let root: URL
    let gitDirectory: URL
    let commonDirectory: URL
    let siblingDirectory: URL

    init(layout: GitMetadataRepositoryLayout, commonDirectoryName: String = "common-admin") throws {
        directory = try TestTemporaryDirectory(prefix: "argus-metadata-refresh")
        let repository = directory.url.appendingPathComponent("repository", isDirectory: true)
        let separateGitDirectory = directory.url.appendingPathComponent(commonDirectoryName, isDirectory: true)
        var arguments = ["init", "-b", "main"]
        if layout == .separate {
            arguments += ["--separate-git-dir", separateGitDirectory.path]
        }
        try TestGit.run(arguments + [repository.path], in: directory.url)
        try TestGit.run(["config", "user.name", "Argus Test"], in: repository)
        try TestGit.run(["config", "user.email", "argus@example.test"], in: repository)
        try TestGit.run(["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "initial"], in: repository)
        commonDirectory = (layout == .separate ? separateGitDirectory : repository.appendingPathComponent(".git"))
            .resolvingSymlinksInPath()
        let sibling = directory.url.appendingPathComponent("sibling", isDirectory: true)
        try TestGit.run(["worktree", "add", "-b", "sibling", sibling.path, "main"], in: repository)
        siblingDirectory = URL(
            fileURLWithPath: try TestGit.run(["rev-parse", "--absolute-git-dir"], in: sibling), isDirectory: true
        ).resolvingSymlinksInPath()
        if layout == .linked || layout == .split {
            root = directory.url.appendingPathComponent("selected", isDirectory: true)
            try TestGit.run(["worktree", "add", "-b", "selected", root.path, "main"], in: repository)
        } else {
            root = repository
        }
        let originalGitDirectory =
            root == repository
            ? commonDirectory
            : URL(
                fileURLWithPath: try TestGit.run(["rev-parse", "--absolute-git-dir"], in: root), isDirectory: true
            ).resolvingSymlinksInPath()
        if layout == .split {
            gitDirectory = directory.url.appendingPathComponent("selected-admin", isDirectory: true)
                .resolvingSymlinksInPath()
            try FileManager.default.moveItem(at: originalGitDirectory, to: gitDirectory)
            try "gitdir: \(gitDirectory.path)\n".write(
                to: root.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
            try "\(commonDirectory.path)\n".write(
                to: gitDirectory.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        } else {
            gitDirectory = originalGitDirectory
        }
    }
}
