import Foundation

/// A non-owning, single-level navigation organizer. Membership lives only here,
/// never on Project, and cannot include the Catch-all Project.
struct ProjectCollection: Codable, Identifiable, Equatable, Sendable {
    static let maximumCount = 128
    static let maximumNameBytes = 4096

    let id: UUID
    var name: String
    var projectIds: [UUID]
    var isExpanded: Bool

    init(id: UUID = UUID(), name: String, projectIds: [UUID] = [], isExpanded: Bool = true) {
        self.id = id
        self.name = name
        self.projectIds = projectIds
        self.isExpanded = isExpanded
    }

    static func normalizedName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumNameBytes else { return nil }
        return trimmed
    }

    /// Only valid, unique records consume the Collection limit.
    static func bounded(_ collections: [Self]) -> [Self] {
        var seenCollections = Set<UUID>()
        var result: [Self] = []
        for var collection in collections {
            guard result.count < maximumCount else { break }
            guard let name = normalizedName(collection.name),
                seenCollections.insert(collection.id).inserted
            else { continue }
            collection.name = name
            result.append(collection)
        }
        return result
    }

    /// First valid occurrence wins, both for identity and membership. Preserve
    /// empty user-created Collections; stale references do not delete an organizer.
    static func reconciled(_ collections: [Self], namedProjectIds: Set<UUID>) -> [Self] {
        var seenProjects = Set<UUID>()
        return bounded(collections).map { collection in
            let members = collection.projectIds.filter {
                namedProjectIds.contains($0) && seenProjects.insert($0).inserted
            }
            return Self(
                id: collection.id, name: collection.name, projectIds: members, isExpanded: collection.isExpanded)
        }
    }

    static func decodeList(from decoder: Decoder) throws -> [Self] {
        var values = try decoder.unkeyedContainer()
        var result: [Self] = []
        var seenCollections = Set<UUID>()
        while !values.isAtEnd {
            // Consume each element before decoding so a malformed optional
            // record cannot reject the core session or stall this loop.
            let element = try values.superDecoder()
            guard result.count < maximumCount,
                var collection = try? Self(from: element),
                let name = normalizedName(collection.name),
                seenCollections.insert(collection.id).inserted
            else { continue }
            collection.name = name
            result.append(collection)
        }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, projectIds, isExpanded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isExpanded = (try? container.decode(Bool.self, forKey: .isExpanded)) ?? true
        var ids: [UUID] = []
        if var members = try? container.nestedUnkeyedContainer(forKey: .projectIds) {
            while !members.isAtEnd {
                let member = try members.superDecoder()
                if let id = try? UUID(from: member), ids.count < Self.maximumCount { ids.append(id) }
            }
        }
        projectIds = ids
    }
}
