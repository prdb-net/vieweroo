import Foundation
import GRDB
import os

public struct CatalogEntry: Hashable, Identifiable, Sendable {
    public let id: Int64
    public let libraryID: Int64
    public let path: String
    public let fileSize: Int64
    public let modified: Double
    public let hash: String?
    public let needsLookup: Bool
    /// A manual title decision, including an explicit choice to leave the entry unmatched.
    public let confirmed: Bool
    public let match: PRDBTitle?
    /// Suggested titles stay in the catalog until a view asks for them with `Catalog.candidates`.
    public let hasCandidates: Bool
    public let manualSiteID: String?
    public let manualStudio: String?
    public let detectedStudio: String?
    public let favorite: Bool
    public let rating: Int
    public let tags: [String]
    public let resume: Double
    public let playCount: Int
    public let watchTime: Double
    public let duration: Double?
    public let videoInfo: VideoInfo?
    public let weightedPlays: Double
    public let availability: CatalogAvailability
    public let playbackFailure: String?

    public var url: URL { URL(fileURLWithPath: path, isDirectory: false) }
    public var filename: String { url.lastPathComponent }
    public let localTitle: String?
    public let localDescription: String?
    public let posterRevision: String?
    public var title: String { localTitle ?? match?.title ?? url.deletingPathExtension().lastPathComponent }
    public var studio: String? { manualStudio ?? match?.studio?.name ?? detectedStudio }

    private static let log = Logger(subsystem: "net.prdb.vieweroo", category: "catalog")

    init(_ row: Row) throws {
        localTitle = row["localTitle"]
        localDescription = row["localDescription"]
        posterRevision = row["posterRevision"]
        id = row["id"]
        libraryID = row["libraryID"]
        path = row["path"]
        fileSize = row["fileSize"]
        modified = row["modified"]
        hash = row["hash"]
        favorite = row["favorite"]
        rating = row["rating"]
        manualSiteID = row["manualSiteID"]
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
        // Cached metadata must never keep the rest of the library from loading. An unreadable
        // value reads as absent: video info is probed again and the match can be found again.
        let id = self.id
        func cached<T: Decodable>(_ type: T.Type, _ column: String) -> T? {
            guard let data: Data = row[column] else { return nil }
            do { return try JSONDecoder().decode(type, from: data) }
            catch {
                Self.log.error("Ignoring unreadable \(column, privacy: .public) of entry \(id): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        videoInfo = cached(VideoInfo.self, "videoInfo")
        match = cached(PRDBTitle.self, "matchData")
        // An empty list is stored as the two bytes of "[]".
        hasCandidates = (row["candidateBytes"] as Int? ?? 0) > 2
        let decoder = JSONDecoder()
        let tagJSON: String = row["tags"]
        tags = try decoder.decode([String].self, from: Data(tagJSON.utf8))
    }
}

public struct LibrarySnapshot: Sendable {
    public let libraries: [CatalogLibrary]
    public let sources: [CatalogSource]
    public let entries: [CatalogEntry]
    public let studioCovers: [String: CatalogCover]
    public let favoriteStudioIDs: Set<String>
    public let studioOptions: [StudioOption]
    /// The studio choices this snapshot was read with, to pass to the next snapshot.
    public let studios: StudioOptionsCache?
    /// False when `studioOptions` came unchanged from the cache passed to `snapshot`.
    public let studioOptionsChanged: Bool
    public let tags: [CatalogTag]
    public let playlists: [CatalogPlaylist]
}

/// Studio choices of one library at a directory revision. Reading every PRDB site for
/// each snapshot is expensive, and the directory changes rarely.
public struct StudioOptionsCache: Sendable {
    let libraryID: Int64
    let revision: Int64
    let options: [StudioOption]
}

extension Catalog {
    static let entryQuery = """
        SELECT e.*, length(e.candidateData) AS candidateBytes,
            (SELECT json_group_array(name) FROM
                (SELECT t.name FROM tagItem i JOIN tag t ON t.id = i.tagID WHERE i.entryID = e.id ORDER BY t.name)) AS tags,
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

    /// Titles suggested for an unmatched entry. Decoding them for every entry of a library
    /// made up almost half of a snapshot, and only the match dialog shows them.
    public func candidates(entryID: Int64) throws -> [PRDBTitle] {
        guard let data = try database.read({ db in
            try Data.fetchOne(db, sql: "SELECT candidateData FROM entry WHERE id = ?", arguments: [entryID])
        }) else { return [] }
        // Unreadable suggestions read as absent, like other cached metadata.
        return (try? JSONDecoder().decode([PRDBTitle].self, from: data)) ?? []
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
    public func snapshot(libraryID: Int64?, studios cached: StudioOptionsCache? = nil) async throws -> LibrarySnapshot {
        try await database.read { db in
            var studios: StudioOptionsCache?
            var changed = true
            if let libraryID {
                let revision = try Int64.fetchOne(db, sql: "SELECT value FROM studioRevision") ?? 0
                if let cached, cached.libraryID == libraryID, cached.revision == revision {
                    studios = cached
                    changed = false
                } else {
                    studios = StudioOptionsCache(libraryID: libraryID, revision: revision,
                                                 options: try Self.studioOptions(db, libraryID: libraryID))
                }
            }
            let options = studios?.options ?? []
            return try LibrarySnapshot(libraries: Self.fetchLibraries(db),
                                sources: libraryID.map { try Self.fetchSources(db, libraryID: $0) } ?? [],
                                entries: libraryID.map { try Self.fetchEntries(db, libraryID: $0) } ?? [],
                                studioCovers: libraryID.map { try Self.studioCovers(db, libraryID: $0) } ?? [:],
                                favoriteStudioIDs: libraryID.map {
                                    try Self.favoriteStudioIDs(db, libraryID: $0, options: options)
                                } ?? [],
                                studioOptions: options, studios: studios, studioOptionsChanged: changed,
                                tags: libraryID.map { try Self.fetchTags(db, libraryID: $0) } ?? [],
                                playlists: libraryID.map { try Self.fetchPlaylists(db, libraryID: $0) } ?? [])
        }
    }

    /// Keep a known duration when the probe could not read one.
    public func storeVideoInfo(_ info: VideoInfo, duration: Double? = nil, for entry: CatalogEntry) async throws {
        let data = try JSONEncoder().encode(info)
        let seconds = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        try await database.write { db in
            try Task.checkCancellation()
            try db.execute(sql: """
                UPDATE entry SET videoInfo = ?, duration = COALESCE(?, duration)
                WHERE id = ? AND path = ? AND fileSize = ? AND modified = ?
                """, arguments: [data, seconds, entry.id, entry.path, entry.fileSize, entry.modified])
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

    @discardableResult
    public func setDetectedStudio(entryID: Int64, name: String?, fileSize: Int64, modified: Double) throws -> Bool {
        try database.write { db in
            try db.execute(sql: """
                UPDATE entry SET detectedStudio = ? WHERE id = ? AND fileSize = ? AND modified = ? AND needsLookup
                """, arguments: [name, entryID, fileSize, modified])
            guard db.changesCount > 0 else { return false }
            try Self.rememberDetectedStudio(db, name, entryID: entryID)
            try Self.reconcileStudioCovers(db, entryID: entryID)
            return true
        }
    }

    /// Give a studio to an entry whose finished lookup left it without one.
    @discardableResult
    func fillDetectedStudio(entryID: Int64, name: String?, fileSize: Int64, modified: Double) throws -> Bool {
        guard let name else { return false }
        return try database.write { db in
            try db.execute(sql: """
                UPDATE entry SET detectedStudio = ? WHERE id = ? AND fileSize = ? AND modified = ?
                    AND NOT needsLookup AND matchData IS NULL AND manualStudio IS NULL AND detectedStudio IS NULL
                """, arguments: [name, entryID, fileSize, modified])
            guard db.changesCount > 0 else { return false }
            try Self.rememberDetectedStudio(db, name, entryID: entryID)
            try Self.reconcileStudioCovers(db, entryID: entryID)
            return true
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
            if db.changesCount > 0 {
                try Self.rememberDetectedStudio(db, result.studio?.name, entryID: entryID)
                let before = db.totalChangesCount
                try Self.rememberSite(db, result.autoTitle?.studio)
                for title in result.candidates { try Self.rememberSite(db, title.studio) }
                try Self.reconcileStudioCovers(db, entryID: db.totalChangesCount == before ? entryID : nil)
            }
        }
    }

    /// Ask PRDB again about videos whose earlier lookup found no title. PRDB keeps growing,
    /// and a finished lookup is otherwise repeated only after the file changes.
    @discardableResult
    public func retryUnmatched(libraryID: Int64) throws -> Int {
        try database.write { db in
            try db.execute(sql: """
                UPDATE entry SET needsLookup = 1
                WHERE libraryID = ? AND NOT confirmed AND matchData IS NULL AND NOT needsLookup
                """, arguments: [libraryID])
            return db.changesCount
        }
    }

    public func confirmMatch(entryID: Int64, title: PRDBTitle?) throws {
        let data = try title.map { try JSONEncoder().encode($0) }
        try database.write { db in
            try db.execute(sql: "UPDATE entry SET matchData = ?, confirmed = 1, needsLookup = 0 WHERE id = ?",
                           arguments: [data, entryID])
            guard db.changesCount == 1 else { throw CatalogError.invalidValue }
            let before = db.totalChangesCount
            try Self.rememberSite(db, title?.studio)
            try Self.reconcileStudioCovers(db, entryID: db.totalChangesCount == before ? entryID : nil)
        }
    }

    /// Save a downloaded studio directory and remember when it was refreshed.
    public func saveStudios(_ studios: [PRDBStudio], refreshed: Date = Date()) throws {
        // Short transactions, so an edit in the interface never waits behind thousands of sites.
        var changed = false
        for start in stride(from: 0, to: studios.count, by: 200) {
            try database.write { db in
                let before = db.totalChangesCount
                for studio in studios[start..<min(start + 200, studios.count)] { try Self.saveSite(db, studio) }
                if db.totalChangesCount != before { changed = true }
            }
        }
        try database.write { db in
            if changed { try Self.reconcileStudioCovers(db) }
            try db.execute(sql: "INSERT OR REPLACE INTO catalogState(key, value) VALUES ('studioDirectoryRefreshed', ?)",
                           arguments: [String(refreshed.timeIntervalSince1970)])
        }
    }

    /// The last successful download of the studio directory, kept across launches.
    public func studioDirectoryRefreshed() throws -> Date? {
        try database.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM catalogState WHERE key = 'studioDirectoryRefreshed'")
                .flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        }
    }

    static func rememberSite(_ db: Database, _ studio: PRDBStudio?) throws {
        guard let studio else { return }
        try rememberStudio(db, studio.name)
        if studio.creator != nil { try saveSite(db, studio) }
        else {
            // A compact identify response can omit the platform of a known account.
            try db.execute(sql: "INSERT OR IGNORE INTO studio(id,name) VALUES (?,?)", arguments: [studio.id, studio.name])
        }
    }

    private static func saveSite(_ db: Database, _ studio: PRDBStudio) throws {
        let data = try studio.creator.map { try JSONEncoder().encode($0) }
        try db.execute(sql: """
            INSERT INTO studio(id,name,creatorData) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET
                name = excluded.name, creatorData = excluded.creatorData
            WHERE studio.name IS NOT excluded.name OR studio.creatorData IS NOT excluded.creatorData
            """, arguments: [studio.id, studio.name, data])
    }

    public func studios() throws -> [PRDBStudio] {
        try database.read(Self.fetchStudios)
    }

    // Include folders covered by any source membership, up to the outermost selected root.
    static let studioSourcePathSQL = """
        (SELECT s.path FROM membership m JOIN source s ON s.id = m.sourceID
         WHERE m.entryID = e.id ORDER BY length(s.path) LIMIT 1)
        """

    static func fetchStudios(_ db: Database) throws -> [PRDBStudio] {
        try Row.fetchAll(db, sql: "SELECT * FROM studio ORDER BY name COLLATE NOCASE").map { row in
            // The v8 migration reads the directory before creatorData is introduced.
            let data: Data? = row.hasColumn("creatorData") ? row["creatorData"] : nil
            return try PRDBStudio(id: row["id"], name: row["name"],
                                  creator: data.map { try JSONDecoder().decode(CreatorAccount.self, from: $0) })
        }
    }
}
