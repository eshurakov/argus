import Foundation
import Testing

@testable import Argus

extension RecordedBaseBranchReaderTests {
    @Test(arguments: [
        "", " \n", "child", "bad..name", "bad/name.lock", "bad name", "-option", "ref@{other}", "bad\nline"
    ])
    func invalidEmptyOrSelfConfigDoesNotOverrideAValidToolRecord(_ value: String) throws {
        let fixture = try RecordedParentRepository()
        try fixture.git(["config", "branch.child.base", value])
        try fixture.graphite("child", parent: "tool-parent")
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["child": "tool-parent"])
        #expect(snapshot.conflicts.isEmpty)
        #expect(snapshot.diagnostics.isEmpty == ["", " \n", "child"].contains(value))
    }

    @Test
    func boundedConfigReadsPreserveIncludeOrderingAndEffectiveLastValues() throws {
        let fixture = try RecordedParentRepository()
        let included = fixture.directory.appendingPathComponent("included config")
        try fixture.git(["config", "--file", included.path, "branch.child.base", "included-parent"])
        let earlier = "[branch \"child\"]\n base = " + String(repeating: "x", count: 1_048_577) + "\n"
        let include = "[include]\n path = \"\(included.path)\"\n"
        try Data((earlier + include + "[branch \"child\"]\n base = last-parent\n").utf8)
            .write(to: fixture.globalConfig)
        let last = try fixture.read()
        let lastMatches = last.parents == ["child": "last-parent"]
        #expect(lastMatches)
        #expect(last.issue == nil)
        try Data((earlier + include).utf8).write(to: fixture.globalConfig)
        let includedSnapshot = try fixture.read()
        let includedMatches = includedSnapshot.parents == ["child": "included-parent"]
        #expect(includedMatches)
        #expect(includedSnapshot.issue == nil)
        let command = try fixture.read(environmentOverrides: [
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "branch.child.base", "GIT_CONFIG_VALUE_0": "command-parent"
        ])
        #expect(command.parents == ["child": "command-parent"])
    }

    @Test(arguments: ["config", "graphite", "gh-stack"], [2_048, 2_049])
    func parentNameBoundsUseUTF8BytesAcrossProviders(_ source: String, _ characterCount: Int) throws {
        let fixture = try RecordedParentRepository()
        let parent = String(repeating: "é", count: characterCount)
        switch source {
        case "config": try fixture.git(["config", "branch.child.base", parent])
        case "graphite": try fixture.graphite("child", parent: parent)
        default: try fixture.ghStack(trunk: parent, branches: ["child"])
        }
        let snapshot = try fixture.read()
        let accepted = characterCount == 2_048
        #expect(snapshot.parents.count == (accepted ? 1 : 0))
        #expect(snapshot.diagnostics.isEmpty == accepted)
    }

    @Test
    func oversizedBranchNamesDoNotDiscardIndependentRelations() throws {
        let fixture = try RecordedParentRepository()
        let branch = String(repeating: "x", count: 4_097)
        let config = "[branch \"\(branch)\"]\n base = parent\n[branch \"healthy\"]\n base = healthy-parent\n"
        try Data(config.utf8).write(to: fixture.globalConfig)
        try fixture.ghStack(trunk: "root", branches: [branch, "descendant", "leaf"])
        let snapshot = try fixture.read()
        #expect(snapshot.parents.count == 2)
        #expect(snapshot.parents["healthy"] == "healthy-parent")
        #expect(snapshot.parents["leaf"] == "descendant")
        #expect(!snapshot.diagnostics.isEmpty)
    }

    @Test(arguments: [4_097, 1_048_577])
    func oversizedExplicitValuesDoNotDiscardHealthyDeclarations(_ byteCount: Int) throws {
        let fixture = try RecordedParentRepository()
        let oversized = String(repeating: "x", count: byteCount)
        let config =
            "[branch \"oversized\"]\n base = \(oversized)\n"
            + "[branch \"healthy\"]\n base = healthy-parent\n[branch \"main\"]\n base = main-parent\n"
        try Data(config.utf8).write(to: fixture.globalConfig)
        let before = try fixture.files()
        let snapshot = try fixture.read()
        #expect(snapshot.parents.count == 2)
        #expect(!snapshot.parents.keys.contains("oversized"))
        #expect(snapshot.parents["healthy"] == "healthy-parent")
        #expect(snapshot.parents["main"] == "main-parent")
        let expected =
            byteCount > 1_048_576
            ? "Local Git metadata output exceeds the 1 MiB limit."
            : "A local branch-parent declaration exceeds the 4096-byte name limit."
        #expect(snapshot.diagnostics == [expected])
        #expect(try fixture.files() == before)
    }

    @Test
    func anEmptyEffectiveLastConfigValueDoesNotResurrectAnEarlierDeclaration() throws {
        let fixture = try RecordedParentRepository()
        try fixture.git(["config", "--add", "branch.child.base", "earlier"])
        try fixture.git(["config", "--add", "branch.child.base", ""])
        try fixture.git(["config", "--add", "branch.main.base", "earlier"])
        try fixture.git(["config", "--add", "branch.main.base", ""])
        let snapshot = try fixture.read()
        #expect(snapshot.parents.isEmpty)
        #expect(snapshot.issue == nil)
    }

    @Test
    func valuelessConfigDoesNotInvalidateIndependentDeclarations() throws {
        let fixture = try RecordedParentRepository()
        let config = "[branch \"unchecked\"]\n base\n[branch \"main\"]\n base\n[branch \"good\"]\n base = parent\n"
        try Data(config.utf8).write(to: fixture.globalConfig)
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["good": "parent"])
        #expect(snapshot.issue == nil)
    }

    @Test(arguments: [
        "{}", "{\"parentBranchName\":null}", "{\"parentBranchName\":\"\"}", "{\"parentBranchName\":\" \"}",
        "{\"parentBranchName\":\"child\"}"
    ])
    func missingEmptyAndSelfGraphiteValuesAreNotDeclarations(_ payload: String) throws {
        let fixture = try RecordedParentRepository()
        try fixture.graphiteJSON("child", payload: payload)
        let snapshot = try fixture.read()
        #expect(snapshot.parents.isEmpty)
        #expect(snapshot.issue == nil)
    }

    @Test(arguments: ["{", "null", "[]", "{\"parentBranchName\":3}", "private-payload-marker"])
    func malformedGraphiteDoesNotPoisonExplicitOrIndependentRecords(_ payload: String) throws {
        let fixture = try RecordedParentRepository()
        try fixture.graphiteJSON("child", payload: payload)
        try fixture.graphite("independent", parent: "other")
        try fixture.git(["config", "branch.child.base", "explicit"])
        try fixture.ghStack(trunk: "main", branches: ["gh-child"])
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["child": "explicit", "independent": "other", "gh-child": "main"])
        #expect(snapshot.diagnostics == ["Local Graphite metadata is malformed."])
        #expect(snapshot.conflicts.isEmpty)
        #expect(snapshot.issue?.contains("private-payload-marker") == false)
    }

    @Test
    func malformedGhStackDoesNotPoisonOtherProvidersOrIndependentStackRecords() throws {
        let fixture = try RecordedParentRepository()
        try fixture.graphite("graphite-child", parent: "parent")
        try fixture.git(["config", "branch.config-child.base", "parent"])
        try fixture.writeGhStackJSON(
            """
            {"schemaVersion":1,"stacks":[
              {"branches":[]},
              {"trunk":{"branch":"parent"},"branches":[{"branch":"gh-child"}]}
            ]}
            """
        )
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["graphite-child": "parent", "config-child": "parent", "gh-child": "parent"])
        #expect(snapshot.diagnostics == ["Local gh-stack metadata is malformed."])
    }

    @Test
    func invalidBranchNamesAreDiagnosedWithoutInventingOrDroppingIndependentEdges() throws {
        let fixture = try RecordedParentRepository()
        try fixture.git(["config", "branch.bad..child.base", "parent"])
        try fixture.git(["config", "branch.good.base", "parent"])
        try fixture.graphite("graphite-child", parent: "bad..parent")
        try fixture.ghStack(trunk: "trunk", branches: ["bad child", "unbound", "descendant"])
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["good": "parent", "descendant": "unbound"])
        #expect(snapshot.diagnostics.count == 3)
    }

    @Test(arguments: ["oversized", "missing", "corrupt", "nonblob", "brokenref"])
    func unreadableOrOversizedGraphiteObjectsDoNotBlockOtherRecords(_ kind: String) throws {
        let fixture = try RecordedParentRepository()
        switch kind {
        case "oversized":
            try fixture.graphiteJSON("child", payload: String(repeating: " ", count: 1_048_577))
        case "missing", "corrupt":
            let objectID = try fixture.graphiteJSON("child", payload: "{}")
            let object = try fixture.gitDirectory().appendingPathComponent(
                "objects/\(objectID.prefix(2))/\(objectID.dropFirst(2))")
            if kind == "missing" {
                try FileManager.default.removeItem(at: object)
            } else {
                try Data("invalid compressed object".utf8).write(to: object, options: .atomic)
            }
        case "brokenref":
            try fixture.graphiteJSON("child", payload: "{}")
            let reference = try fixture.gitDirectory().appendingPathComponent("refs/branch-metadata/child")
            try Data("invalid-object-id\n".utf8).write(to: reference)
        default:
            try fixture.git(["update-ref", "refs/branch-metadata/child", "HEAD"])
        }
        try fixture.git(["config", "branch.child.base", "explicit"])
        try fixture.graphite("independent", parent: "other")
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["child": "explicit", "independent": "other"])
        let expected =
            kind == "oversized"
            ? "Local Graphite metadata exceeds the 1 MiB limit." : "Local Graphite metadata could not be read."
        #expect(snapshot.diagnostics == [expected])
    }

    @Test(arguments: ["graphite", "gh-stack"])
    func metadataAtTheOneMiBLimitIsAccepted(_ source: String) throws {
        let fixture = try RecordedParentRepository()
        let json =
            source == "graphite"
            ? "{\"parentBranchName\":\"parent\"}"
            : #"{"schemaVersion":1,"stacks":[{"trunk":{"branch":"parent"},"branches":[{"branch":"child"}]}]}"#
        let payload = json + String(repeating: " ", count: 1_048_576 - json.utf8.count)
        if source == "graphite" {
            try fixture.graphiteJSON("child", payload: payload)
        } else {
            try fixture.writeGhStackJSON(payload)
        }
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["child": "parent"])
        #expect(snapshot.issue == nil)
    }

    @Test
    func allProvidersAndRegisteredWorktreesRemainReadOnly() throws {
        let fixture = try RecordedParentRepository()
        let linked = try fixture.addWorktree(branch: "child")
        try fixture.git(["config", "extensions.worktreeConfig", "true"])
        try fixture.git(["config", "--worktree", "branch.child.base", "parent"], checkout: linked)
        try fixture.git(["config", "--file", fixture.globalConfig.path, "branch.parent.base", "main"])
        try fixture.graphite("child", parent: "parent")
        try fixture.ghStack(trunk: "main", branches: ["parent", "child"], checkout: linked)
        try fixture.git(["pack-refs", "--all"])
        let before = try fixture.files()
        let snapshot = try fixture.read(checkout: linked)
        #expect(snapshot.parents == ["parent": "main", "child": "parent"])
        #expect(snapshot.issue == nil)
        #expect(try fixture.files() == before)
    }

    @Test
    func diagnosticSummariesDeduplicateAndLimitVisibleIssues() {
        let empty = RecordedBaseBranchSnapshot(gitCommonDirectory: "/fixture")
        #expect(empty.issue == nil)
        let snapshot = RecordedBaseBranchSnapshot(
            gitCommonDirectory: "/fixture",
            conflicts: ["first": "A conflict.", "second": "A conflict.", "third": "C cycle."],
            diagnostics: ["A conflict.", "B malformed.", "B malformed.", "D unreadable."]
        )
        #expect(snapshot.issue == "A conflict. C cycle. 2 more metadata issues.")
    }
}

final class RecordedParentRepository {
    private let temporary: TestTemporaryDirectory
    let repository: URL
    let globalConfig: URL

    var directory: URL { temporary.url.resolvingSymlinksInPath() }

    private var environment: [String: String] {
        GitCommandEnvironment.standard.merging([
            "GIT_CONFIG_GLOBAL": globalConfig.path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_COUNT": "0"
        ]) { _, new in new }
    }

    init(objectFormat: String = "sha1") throws {
        temporary = try TestTemporaryDirectory(prefix: "argus-recorded-parents")
        repository = temporary.url.appendingPathComponent("repository").resolvingSymlinksInPath()
        globalConfig = temporary.url.appendingPathComponent("global-config")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "--object-format=\(objectFormat)", "-b", "main", "."])
        try git([
            "-c", "user.name=Test User", "-c", "user.email=test@example.com",
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
            "commit", "--allow-empty", "-m", "initial"
        ])
    }

    deinit { temporary.remove() }

    @discardableResult
    func git(_ arguments: [String], checkout: URL? = nil) throws -> String {
        try TestGit.run(arguments, in: checkout ?? repository, environment: environment)
    }

    func read(checkout: URL? = nil, environmentOverrides: [String: String] = [:]) throws -> RecordedBaseBranchSnapshot {
        try RecordedBaseBranchReader(environment: environment.merging(environmentOverrides) { _, new in new })
            .read(repositoryPath: (checkout ?? repository).path)
    }

    func addWorktree(branch: String, directoryName: String? = nil, existing: Bool = false) throws -> URL {
        let checkout = directory.appendingPathComponent(
            directoryName ?? branch.replacingOccurrences(of: "/", with: "-"))
        if existing {
            try git(["worktree", "add", "--force", checkout.path, branch])
        } else {
            try git(["worktree", "add", "-b", branch, checkout.path, "HEAD"])
        }
        return checkout
    }

    func gitDirectory(checkout: URL? = nil) throws -> URL {
        let result = try git(["rev-parse", "--path-format=absolute", "--git-dir"], checkout: checkout)
        return URL(fileURLWithPath: result)
    }

    func graphite(_ branch: String, parent: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["parentBranchName": parent])
        try graphiteJSON(branch, payload: #require(String(bytes: data, encoding: .utf8)))
    }

    @discardableResult
    func graphiteJSON(_ branch: String, payload: String) throws -> String {
        let url = directory.appendingPathComponent("payload-\(UUID().uuidString)")
        try Data(payload.utf8).write(to: url)
        let objectID = try git(["hash-object", "-w", url.path])
        try git(["update-ref", "refs/branch-metadata/\(branch)", objectID])
        return objectID
    }

    func ghStack(trunk: String, branches: [String], checkout: URL? = nil) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "stacks": [["trunk": ["branch": trunk], "branches": branches.map { ["branch": $0] }]]
        ])
        try writeGhStackJSON(#require(String(bytes: data, encoding: .utf8)), checkout: checkout)
    }

    func writeGhStackJSON(_ json: String, checkout: URL? = nil) throws {
        try Data(json.utf8).write(to: gitDirectory(checkout: checkout).appendingPathComponent("gh-stack"))
    }

    func files() throws -> [String: RecordedParentFixtureFile] {
        let paths = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
        return try Dictionary(
            uniqueKeysWithValues: paths.map { path in
                let url = directory.appendingPathComponent(path)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let data = attributes[.type] as? FileAttributeType == .typeRegular ? try Data(contentsOf: url) : nil
                return (path, RecordedParentFixtureFile(data: data, modified: attributes[.modificationDate] as? Date))
            })
    }
}

struct RecordedParentFixtureFile: Equatable {
    let data: Data?
    let modified: Date?
}
