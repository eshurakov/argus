import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    fileprivate static let argusProject = UTType(exportedAs: "com.argus.sidebar-project", conformingTo: .data)
    fileprivate static let argusCollection = UTType(exportedAs: "com.argus.sidebar-collection", conformingTo: .data)
}

struct SidebarProjectDrag: Codable, Equatable, Sendable {
    let projectId: UUID
    let sourceCollectionId: UUID?
    let sourceOrder: [UUID]
}

struct SidebarCollectionDrag: Codable, Equatable, Sendable {
    let collectionId: UUID
    let sourceOrder: [UUID]
}

enum SidebarNavigationDrag: Codable, Equatable, Sendable {
    case project(SidebarProjectDrag)
    case collection(SidebarCollectionDrag)

    var typeIdentifier: String {
        switch self {
        case .project: UTType.argusProject.identifier
        case .collection: UTType.argusCollection.identifier
        }
    }

    var itemProvider: NSItemProvider {
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

enum SidebarNavigationDrop: Equatable, Sendable {
    case project(UUID)
    case collection(UUID)
    case otherProjects
}

struct SidebarNavigationDropContext: Equatable, Sendable {
    let target: SidebarNavigationDrop
    let collectionId: UUID?
    let projectOrder: [UUID]
    let collectionOrder: [UUID]
}

extension WorkspaceManager {
    func navigationDropContext(for target: SidebarNavigationDrop) -> SidebarNavigationDropContext? {
        let collectionId: UUID?
        switch target {
        case .project(let projectId):
            guard namedProjects.contains(where: { $0.id == projectId }) else { return nil }
            collectionId = collection(containing: projectId)?.id
        case .collection(let id):
            guard collections.contains(where: { $0.id == id }) else { return nil }
            collectionId = id
        case .otherProjects:
            collectionId = nil
        }
        return SidebarNavigationDropContext(
            target: target, collectionId: collectionId,
            projectOrder: projects(in: collectionId).map(\.id), collectionOrder: collections.map(\.id))
    }

    /// Capture the destination before the asynchronous provider read. Completion
    /// must not redirect a drop to a target's newly changed Collection or position.
    func loadNavigationDrop(
        from provider: NSItemProvider, typeIdentifier: String,
        context: SidebarNavigationDropContext, after: Bool
    ) async -> Bool {
        let data: Data? = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data, data.count <= 32_768,
            let drag = try? JSONDecoder().decode(SidebarNavigationDrag.self, from: data),
            drag.typeIdentifier == typeIdentifier,
            navigationDropContext(for: context.target) == context
        else { return false }
        return applyNavigationDrop(drag, to: context.target, after: after)
    }

    func projectDrag(_ projectId: UUID) -> SidebarNavigationDrag {
        let collectionId = collection(containing: projectId)?.id
        return .project(
            SidebarProjectDrag(
                projectId: projectId, sourceCollectionId: collectionId,
                sourceOrder: projects(in: collectionId).map(\.id)))
    }

    func collectionDrag(_ collectionId: UUID) -> SidebarNavigationDrag {
        .collection(SidebarCollectionDrag(collectionId: collectionId, sourceOrder: collections.map(\.id)))
    }

    /// Validate against live identity and source order at drop time. A stale or
    /// mixed drag cannot silently move a different block or change resource ownership.
    @discardableResult
    func applyNavigationDrop(_ drag: SidebarNavigationDrag, to target: SidebarNavigationDrop, after: Bool) -> Bool {
        switch drag {
        case .project(let source):
            guard namedProjects.contains(where: { $0.id == source.projectId }),
                collection(containing: source.projectId)?.id == source.sourceCollectionId,
                projects(in: source.sourceCollectionId).map(\.id) == source.sourceOrder
            else { return false }
            switch target {
            case .project(let targetId):
                guard targetId != source.projectId, namedProjects.contains(where: { $0.id == targetId }) else {
                    return false
                }
                let destinationId = collection(containing: targetId)?.id
                let siblings = projects(in: destinationId).filter { $0.id != source.projectId }
                guard let index = siblings.firstIndex(where: { $0.id == targetId }) else { return false }
                return moveProject(source.projectId, toCollection: destinationId, at: index + (after ? 1 : 0))
            case .collection(let collectionId):
                return moveProject(source.projectId, toCollection: collectionId)
            case .otherProjects:
                return moveProject(source.projectId, toCollection: nil)
            }
        case .collection(let source):
            guard source.sourceOrder == collections.map(\.id),
                let sourceIndex = collections.firstIndex(where: { $0.id == source.collectionId }),
                case .collection(let targetId) = target,
                targetId != source.collectionId,
                let targetIndex = collections.firstIndex(where: { $0.id == targetId })
            else { return false }
            let index = targetIndex - (sourceIndex < targetIndex ? 1 : 0) + (after ? 1 : 0)
            return reorderCollection(source.collectionId, to: index)
        }
    }
}

struct SidebarNavigationDropTarget: ViewModifier {
    let target: SidebarNavigationDrop
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @State private var placement: SidebarNavigationDropPlacement?
    @State private var targetHeight: CGFloat = 28

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                targetHeight = $0
            }
            .overlay {
                if placement == .append {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1) }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: placement == .after ? .bottom : .top) {
                if placement == .before || placement == .after {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onDrop(
                of: [.argusProject, .argusCollection],
                delegate: SidebarNavigationDropDelegate(
                    manager: workspaceManager, target: target, targetHeight: targetHeight, placement: $placement)
            )
    }
}

private struct SidebarNavigationDropDelegate: DropDelegate {
    let manager: WorkspaceManager
    let target: SidebarNavigationDrop
    let targetHeight: CGFloat
    @Binding var placement: SidebarNavigationDropPlacement?

    func validateDrop(info: DropInfo) -> Bool { provider(in: info) != nil }

    func dropEntered(info: DropInfo) { updatePlacement(info: info) }
    func dropExited(info: DropInfo) { placement = nil }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        updatePlacement(info: info)
        return DropProposal(operation: placement != nil ? .move : .forbidden)
    }

    private func updatePlacement(info: DropInfo) {
        placement = provider(in: info).map { _, type in
            SidebarNavigationDropPlacement(
                typeIdentifier: type, target: target, after: info.location.y > targetHeight / 2)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        placement = nil
        guard let (provider, type) = provider(in: info),
            let context = manager.navigationDropContext(for: target)
        else { return false }
        let after = info.location.y > targetHeight / 2
        Task { @MainActor in
            await manager.loadNavigationDrop(from: provider, typeIdentifier: type, context: context, after: after)
        }
        return true
    }

    private func provider(in info: DropInfo) -> (NSItemProvider, String)? {
        let providers = info.itemProviders(for: [.item])
        return SidebarNavigationDropValidation.provider(from: providers, target: target)
    }
}

enum SidebarNavigationDropValidation {
    static func provider(from providers: [NSItemProvider], target: SidebarNavigationDrop) -> (NSItemProvider, String)? {
        guard providers.count == 1, let provider = providers.first else { return nil }
        let types = [UTType.argusProject.identifier, UTType.argusCollection.identifier]
            .filter { provider.hasItemConformingToTypeIdentifier($0) }
        guard types.count == 1, let type = types.first,
            !provider.hasItemConformingToTypeIdentifier(UTType.text.identifier)
        else { return nil }
        if type == UTType.argusCollection.identifier, case .collection = target { return (provider, type) }
        return type == UTType.argusProject.identifier ? (provider, type) : nil
    }
}

enum SidebarNavigationDropPlacement: Equatable {
    case before
    case after
    case append

    init(typeIdentifier: String, target: SidebarNavigationDrop, after: Bool) {
        if typeIdentifier == UTType.argusProject.identifier {
            // Project drops append when the destination is a section rather than another Project.
            switch target {
            case .collection, .otherProjects:
                self = .append
                return
            case .project:
                break
            }
        }
        self = after ? .after : .before
    }
}
