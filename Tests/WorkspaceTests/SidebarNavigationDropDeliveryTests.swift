import AppKit
import Testing

@testable import Argus

@Suite
@MainActor
struct SidebarNavigationDropDeliveryTests {
    enum DestinationChange: CaseIterable, Sendable {
        case none, membership, projectOrder, collectionOrder, removeProject, removeCollection
    }

    @Test(arguments: DestinationChange.allCases)
    func asynchronousDeliveryRejectsChangedDestinationWithoutRedirectingSource(change: DestinationChange) async throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let first = try #require(manager.createCollection(name: "First"))
        let second = try #require(manager.createCollection(name: "Second"))
        let target = Project(repositoryPath: fixture.root.appendingPathComponent("target").path, mainBranch: "main")
        let sibling = Project(repositoryPath: fixture.root.appendingPathComponent("sibling").path, mainBranch: "main")
        manager.projects.insert(contentsOf: [target, sibling], at: 0)
        manager.moveProject(target.id, toCollection: first.id)
        manager.moveProject(sibling.id, toCollection: first.id)
        let drag = manager.projectDrag(fixture.project.id)
        let context = try #require(manager.navigationDropContext(for: .project(target.id)))
        let delayed = DelayedNavigationProvider(typeIdentifier: drag.typeIdentifier)
        let delivery = Task {
            await manager.loadNavigationDrop(
                from: delayed.provider, typeIdentifier: drag.typeIdentifier, context: context, after: true)
        }
        await waitForStackState { delayed.isRequested }
        switch change {
        case .none: break
        case .membership: manager.moveProject(target.id, toCollection: second.id)
        case .projectOrder: manager.moveProject(target.id, offset: 1)
        case .collectionOrder: manager.moveCollection(first.id, offset: 1)
        case .removeProject: await manager.removeProject(target.id)
        case .removeCollection: manager.removeCollection(first.id)
        }
        delayed.complete(with: try JSONEncoder().encode(drag))
        #expect(await delivery.value == (change == .none))
        #expect(manager.collection(containing: fixture.project.id)?.id == (change == .none ? first.id : nil))
        if change == .none {
            #expect(manager.projects(in: first.id).map(\.id) == [target.id, fixture.project.id, sibling.id])
        }
        #expect(manager.selectedWorkspaceId == fixture.child.id)
    }
}

/// Holds the real NSItemProvider callback until the test changes the destination.
private final class DelayedNavigationProvider: @unchecked Sendable {
    let provider = NSItemProvider()
    private let lock = NSLock()
    private var completion: (@Sendable (Data?, (any Error)?) -> Void)?

    var isRequested: Bool { lock.withLock { completion != nil } }

    init(typeIdentifier: String) {
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { [weak self] in
            self?.setCompletion($0)
            return nil
        }
    }

    private func setCompletion(_ completion: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        lock.withLock { self.completion = completion }
    }

    func complete(with data: Data) {
        let callback = lock.withLock {
            let callback = completion
            completion = nil
            return callback
        }
        callback?(data, nil)
    }
}
