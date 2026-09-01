import Foundation
import Testing

@testable import Argus

struct StackChainFixture: Sendable {
    let trunkBranch: String
    let branches: [String]
}

final class StackRepositoryFixture {
    private let temporary: TestTemporaryDirectory
    let repository: URL

    var reader: RecordedBaseBranchReader {
        RecordedBaseBranchReader(
            environment: GitCommandEnvironment.standard.merging([
                "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": "0"
            ]) { _, new in new })
    }

    var service: WorkspaceStackService { WorkspaceStackService(reader: reader) }

    init() throws {
        temporary = try TestTemporaryDirectory(prefix: "argus-workspace-stack")
        repository = temporary.url.appendingPathComponent("repository").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try TestGit.run(["init", "-b", "main", "."], in: repository)
        try TestGit.run(
            [
                "-c", "user.name=Test User", "-c", "user.email=test@example.com",
                "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                "commit", "--allow-empty", "-m", "initial"
            ], in: repository)
    }

    deinit { temporary.remove() }

    func addWorktree(branch: String, directory: String? = nil) throws -> URL {
        let name = directory ?? branch.replacingOccurrences(of: "/", with: "-")
        let checkout = temporary.url.appendingPathComponent(name).resolvingSymlinksInPath()
        try TestGit.run(["worktree", "add", "-b", branch, checkout.path, "HEAD"], in: repository)
        return checkout
    }

    func metadataURL(checkout: URL? = nil) throws -> URL {
        let path = try TestGit.run(["rev-parse", "--path-format=absolute", "--git-dir"], in: checkout ?? repository)
        return URL(fileURLWithPath: path).appendingPathComponent("gh-stack")
    }

    func writeMetadata(_ json: String) throws {
        try Data(json.utf8).write(to: metadataURL())
    }

    func writeStacks(_ definitions: [StackChainFixture], checkout: URL? = nil, published: Bool = false) throws {
        let stacks: [[String: Any]] = definitions.map { definition in
            var stack: [String: Any] = [
                "trunk": ["branch": definition.trunkBranch],
                "branches": definition.branches.map { ["branch": $0] }
            ]
            if published {
                stack["id"] = "upstream-identifier"
                stack["number"] = 42
            }
            return stack
        }
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "stacks": stacks])
        try data.write(to: metadataURL(checkout: checkout))
    }

    func files() throws -> [String: StackFixtureFile] {
        let paths = try FileManager.default.subpathsOfDirectory(atPath: repository.path)
        return try Dictionary(
            uniqueKeysWithValues: paths.map { path in
                let url = repository.appendingPathComponent(path)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let data = attributes[.type] as? FileAttributeType == .typeRegular ? try Data(contentsOf: url) : nil
                return (path, StackFixtureFile(data: data, modified: attributes[.modificationDate] as? Date))
            })
    }
}

struct StackFixtureFile: Equatable {
    let data: Data?
    let modified: Date?
}
