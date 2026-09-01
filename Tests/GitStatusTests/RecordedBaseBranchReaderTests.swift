import Foundation
import Testing

@testable import Argus

@Suite
struct RecordedBaseBranchReaderTests {
    @Test
    func configOnlyUsesEffectiveLastValuesAndPreservesMissingParentNames() throws {
        let fixture = try RecordedParentRepository()
        try fixture.git(["config", "--add", "branch.feature/api.v2.base", "older-parent"])
        try fixture.git(["config", "--add", "branch.feature/api.v2.base", "missing/parent.v1"])
        try fixture.git(["config", "branch.next.base", "feature/api.v2"])
        try fixture.git(["config", "branch.main.base", "root"])
        try fixture.git(["config", "branch.feature/api.v2.remote", "unrelated-value"])
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["feature/api.v2": "missing/parent.v1", "next": "feature/api.v2", "main": "root"])
        #expect(snapshot.trunkBranches.isEmpty)
        #expect(snapshot.issue == nil)
    }

    @Test
    func commonConfigurationIncludesGlobalValuesButLocalLastValueWins() throws {
        let fixture = try RecordedParentRepository()
        try fixture.git(["config", "--file", fixture.globalConfig.path, "branch.global-only.base", "global-parent"])
        try fixture.git(["config", "--file", fixture.globalConfig.path, "branch.child.base", "global-parent"])
        try fixture.git(["config", "--add", "branch.child.base", "first-local-parent"])
        try fixture.git(["config", "--add", "branch.child.base", "last-local-parent"])
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["global-only": "global-parent", "child": "last-local-parent"])
        #expect(snapshot.issue == nil)
    }

    @Test(arguments: [false, true])
    func worktreeOverridesBindToTheirCurrentBranchIndependentOfStartingCheckout(_ separate: Bool) throws {
        let fixture = try RecordedParentRepository()
        if separate {
            try fixture.git([
                "init", "--separate-git-dir", fixture.directory.appendingPathComponent("git data\nwith spaces ").path
            ]
            )
        }
        let linked = try fixture.addWorktree(branch: "topic/child")
        try fixture.git(["config", "extensions.worktreeConfig", "true"])
        try fixture.git(["config", "branch.topic/child.base", "common-parent"])
        try fixture.git(["config", "branch.unchecked.base", "common-only"])
        try fixture.git(["config", "--worktree", "branch.unchecked.base", "not-current"])
        try fixture.git(["config", "--worktree", "branch.topic/child.base", "wrong-checkout"])
        try fixture.git(["config", "--worktree", "branch.main.base", "main-parent"])
        try fixture.git(["config", "--worktree", "branch.topic/child.base", "linked-parent"], checkout: linked)
        let snapshot = try fixture.read()
        #expect(snapshot.parents == (try fixture.read(checkout: linked)).parents)
        #expect(snapshot.parents == ["main": "main-parent", "topic/child": "linked-parent", "unchecked": "common-only"])
        #expect(snapshot.worktrees.contains(GitWorktreeBranch(path: fixture.repository.path, branch: "main")))
        #expect(snapshot.worktrees.contains(GitWorktreeBranch(path: linked.path, branch: "topic/child")))
        #expect(snapshot.issue == nil)
        try fixture.git(["config", "branch.topic/child.base", "bad..parent"])
        #expect(try fixture.read() == snapshot)
        try fixture.git(["config", "branch.topic/child.base", "common-parent"])
        try fixture.git(["switch", "-c", "topic/changed"], checkout: linked)
        try fixture.git(["config", "--worktree", "branch.topic/changed.base", "changed-parent"], checkout: linked)
        let changed = try fixture.read()
        #expect(changed.parents == (try fixture.read(checkout: linked)).parents)
        #expect(changed.parents["topic/child"] == "common-parent")
        #expect(changed.parents["topic/changed"] == "changed-parent")
    }

    @Test
    func separateDirectoryInventoryVerifiesInitiatorWithoutInventingMain() throws {
        let fixture = try RecordedParentRepository()
        let metadata = fixture.directory.appendingPathComponent("separate metadata ")
        try fixture.git(["init", "--separate-git-dir", metadata.path])
        let linked = try fixture.addWorktree(branch: "child")
        try fixture.git(["config", "extensions.worktreeConfig", "true"])
        try fixture.git(["config", "--worktree", "branch.main.base", "main-parent"])
        try fixture.git(["config", "--worktree", "branch.child.base", "linked-parent"], checkout: linked)
        let rootSnapshot = try fixture.read()
        #expect(
            rootSnapshot.worktrees == [
                GitWorktreeBranch(path: fixture.repository.path, branch: "main"),
                GitWorktreeBranch(path: linked.path, branch: "child")
            ])
        let linkedSnapshot = try fixture.read(checkout: linked)
        #expect(linkedSnapshot.worktrees == [GitWorktreeBranch(path: linked.path, branch: "child")])
        #expect(linkedSnapshot.parents == rootSnapshot.parents)
        #expect(linkedSnapshot.parents == ["main": "main-parent", "child": "linked-parent"])
        let nested = fixture.repository.appendingPathComponent("nested directory")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        #expect(try fixture.read(checkout: nested) == rootSnapshot)
        try fixture.git(["config", "--worktree", "core.worktree", fixture.repository.path])
        let located = try fixture.read(checkout: linked)
        #expect(located.worktrees == rootSnapshot.worktrees)
        #expect(located.parents == rootSnapshot.parents)
    }

    @Test
    func malformedMainWorktreeConfigDoesNotBlockHealthyLinkedMetadata() throws {
        let fixture = try RecordedParentRepository()
        let linked = try fixture.addWorktree(branch: "child")
        let commonDirectory = try fixture.gitDirectory()
        try fixture.git(["config", "extensions.worktreeConfig", "true"])
        try fixture.git(["config", "branch.child.base", "common-parent"])
        try fixture.git(["config", "--worktree", "branch.child.base", "linked-parent"], checkout: linked)
        try fixture.graphite("independent", parent: "other")
        try Data("[branch \"main\"\n".utf8).write(to: commonDirectory.appendingPathComponent("config.worktree"))
        #expect(try fixture.git(["status", "--porcelain"], checkout: linked).isEmpty)
        #expect(try fixture.git(["config", "--get", "branch.child.base"], checkout: linked) == "linked-parent")
        let before = try fixture.files()
        let snapshot = try fixture.read(checkout: linked)
        #expect(snapshot.parents == ["child": "linked-parent", "independent": "other"])
        #expect(snapshot.worktrees.contains(GitWorktreeBranch(path: linked.path, branch: "child")))
        #expect(!snapshot.diagnostics.isEmpty)
        #expect(try fixture.files() == before)
    }

    @Test
    func failedInventoryRecoversOtherVerifiedRegistrationsButNotPrunableCheckouts() throws {
        let fixture = try RecordedParentRepository()
        let child = try fixture.addWorktree(branch: "child")
        let parent = try fixture.addWorktree(branch: "parent")
        let removed = try fixture.addWorktree(branch: "removed")
        let commonDirectory = try fixture.gitDirectory()
        try fixture.git(["config", "extensions.worktreeConfig", "true"])
        try fixture.git(["config", "--worktree", "branch.child.base", "parent"], checkout: child)
        try fixture.git(["config", "--worktree", "branch.parent.base", "trunk"], checkout: parent)
        try FileManager.default.removeItem(at: removed)
        try Data("[broken\n".utf8).write(to: commonDirectory.appendingPathComponent("config.worktree"))
        let before = try fixture.files()
        let snapshot = try fixture.read(checkout: child)
        #expect(Set(snapshot.worktrees.map(\.path)) == [child.path, parent.path])
        #expect(snapshot.parents == ["child": "parent", "parent": "trunk"])
        #expect(try fixture.files() == before)
    }

    @Test
    func globalGitDirectoryAndOnBranchIncludesUseEachRegisteredCheckout() throws {
        let fixture = try RecordedParentRepository()
        let linked = try fixture.addWorktree(branch: "topic/child")
        let scoped = fixture.directory.appendingPathComponent("conditional-config")
        let onBranch = fixture.directory.appendingPathComponent("on-branch-config")
        let gitDirectory = try fixture.gitDirectory(checkout: linked)
        try fixture.git(["config", "--file", scoped.path, "branch.topic/child.base", "gitdir-parent"])
        try fixture.git([
            "config", "--file", fixture.globalConfig.path,
            "includeIf.gitdir:\(gitDirectory.path).path", scoped.path
        ])
        try fixture.git(["config", "--file", onBranch.path, "branch.topic/child.base", "onbranch-parent"])
        try fixture.git(["config", "includeIf.onbranch:topic/*.path", onBranch.path])
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["topic/child": "onbranch-parent"])
        #expect(snapshot == (try fixture.read(checkout: linked)))
        try fixture.git(["config", "--unset", "includeIf.onbranch:topic/*.path"])
        let globalOnly = try fixture.read()
        #expect(globalOnly.parents == ["topic/child": "gitdir-parent"])
        #expect(globalOnly == (try fixture.read(checkout: linked)))
    }

    @Test
    func duplicateCheckoutsDiagnoseDifferentEffectiveExplicitParents() throws {
        let fixture = try RecordedParentRepository()
        let first = try fixture.addWorktree(branch: "child")
        let second = try fixture.addWorktree(branch: "child", directoryName: "duplicate", existing: true)
        try fixture.git(["config", "extensions.worktreeConfig", "true"])
        try fixture.git(["config", "branch.child.base", "common"])
        try fixture.git(["config", "branch.descendant.base", "child"])
        try fixture.git(["config", "--worktree", "branch.child.base", "first-parent"], checkout: first)
        try fixture.git(["config", "--worktree", "branch.child.base", "second-parent"], checkout: second)
        try fixture.graphite("child", parent: "tool-parent")
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["descendant": "child"])
        #expect(Set(snapshot.conflicts.keys) == ["child"])
        #expect(snapshot.issue?.contains("'child'") == true)
        #expect(snapshot.issue?.contains("'first-parent'") == true)
        #expect(snapshot.issue?.contains("'second-parent'") == true)
        #expect(snapshot == (try fixture.read(checkout: second)))
        try fixture.git(["config", "--worktree", "branch.child.base", "first-parent"], checkout: second)
        let matching = try fixture.read()
        #expect(matching.parents == ["child": "first-parent", "descendant": "child"])
        #expect(matching.issue == nil)
    }

    @Test(arguments: [false, true])
    func graphiteOnlyReadsLooseAndPackedMetadataRefs(_ packed: Bool) throws {
        let fixture = try RecordedParentRepository()
        try fixture.graphite("feature/api.v2", parent: "missing-parent")
        try fixture.graphite("child", parent: "feature/api.v2")
        if packed { try fixture.git(["pack-refs", "--all"]) }
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["feature/api.v2": "missing-parent", "child": "feature/api.v2"])
        #expect(snapshot.trunkBranches.isEmpty)
        #expect(snapshot.issue == nil)
    }

    @Test(arguments: ["sha1", "sha256"])
    func graphiteReadsUseBoundedBatchesInsteadOfPerRefProcesses(_ objectFormat: String) throws {
        let fixture = try RecordedParentRepository(objectFormat: objectFormat)
        let parents = Dictionary(uniqueKeysWithValues: (0..<20).map { ("child-\($0)", "parent-\($0)") })
        for (branch, parent) in parents { try fixture.graphite(branch, parent: parent) }
        let trace = fixture.directory.appendingPathComponent("git-trace.jsonl")

        let snapshot = try fixture.read(environmentOverrides: ["GIT_TRACE2_EVENT": trace.path])
        let commands = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").compactMap { line in
            let event = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return event?["event"] as? String == "start" ? event?["argv"] as? [String] : nil
        }

        #expect(snapshot.parents == parents)
        #expect(snapshot.issue == nil)
        #expect(!commands.isEmpty)
        let commandLimit = objectFormat == "sha1" ? 12 : 14
        #expect(commands.count <= commandLimit)
    }

    @Test
    func graphiteBatchesRespectTheCombinedOutputBudget() throws {
        let fixture = try RecordedParentRepository()
        let size = RecordedBaseBranchReader.maximumMetadataBytes / 2
        for index in 0..<3 {
            let json = "{\"parentBranchName\":\"parent-\(index)\"}"
            let payload = json + String(repeating: " ", count: size - json.utf8.count)
            try fixture.graphiteJSON("child-\(index)", payload: payload)
        }

        let snapshot = try fixture.read()

        #expect(snapshot.parents == ["child-0": "parent-0", "child-1": "parent-1", "child-2": "parent-2"])
        #expect(snapshot.issue == nil)
    }

    @Test
    func graphiteBatchesPreserveDuplicateObjectsAndIsolateMalformedPayloads() throws {
        let fixture = try RecordedParentRepository()
        let shared = try fixture.graphiteJSON("first", payload: "{\"parentBranchName\":\"parent/é\"}")
        try fixture.git(["update-ref", "refs/branch-metadata/second", shared])
        try fixture.graphiteJSON("empty", payload: "")
        try fixture.graphiteJSON("binary", payload: "\0invalid")
        try fixture.graphite("third", parent: "second")

        let snapshot = try fixture.read()

        #expect(snapshot.parents == ["first": "parent/é", "second": "parent/é", "third": "second"])
        #expect(snapshot.diagnostics == ["Local Graphite metadata is malformed."])
    }

    @Test
    func matchingSourcesCoalesceAcrossBothToolsAndConfig() throws {
        let fixture = try RecordedParentRepository()
        let linked = try fixture.addWorktree(branch: "unopened")
        try fixture.ghStack(trunk: "main", branches: ["parent", "child"])
        try fixture.ghStack(trunk: "parent", branches: ["child", "next"], checkout: linked)
        try fixture.graphite("child", parent: "parent")
        try fixture.git(["config", "branch.parent.base", "main"])
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["parent": "main", "child": "parent", "next": "child"])
        #expect(snapshot.trunkBranches == ["main", "parent"])
        #expect(snapshot.issue == nil)
    }

    @Test
    func explicitConfigOverridesEveryConflictingToolCandidate() throws {
        let fixture = try RecordedParentRepository()
        let linked = try fixture.addWorktree(branch: "unopened")
        try fixture.ghStack(trunk: "gh-first", branches: ["child", "descendant"])
        try fixture.ghStack(trunk: "gh-second", branches: ["child"], checkout: linked)
        try fixture.graphite("child", parent: "graphite-parent")
        try fixture.git(["config", "branch.child.base", "explicit-parent"])
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["child": "explicit-parent", "descendant": "child"])
        #expect(snapshot.issue == nil)
    }

    @Test
    func genuineToolConflictsExcludeOnlyTheConflictingIncomingEdge() throws {
        let fixture = try RecordedParentRepository()
        try fixture.ghStack(trunk: "gh-parent", branches: ["child", "descendant"])
        try fixture.graphite("child", parent: "graphite-parent")
        try fixture.graphite("independent", parent: "other")
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["descendant": "child", "independent": "other"])
        #expect(Set(snapshot.conflicts.keys) == ["child"])
        #expect(snapshot.diagnostics.isEmpty)
        #expect(snapshot.issue?.contains("'child'") == true)
        #expect(snapshot.issue?.contains("'gh-parent'") == true)
        #expect(snapshot.issue?.contains("'graphite-parent'") == true)
    }

    @Test
    func longConflictNamesRemainIdentifiableWithoutFloodingTheSummary() throws {
        let fixture = try RecordedParentRepository()
        let linked = try fixture.addWorktree(branch: "tracker")
        let child = "feature/" + String(repeating: "é", count: 1_000) + "/child"
        let firstParent = "first/" + String(repeating: "a", count: 2_000) + "/parent-a"
        let secondParent = "second/" + String(repeating: "b", count: 2_000) + "/parent-b"
        try fixture.ghStack(trunk: firstParent, branches: [child])
        try fixture.ghStack(trunk: secondParent, branches: [child], checkout: linked)
        let snapshot = try fixture.read()
        let message = try #require(snapshot.conflicts[child])
        #expect(message.contains("feature/"))
        #expect(message.contains("/child"))
        #expect(message.contains("first/") && message.contains("/parent-a"))
        #expect(message.contains("second/") && message.contains("/parent-b"))
        #expect(!message.contains("�"))
        #expect(message.utf8.count < 512)
        #expect((snapshot.issue?.utf8.count ?? 0) < 512)
    }

    @Test(arguments: [false, true])
    func cycleValidationHappensAfterExplicitPrecedence(_ override: Bool) throws {
        let fixture = try RecordedParentRepository()
        try fixture.graphite("first", parent: "second")
        try fixture.ghStack(trunk: "first", branches: ["second", "descendant"])
        try fixture.git(["config", "branch.independent.base", "missing-parent"])
        if override { try fixture.git(["config", "branch.first.base", "root"]) }
        let snapshot = try fixture.read()
        if override {
            #expect(
                snapshot.parents == [
                    "first": "root", "second": "first", "descendant": "second", "independent": "missing-parent"
                ])
            #expect(snapshot.issue == nil)
        } else {
            #expect(snapshot.parents == ["descendant": "second", "independent": "missing-parent"])
            #expect(Set(snapshot.conflicts.keys) == ["first", "second"])
        }
    }

    @Test
    func explicitConfigCyclesAreAlsoExcluded() throws {
        let fixture = try RecordedParentRepository()
        try fixture.git(["config", "branch.first.base", "second"])
        try fixture.git(["config", "branch.second.base", "first"])
        try fixture.git(["config", "branch.descendant.base", "first"])
        let snapshot = try fixture.read()
        #expect(snapshot.parents == ["descendant": "first"])
        #expect(Set(snapshot.conflicts.keys) == ["first", "second"])
        #expect(snapshot.conflicts["first"]?.contains("'first'") == true)
        #expect(snapshot.conflicts["first"]?.contains("'second'") == true)
    }
}

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
            : "{\"schemaVersion\":1,\"stacks\":[{\"trunk\":{\"branch\":\"parent\"},\"branches\":[{\"branch\":\"child\"}]}]}"
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

private final class RecordedParentRepository {
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
        try graphiteJSON(branch, payload: String(decoding: data, as: UTF8.self))
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
        try writeGhStackJSON(String(decoding: data, as: UTF8.self), checkout: checkout)
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

private struct RecordedParentFixtureFile: Equatable {
    let data: Data?
    let modified: Date?
}
