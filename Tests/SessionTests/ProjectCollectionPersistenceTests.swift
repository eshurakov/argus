import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct ProjectCollectionPersistenceTests {
    @Test
    func userMutationsCheckpointAndRoundTripWithNoSchemaChange() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let collection = try #require(manager.createCollection(name: "Client API"))
        #expect(try saved(manager).collections?.first?.name == "Client API")
        manager.renameCollection(collection.id, name: "Client aPI")
        #expect(try saved(manager).collections?.first?.name == "Client aPI")
        manager.moveProject(fixture.project.id, toCollection: collection.id)
        #expect(try saved(manager).collections?.first?.projectIds == [fixture.project.id])
        manager.toggleCollection(collection.id)
        #expect(try saved(manager).collections?.first?.isExpanded == false)
        let empty = try #require(manager.createCollection(name: "Empty"))
        manager.moveCollection(empty.id, offset: -1)
        let snapshot = try saved(manager)
        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.collections?.map(\.id) == [empty.id, collection.id])
        let restored = WorkspaceManager(
            settings: manager.settings, sessionSnapshotURL: fixture.root.appendingPathComponent("restored.json"),
            environment: ["ARGUS_UNDER_TEST": "1"])
        #expect(restored.restoreSession(from: snapshot))
        #expect(restored.collections == manager.collections)
        #expect(restored.selectedWorkspaceId == manager.selectedWorkspaceId)
        #expect(restored.sidebarOrderedProjects.map(\.id) == manager.sidebarOrderedProjects.map(\.id))
        restored.removeCollection(collection.id)
        #expect(try saved(restored).collections?.map(\.id) == [empty.id])
        #expect(restored.ungroupedProjects.map(\.id) == [fixture.project.id])
    }

    @Test
    func legacyJSONAndOptionalDisclosureRestoreWithoutDiscardingSession() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let data = try JSONEncoder().encode(manager.makeSessionSnapshot())
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "collections")
        let legacy = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(manager.restoreSession(from: legacy))
        #expect(manager.collections.isEmpty)
        #expect(manager.namedProjects.map(\.id) == [fixture.project.id])
        let id = UUID()
        json["collections"] = [["id": id.uuidString, "name": "Legacy", "projectIds": [fixture.project.id.uuidString]]]
        let optional = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(manager.restoreSession(from: optional))
        #expect(manager.collections.first?.isExpanded == true)
        #expect(manager.collections.first?.id == id)
    }

    @Test
    func reconciliationDropsStaleDuplicateAndCatchAllMembershipButKeepsEmptyCollections() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let original = fixture.manager.makeSessionSnapshot()
        let first = ProjectCollection(
            name: "First",
            projectIds: [
                UUID(), fixture.manager.catchAllProject.id, fixture.project.id, fixture.project.id
            ], isExpanded: false)
        let second = ProjectCollection(name: "Second", projectIds: [fixture.project.id])
        let invalid = ProjectCollection(name: " \n")
        let snapshot = ArgusSessionSnapshot(
            selectedWorkspaceId: original.selectedWorkspaceId, projects: original.projects,
            workspaces: original.workspaces,
            collections: [first, first, invalid, second])
        #expect(snapshot.isValidForRestore(maxWorkspaces: 128))
        let reconciled = snapshot.reconciledForRestore()
        #expect(
            reconciled.collections == [
                ProjectCollection(id: first.id, name: first.name, projectIds: [fixture.project.id], isExpanded: false),
                ProjectCollection(id: second.id, name: second.name)
            ])
        #expect(reconciled.reconciledForRestore().collections == reconciled.collections)
        #expect(fixture.manager.restoreSession(from: snapshot))
        #expect(fixture.manager.workspaces.count == original.workspaces.count)
        #expect(fixture.manager.sidebarOrderedProjects.map(\.id) == [fixture.project.id, original.projects.last?.id])
    }

    @Test
    func decodingBoundsCollectionCountAndMembership() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let original = try JSONEncoder().encode(fixture.manager.makeSessionSnapshot())
        var json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        let members = (0..<200).map { _ in UUID().uuidString }
        json["collections"] = (0..<200).map { index in
            ["id": UUID().uuidString, "name": "Collection \(index)", "projectIds": members] as [String: Any]
        }
        let decoded = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.collections?.count == 128)
        #expect(decoded.collections?.allSatisfy { $0.projectIds.count == 128 } == true)
        #expect(fixture.manager.restoreSession(from: decoded))
        #expect(fixture.manager.collections.count == 128)
        #expect(fixture.manager.collections.allSatisfy { $0.projectIds.isEmpty })
    }

    @Test(arguments: [false, true])
    func collectionLimitCountsOnlyValidUniqueRecords(decodeJSON: Bool) throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let original = fixture.manager.makeSessionSnapshot()
        let first = ProjectCollection(name: "First", projectIds: [fixture.project.id], isExpanded: false)
        let later = ProjectCollection(name: "Later")
        let invalid = (0..<128).map { index in
            ProjectCollection(id: first.id, name: index.isMultiple(of: 2) ? " \n" : String(repeating: "a", count: 4097))
        }
        let duplicate = ProjectCollection(id: first.id, name: "Duplicate", projectIds: [UUID()])
        let records = invalid + [first] + Array(repeating: duplicate, count: 128) + [later]
        let snapshot: ArgusSessionSnapshot
        if decodeJSON {
            var json = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            json["collections"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records))
            snapshot = try JSONDecoder().decode(
                ArgusSessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        } else {
            snapshot = ArgusSessionSnapshot(
                selectedWorkspaceId: original.selectedWorkspaceId, projects: original.projects,
                workspaces: original.workspaces, collections: records)
        }
        #expect(snapshot.collections == [first, later])
        #expect(ProjectCollection.reconciled(records, namedProjectIds: [fixture.project.id]) == [first, later])
        #expect(snapshot.isValidForRestore(maxWorkspaces: 128))
        #expect(fixture.manager.restoreSession(from: snapshot))
        #expect(fixture.manager.collections == [first, later])
    }

    @Test
    func inMemoryCollectionLimitRetainsFirst128ValidRecords() {
        let records = (0..<200).map { ProjectCollection(name: "Collection \($0)") }
        let expected = Array(records.prefix(128))
        let snapshot = ArgusSessionSnapshot(
            selectedWorkspaceId: nil, projects: [], workspaces: [], collections: records)
        #expect(snapshot.collections == expected)
        #expect(ProjectCollection.reconciled(records, namedProjectIds: []) == expected)
    }

    @Test
    func malformedOptionalCollectionsPreserveCoreSessionAndValidSiblings() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let sibling = Project(repositoryPath: fixture.root.appendingPathComponent("sibling").path, mainBranch: "main")
        manager.projects.insert(sibling, at: 0)
        let original = manager.makeSessionSnapshot()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        let firstId = UUID()
        let secondId = UUID()
        json["collections"] =
            [
                ["id": "not-a-uuid", "name": "Invalid", "projectIds": []],
                [
                    "id": firstId.uuidString, "name": "First", "isExpanded": "wrong-type",
                    "projectIds": ["bad-uuid", 123, NSNull(), fixture.project.id.uuidString]
                ],
                "not-a-record", NSNull(),
                ["id": UUID().uuidString, "name": 42, "projectIds": []],
                ["id": secondId.uuidString, "name": "Second", "projectIds": [sibling.id.uuidString]]
            ] as [Any]
        let decoded = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(manager.restoreSession(from: decoded))
        #expect(manager.workspaces.map(\.id) == original.workspaces.map(\.id))
        #expect(manager.projects.map(\.id) == original.projects.map(\.id))
        #expect(manager.selectedWorkspaceId == original.selectedWorkspaceId)
        #expect(
            manager.collections == [
                ProjectCollection(id: firstId, name: "First", projectIds: [fixture.project.id]),
                ProjectCollection(id: secondId, name: "Second", projectIds: [sibling.id])
            ])
        for malformed in [42, "not-an-array", ["wrong": "shape"]] as [Any] {
            json["collections"] = malformed
            let malformedSnapshot = try JSONDecoder().decode(
                ArgusSessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(manager.restoreSession(from: malformedSnapshot))
            #expect(manager.collections.isEmpty)
            #expect(manager.workspaces.map(\.id) == original.workspaces.map(\.id))
        }
    }

    private func saved(_ manager: WorkspaceManager) throws -> ArgusSessionSnapshot {
        try JSONDecoder().decode(ArgusSessionSnapshot.self, from: Data(contentsOf: manager.sessionSnapshotURL))
    }
}
