import Foundation
import GRDB

public struct CatalogEntry: Hashable, Identifiable, Sendable {
    public let id: Int64
    public let libraryID: Int64
    public let path: String
    public let fileSize: Int64
    public let modified: Double
    public let hash: String?
    public let needsLookup: Bool
    public let confirmed: Bool
    public let match: PRDBTitle?
    public let candidates: [PRDBTitle]
    public let manualStudio: String?
    public let detectedStudio: String?
    public let favorite: Bool
    public let rating: Int
    public let tags: [String]
    public let resume: Double
    public let playCount: Int
    public let watchTime: Double
    public let duration: Double?
    public let weightedPlays: Double
    public let availability: CatalogAvailability
    public let playbackFailure: String?

    public var url: URL { URL(fileURLWithPath: path, isDirectory: false) }
    public var filename: String { url.lastPathComponent }
    public var title: String { match?.title ?? url.deletingPathExtension().lastPathComponent }
    public var studio: String? { manualStudio ?? match?.studio?.name ?? detectedStudio }

    init(_ row: Row) throws {
        id = row["id"]
        libraryID = row["libraryID"]
        path = row["path"]
        fileSize = row["fileSize"]
        modified = row["modified"]
        hash = row["hash"]
        favorite = row["favorite"]
        rating = row["rating"]
        manualStudio = row["manualStudio"]
        detectedStudio = row["detectedStudio"]
        resume = row["resume"]
        confirmed = row["confirmed"]
        needsLookup = row["needsLookup"]
        playCount = row["playCount"]
        watchTime = row["watchTime"]
        duration = row["duration"]
        weightedPlays = row["weightedPlays"]
        availability = CatalogAvailability(rawValue: row["availability"]) ?? .missing
        playbackFailure = row["playbackFailure"]
        let decoder = JSONDecoder()
        let titleData: Data? = row["matchData"]
        match = try titleData.map { try decoder.decode(PRDBTitle.self, from: $0) }
        let candidateData: Data? = row["candidateData"]
        candidates = try candidateData.map { try decoder.decode([PRDBTitle].self, from: $0) } ?? []
        let tagJSON: String = row["tags"]
        tags = try decoder.decode([String].self, from: Data(tagJSON.utf8))
    }
}

public struct LibrarySnapshot: Sendable {
    public let libraries: [CatalogLibrary]
    public let sources: [CatalogSource]
    public let entries: [CatalogEntry]
    public let playlists: [CatalogPlaylist]
}

extension Catalog {
    static let entryQuery = """
        SELECT e.*,
            (SELECT json_group_array(name) FROM
                (SELECT name FROM entryTag WHERE entryID = e.id ORDER BY name COLLATE NOCASE)) AS tags,
            (SELECT COUNT(*) FROM \(visibleSessions) s WHERE s.entryID = e.id) AS playCount,
            (SELECT COALESCE(SUM(s.watchTime),0) FROM \(visibleSessions) s
                WHERE s.entryID = e.id) AS watchTime,
            \(weightedPlaysQuery) AS weightedPlays,
            CASE WHEN EXISTS(SELECT 1 FROM membership m JOIN source s ON s.id = m.sourceID
                WHERE m.entryID = e.id AND m.present AND s.online) THEN 'available'
            WHEN EXISTS(SELECT 1 FROM membership m JOIN source s ON s.id = m.sourceID
                WHERE m.entryID = e.id AND NOT s.online) THEN 'offline'
            ELSE 'missing' END AS availability
        FROM entry e
        """

    public func entry(_ id: Int64) throws -> CatalogEntry? {
        try database.read { db in try Self.fetchEntry(db, id: id) }
    }

    static func fetchEntry(_ db: Database, id: Int64) throws -> CatalogEntry? {
        try Row.fetchOne(db, sql: entryQuery + " WHERE e.id = ?", arguments: [id]).map(CatalogEntry.init)
    }

    public func entries(libraryID: Int64) throws -> [CatalogEntry] {
        try database.read { try Self.fetchEntries($0, libraryID: libraryID) }
    }

    static func fetchEntries(_ db: Database, libraryID: Int64) throws -> [CatalogEntry] {
        let rows = try Row.fetchCursor(db, sql: entryQuery + " WHERE e.libraryID = ? ORDER BY e.path COLLATE NOCASE",
                                       arguments: [libraryID])
        return try Array(rows.map(CatalogEntry.init))
    }

    /// Read a consistent browsing snapshot on the database queue, including metadata decoding.
    public func snapshot(libraryID: Int64?) async throws -> LibrarySnapshot {
        try await database.read { db in
            try LibrarySnapshot(libraries: Self.fetchLibraries(db),
                                sources: libraryID.map { try Self.fetchSources(db, libraryID: $0) } ?? [],
                                entries: libraryID.map { try Self.fetchEntries(db, libraryID: $0) } ?? [],
                                playlists: libraryID.map { try Self.fetchPlaylists(db, libraryID: $0) } ?? [])
        }
    }

    public func setDuration(_ duration: Double, for entry: CatalogEntry) throws {
        guard duration.isFinite, duration > 0 else { throw CatalogError.invalidValue }
        try database.write { db in
            try db.execute(sql: """
                UPDATE entry SET duration = ? WHERE id = ? AND fileSize = ? AND modified = ?
                """, arguments: [duration, entry.id, entry.fileSize, entry.modified])
        }
    }

    public func setDetectedStudio(entryID: Int64, name: String?, fileSize: Int64, modified: Double) throws {
        try database.write { db in
            try db.execute(sql: """
                UPDATE entry SET detectedStudio = ? WHERE id = ? AND fileSize = ? AND modified = ? AND needsLookup
                """, arguments: [name, entryID, fileSize, modified])
        }
    }

    public func setHash(entryID: Int64, hash: String?, fileSize: Int64, modified: Double) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE entry SET hash = ? WHERE id = ? AND fileSize = ? AND modified = ?",
                           arguments: [hash, entryID, fileSize, modified])
        }
    }

    public func setPlaybackFailure(entryID: Int64, message: String?, fileSize: Int64, modified: Double) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE entry SET playbackFailure = ? WHERE id = ? AND fileSize = ? AND modified = ?",
                           arguments: [message, entryID, fileSize, modified])
        }
    }

    public func applyMatch(entryID: Int64, result: PRDBMatch, fileSize: Int64, modified: Double) throws {
        let matchData = try result.autoTitle.map { try JSONEncoder().encode($0) }
        let candidateData = try JSONEncoder().encode(result.candidates)
        try database.write { db in
            try db.execute(sql: """
                UPDATE entry SET matchData = ?, candidateData = ?, detectedStudio = ?, needsLookup = 0
                WHERE id = ? AND fileSize = ? AND modified = ? AND NOT confirmed
                """, arguments: [matchData, candidateData, result.studio?.name, entryID, fileSize, modified])
        }
    }

    public func confirmMatch(entryID: Int64, title: PRDBTitle) throws {
        let data = try JSONEncoder().encode(title)
        try database.write { db in
            try db.execute(sql: "UPDATE entry SET matchData = ?, confirmed = 1, needsLookup = 0 WHERE id = ?",
                           arguments: [data, entryID])
        }
    }

    public func saveStudios(_ studios: [PRDBStudio]) throws {
        try database.write { db in
            for studio in studios {
                try db.execute(sql: """
                    INSERT INTO studio(id,name) VALUES (?,?) ON CONFLICT(id) DO UPDATE SET name = excluded.name
                    """, arguments: [studio.id, studio.name])
            }
        }
    }

    public func studios() throws -> [PRDBStudio] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT id,name FROM studio ORDER BY name COLLATE NOCASE")
                .map { PRDBStudio(id: $0["id"], name: $0["name"]) }
        }
    }
}
