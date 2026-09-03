import Foundation

extension WorkspaceManager {
    func collection(containing projectId: UUID) -> ProjectCollection? {
        collections.first { $0.projectIds.contains(projectId) }
    }

    func projects(in collectionId: UUID?) -> [Project] {
        guard let collectionId else { return ungroupedProjects }
        guard let collection = collections.first(where: { $0.id == collectionId }) else { return [] }
        return collection.projectIds.compactMap { id in namedProjects.first { $0.id == id } }
    }

    var ungroupedProjects: [Project] {
        let groupedIds = Set(collections.flatMap(\.projectIds))
        return namedProjects.filter { !groupedIds.contains($0.id) }
    }

    /// All navigation uses this order, regardless of Collection/Project/Stack disclosure.
    var sidebarOrderedProjects: [Project] {
        collections.flatMap { projects(in: $0.id) } + ungroupedProjects + projects.filter(\.isCatchAll)
    }

    var canCreateCollection: Bool { collections.count < ProjectCollection.maximumCount }

    @discardableResult
    func createCollection(name: String) -> ProjectCollection? {
        guard canCreateCollection, let name = ProjectCollection.normalizedName(name) else { return nil }
        let collection = ProjectCollection(name: name)
        collections.append(collection)
        saveSession()
        return collection
    }

    @discardableResult
    func renameCollection(_ collectionId: UUID, name: String) -> Bool {
        guard let index = collections.firstIndex(where: { $0.id == collectionId }),
            let name = ProjectCollection.normalizedName(name)
        else { return false }
        collections[index].name = name
        saveSession()
        return true
    }

    func toggleCollection(_ collectionId: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == collectionId }) else { return }
        for projectId in collections[index].projectIds { cancelPendingWorkspaceStackReveal(in: projectId) }
        collections[index].isExpanded.toggle()
        saveSession()
    }

    func revealCollection(containing projectId: UUID) {
        guard let index = collections.firstIndex(where: { $0.projectIds.contains(projectId) }),
            !collections[index].isExpanded
        else { return }
        collections[index].isExpanded = true
        saveSession()
    }

    func removeCollection(_ collectionId: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == collectionId }) else { return }
        let members = projects(in: collectionId)
        collections.remove(at: index)
        // Append as a block, preserving member order rather than old registry positions.
        placeUngroupedProjects(
            members,
            at: ungroupedProjects.filter { project in
                !members.contains { $0.id == project.id }
            }.count)
        saveSession()
    }

    /// A nil destination means Other Projects. A nil insertion index appends.
    /// This changes navigation only: no Workspace, Panel or resource lifecycle calls.
    @discardableResult
    func moveProject(_ projectId: UUID, toCollection collectionId: UUID?, at insertionIndex: Int? = nil) -> Bool {
        guard let project = namedProjects.first(where: { $0.id == projectId }),
            collectionId == nil || collections.contains(where: { $0.id == collectionId })
        else { return false }
        let destination = projects(in: collectionId).filter { $0.id != projectId }
        let index = insertionIndex ?? destination.count
        guard (0...destination.count).contains(index) else { return false }
        let previousOrder = projects(in: collectionId).map(\.id)
        var nextOrder = destination.map(\.id)
        nextOrder.insert(projectId, at: index)
        guard collection(containing: projectId)?.id != collectionId || previousOrder != nextOrder else { return false }
        for index in collections.indices { collections[index].projectIds.removeAll { $0 == projectId } }
        if let collectionId, let collectionIndex = collections.firstIndex(where: { $0.id == collectionId }) {
            collections[collectionIndex].projectIds = nextOrder
            if !collections[collectionIndex].isExpanded { cancelPendingWorkspaceStackReveal(in: projectId) }
        } else {
            placeUngroupedProjects([project], at: index)
        }
        saveSession()
        return true
    }

    func canMoveProject(_ projectId: UUID, offset: Int) -> Bool {
        guard offset == -1 || offset == 1 else { return false }
        let siblings = projects(in: collection(containing: projectId)?.id)
        guard let index = siblings.firstIndex(where: { $0.id == projectId }) else { return false }
        return siblings.indices.contains(index + offset)
    }

    @discardableResult
    func moveProject(_ projectId: UUID, offset: Int) -> Bool {
        guard canMoveProject(projectId, offset: offset) else { return false }
        let collectionId = collection(containing: projectId)?.id
        guard let index = projects(in: collectionId).firstIndex(where: { $0.id == projectId }) else { return false }
        return moveProject(projectId, toCollection: collectionId, at: index + offset)
    }

    func canMoveCollection(_ collectionId: UUID, offset: Int) -> Bool {
        guard offset == -1 || offset == 1,
            let index = collections.firstIndex(where: { $0.id == collectionId })
        else { return false }
        return collections.indices.contains(index + offset)
    }

    @discardableResult
    func moveCollection(_ collectionId: UUID, offset: Int) -> Bool {
        guard canMoveCollection(collectionId, offset: offset),
            let index = collections.firstIndex(where: { $0.id == collectionId })
        else { return false }
        return reorderCollection(collectionId, to: index + offset)
    }

    @discardableResult
    func reorderCollection(_ collectionId: UUID, to index: Int) -> Bool {
        guard let source = collections.firstIndex(where: { $0.id == collectionId }),
            collections.indices.contains(index), source != index
        else { return false }
        collections.insert(collections.remove(at: source), at: index)
        saveSession()
        return true
    }

    private func placeUngroupedProjects(_ moved: [Project], at index: Int) {
        let movedIds = Set(moved.map(\.id))
        var ungrouped = ungroupedProjects.filter { !movedIds.contains($0.id) }
        ungrouped.insert(contentsOf: moved, at: index)
        let ungroupedIds = Set(ungrouped.map(\.id))
        // Grouped registry positions are not navigation order; membership owns that order.
        projects =
            namedProjects.filter { !ungroupedIds.contains($0.id) }
            + ungrouped + projects.filter(\.isCatchAll)
    }
}
