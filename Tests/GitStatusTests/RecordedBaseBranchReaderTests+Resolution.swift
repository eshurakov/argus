import Foundation
import Testing

@testable import Argus

extension RecordedBaseBranchReaderTests {
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
