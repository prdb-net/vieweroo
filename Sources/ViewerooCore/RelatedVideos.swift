import Foundation

public struct RelatedVideo: Identifiable, Sendable {
    public let entry: CatalogEntry
    public let subtitle: String?
    public var id: Int64 { entry.id }

    public static func canOffer(_ entry: CatalogEntry, for current: CatalogEntry) -> Bool {
        entry.libraryID == current.libraryID && entry.id != current.id
            && entry.availability == .available && entry.playbackFailure == nil
    }

    /// Prefer local metadata connections. Starting just after the current entry also lets
    /// someone browse forward through an entirely unmatched library.
    public static func suggestions(for current: CatalogEntry, in entries: [CatalogEntry]) -> [RelatedVideo] {
        guard let start = entries.firstIndex(where: { $0.id == current.id }) else { return [] }
        let performers = Set(current.match?.performers.map(\.id) ?? [])
        let studio = current.studio?.lowercased()
        let tags = Set(current.tags.map { $0.lowercased() })
        let limit = 8
        enum Connection: Int, CaseIterable { case studio, performer, tag, library }
        let strongestConnection: Connection
        if studio != nil { strongestConnection = .studio }
        else if !performers.isEmpty { strongestConnection = .performer }
        else if !tags.isEmpty { strongestConnection = .tag }
        else { strongestConnection = .library }
        var groups = Array(repeating: [RelatedVideo](), count: Connection.allCases.count)
        for offset in 1..<entries.count {
            let candidate = entries[(start + offset) % entries.count]
            guard canOffer(candidate, for: current) else { continue }
            let connection: Connection
            let subtitle: String?
            if let studio, studio == candidate.studio?.lowercased() {
                connection = .studio
                subtitle = candidate.studio
            } else if !performers.isEmpty, let person = candidate.match?.performers.first(where: { performers.contains($0.id) }) {
                connection = .performer
                subtitle = "With \(person.name)"
            } else if !tags.isEmpty, let tag = candidate.tags.first(where: { tags.contains($0.lowercased()) }) {
                connection = .tag
                subtitle = "Tagged \(tag)"
            } else {
                connection = .library
                subtitle = candidate.studio
            }
            if groups[connection.rawValue].count < limit {
                groups[connection.rawValue].append(RelatedVideo(entry: candidate, subtitle: subtitle))
            }
            if groups[strongestConnection.rawValue].count == limit { break }
        }
        return Array(groups.joined().prefix(limit))
    }
}
