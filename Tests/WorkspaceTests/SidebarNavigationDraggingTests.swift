import AppKit
import Testing

@testable import Argus

@Suite
@MainActor
struct SidebarNavigationDraggingTests {
    @Test
    func typedProjectDropsMoveWholeBlocksWithoutChangingSelectionAndRejectStaleSources() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let other = Project(repositoryPath: fixture.root.appendingPathComponent("other").path, mainBranch: "main")
        manager.projects.insert(other, at: 0)
        let first = try #require(manager.createCollection(name: "First"))
        let second = try #require(manager.createCollection(name: "Second"))
        let selection = manager.selectedWorkspaceId
        let workspaceOrder = fixture.project.workspaceIds
        let drag = manager.projectDrag(fixture.project.id)
        #expect(manager.applyNavigationDrop(drag, to: .collection(first.id), after: false))
        #expect(!manager.applyNavigationDrop(drag, to: .collection(second.id), after: false))
        #expect(manager.collection(containing: fixture.project.id)?.id == first.id)
        #expect(
            manager.applyNavigationDrop(manager.projectDrag(other.id), to: .project(fixture.project.id), after: true))
        #expect(manager.projects(in: first.id).map(\.id) == [fixture.project.id, other.id])
        #expect(
            manager.applyNavigationDrop(manager.projectDrag(other.id), to: .project(fixture.project.id), after: false))
        #expect(manager.projects(in: first.id).map(\.id) == [other.id, fixture.project.id])
        #expect(manager.applyNavigationDrop(manager.projectDrag(other.id), to: .collection(second.id), after: false))
        #expect(manager.applyNavigationDrop(manager.projectDrag(fixture.project.id), to: .otherProjects, after: false))
        #expect(manager.ungroupedProjects.map(\.id) == [fixture.project.id])
        #expect(manager.selectedWorkspaceId == selection)
        #expect(fixture.project.workspaceIds == workspaceOrder)
        #expect(
            !manager.applyNavigationDrop(
                manager.projectDrag(fixture.project.id), to: .project(fixture.project.id), after: true))
        #expect(
            !manager.applyNavigationDrop(
                manager.projectDrag(manager.catchAllProject.id), to: .collection(first.id), after: false))
        #expect(
            !manager.applyNavigationDrop(
                manager.projectDrag(fixture.project.id), to: .project(manager.catchAllProject.id), after: false))
        #expect(!manager.applyNavigationDrop(manager.projectDrag(UUID()), to: .collection(first.id), after: false))
        #expect(
            !manager.applyNavigationDrop(manager.projectDrag(fixture.project.id), to: .collection(UUID()), after: false)
        )
    }

    @Test
    func collectionDropsReorderBothDirectionsAndRejectWrongOrStaleTargets() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let first = try #require(manager.createCollection(name: "First"))
        let second = try #require(manager.createCollection(name: "Second"))
        let third = try #require(manager.createCollection(name: "Third"))
        let drag = manager.collectionDrag(first.id)
        #expect(manager.applyNavigationDrop(drag, to: .collection(third.id), after: true))
        #expect(manager.collections.map(\.id) == [second.id, third.id, first.id])
        #expect(!manager.applyNavigationDrop(drag, to: .collection(second.id), after: false))
        #expect(manager.applyNavigationDrop(manager.collectionDrag(first.id), to: .collection(second.id), after: false))
        #expect(manager.collections.map(\.id) == [first.id, second.id, third.id])
        #expect(
            !manager.applyNavigationDrop(
                manager.collectionDrag(first.id), to: .project(fixture.project.id), after: false))
        #expect(!manager.applyNavigationDrop(manager.collectionDrag(first.id), to: .otherProjects, after: false))
        #expect(!manager.applyNavigationDrop(manager.collectionDrag(first.id), to: .collection(first.id), after: false))
        #expect(!manager.applyNavigationDrop(manager.collectionDrag(UUID()), to: .collection(first.id), after: false))
    }

    @Test
    func dropFeedbackDistinguishesInsertionFromSectionAppend() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let collection = try #require(manager.createCollection(name: "Work"))
        let projectType = manager.projectDrag(fixture.project.id).typeIdentifier
        let collectionType = manager.collectionDrag(collection.id).typeIdentifier
        for after in [false, true] {
            let insertion = after ? SidebarNavigationDropPlacement.after : .before
            #expect(
                SidebarNavigationDropPlacement(
                    typeIdentifier: projectType, target: .project(fixture.project.id), after: after) == insertion)
            #expect(
                SidebarNavigationDropPlacement(
                    typeIdentifier: collectionType, target: .collection(collection.id), after: after) == insertion)
            #expect(
                SidebarNavigationDropPlacement(
                    typeIdentifier: projectType, target: .collection(collection.id), after: after) == .append)
            #expect(
                SidebarNavigationDropPlacement(
                    typeIdentifier: projectType, target: .otherProjects, after: after) == .append)
        }
    }

    @Test
    func mixedMultipleAndWorkspaceProvidersCannotEnterNavigationDrops() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let collection = try #require(manager.createCollection(name: "Work"))
        let projectDrag = manager.projectDrag(fixture.project.id)
        let collectionDrag = manager.collectionDrag(collection.id)
        let project = projectDrag.itemProvider
        let organizer = collectionDrag.itemProvider
        let workspace = NSItemProvider(object: fixture.child.id.uuidString as NSString)
        let target = SidebarNavigationDrop.collection(collection.id)
        #expect(SidebarNavigationDropValidation.provider(from: [project], target: target) != nil)
        #expect(SidebarNavigationDropValidation.provider(from: [organizer], target: target) != nil)
        #expect(SidebarNavigationDropValidation.provider(from: [workspace], target: target) == nil)
        #expect(SidebarNavigationDropValidation.provider(from: [project, organizer], target: target) == nil)
        #expect(SidebarNavigationDropValidation.provider(from: [project, workspace], target: target) == nil)
        #expect(SidebarNavigationDropValidation.provider(from: [project, project], target: target) == nil)
        #expect(
            SidebarNavigationDropValidation.provider(from: [organizer], target: .project(fixture.project.id)) == nil)
        let mixed = NSItemProvider()
        for type in [projectDrag.typeIdentifier, collectionDrag.typeIdentifier] {
            mixed.registerDataRepresentation(forTypeIdentifier: type, visibility: .ownProcess) { completion in
                completion(Data(), nil)
                return nil
            }
        }
        #expect(SidebarNavigationDropValidation.provider(from: [mixed], target: target) == nil)
        #expect(projectDrag.typeIdentifier != collectionDrag.typeIdentifier)
    }
}
