import Foundation
import GRDB

public struct CatalogLibrary: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let name: String
}

public struct CatalogSource: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let libraryID: Int64
    public let path: String
    public let online: Bool
    public let scanPending: Bool
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    fileprivate var prefix: String { path.hasSuffix("/") ? path : path + "/" }

    fileprivate func canTraverse(to nested: CatalogSource) -> Bool {
        nested.prefix.hasPrefix(prefix) && CatalogScanner.traversalBoundary(for: nested.url, upTo: path) == path
    }

    init(_ row: Row) {
        id = row["id"]
        libraryID = row["libraryID"]
        path = row["path"]
        online = row["online"]
        scanPending = row["scanPending"]
    }
}

public struct CatalogPlaylist: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let libraryID: Int64
    public let name: String
    public let videoCount: Int
    public let lastOpenedOrder: Int64
}

public enum CatalogAvailability: String, Sendable {
    case available, offline, missing
}

public enum CatalogError: LocalizedError {
    case staleScan, invalidPlaylistOrder, invalidValue, unavailableFolder

    public var errorDescription: String? {
        switch self {
        case .staleScan: "This scan was superseded."
        case .invalidPlaylistOrder: "The playlist changed. Reopen it and try again."
        case .invalidValue: "The supplied value is invalid."
        case .unavailableFolder: "The source folder could not be read."
        }
    }
}

public final class Catalog: Sendable {
    let database: DatabaseQueue

    public init(path: String) throws {
        database = try DatabaseQueue(path: path)
        try Self.migrator.migrate(database)
    }

    public func libraries() throws -> [CatalogLibrary] {
        try database.read(Self.fetchLibraries)
    }

    static func fetchLibraries(_ db: Database) throws -> [CatalogLibrary] {
        try Row.fetchAll(db, sql: "SELECT id, name FROM library ORDER BY name COLLATE NOCASE, id")
            .map { CatalogLibrary(id: $0["id"], name: $0["name"]) }
    }

    @discardableResult
    public func createLibrary(name: String) throws -> CatalogLibrary {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try database.write { db in
            try db.execute(sql: "INSERT INTO library(name) VALUES (?)", arguments: [clean])
            return CatalogLibrary(id: db.lastInsertedRowID, name: clean)
        }
    }

    public func renameLibrary(_ id: Int64, to name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw CatalogError.invalidValue }
        try database.write { db in
            try db.execute(sql: "UPDATE library SET name = ? WHERE id = ?", arguments: [clean, id])
            guard db.changesCount == 1 else { throw CatalogError.invalidValue }
        }
    }

    public func deleteLibrary(_ id: Int64) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM library WHERE id = ?", arguments: [id])
        }
    }

    public func sources(libraryID: Int64) throws -> [CatalogSource] {
        try database.read { try Self.fetchSources($0, libraryID: libraryID) }
    }

    static func fetchSources(_ db: Database, libraryID: Int64) throws -> [CatalogSource] {
        try Row.fetchAll(db, sql: "SELECT * FROM source WHERE libraryID = ? ORDER BY path",
                         arguments: [libraryID]).map(CatalogSource.init)
    }

    @discardableResult
    public func addSource(libraryID: Int64, url: URL) throws -> CatalogSource {
        guard url.isFileURL else { throw CatalogError.invalidValue }
        let path = url.standardizedFileURL.path
        return try database.write { db in
            try db.execute(sql: """
                INSERT INTO source(libraryID, path) VALUES (?, ?) ON CONFLICT(libraryID, path) DO NOTHING
                """, arguments: [libraryID, path])
            let inserted = db.changesCount == 1
            let row = try Row.fetchOne(db, sql: "SELECT * FROM source WHERE libraryID = ? AND path = ?",
                                       arguments: [libraryID, path])!
            let source = CatalogSource(row)
            guard inserted else { return source }
            // Inherit observations only from overlapping roots that can actually
            // traverse the same subtree. A linked child is its own source.
            let coverage = try Self.fetchSources(db, libraryID: libraryID).filter { other in
                other.id != source.id && (other.canTraverse(to: source) || source.canTraverse(to: other))
            }
            for other in coverage {
                try db.execute(sql: """
                    INSERT INTO membership(libraryID, sourceID, entryID, present)
                    SELECT e.libraryID, ?, e.id, m.present FROM membership m JOIN entry e ON e.id = m.entryID
                    WHERE m.sourceID = ? AND instr(e.path, ?) = 1
                    ON CONFLICT(sourceID,entryID) DO UPDATE SET present = MAX(membership.present, excluded.present)
                    """, arguments: [source.id, other.id, source.prefix])
            }
            return source
        }
    }

    static let orphanPredicate = """
        NOT EXISTS (SELECT 1 FROM membership other WHERE other.entryID = m.entryID AND other.sourceID <> ?)
        """

    public func sourceRemovalCount(_ sourceID: Int64) throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM membership m WHERE sourceID = ? AND " + Self.orphanPredicate,
                             arguments: [sourceID, sourceID]) ?? 0
        }
    }

    public func removeSource(_ sourceID: Int64, removeOrphans: Bool) throws {
        try database.write { db in
            if removeOrphans {
                try db.execute(sql: "DELETE FROM entry WHERE id IN (SELECT entryID FROM membership m WHERE sourceID = ? AND "
                               + Self.orphanPredicate + ")", arguments: [sourceID, sourceID])
            }
            try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [sourceID])
        }
    }

    @discardableResult
    public func checkSources(libraryID: Int64) throws -> Bool {
        var changed = false
        for source in try sources(libraryID: libraryID) {
            try Task.checkCancellation()
            let online = CatalogScanner.canOpen(source.url)
            guard online != source.online else { continue }
            let updated = try database.write { db in
                try Task.checkCancellation()
                try db.execute(sql: "UPDATE source SET online = ? WHERE id = ? AND online <> ?",
                               arguments: [online, source.id, online])
                return db.changesCount > 0
            }
            changed = changed || updated
        }
        return changed
    }

    public func deleteEntry(_ entryID: Int64) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM entry WHERE id = ?", arguments: [entryID])
        }
    }

    public func setRating(entryID: Int64, value: Int) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE entry SET rating = ? WHERE id = ?", arguments: [value, entryID])
        }
    }

    public func setFavorite(entryID: Int64, value: Bool) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE entry SET favorite = ? WHERE id = ?", arguments: [value, entryID])
        }
    }

    public func setManualStudio(entryID: Int64, name: String?) throws {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try database.write { db in
            try db.execute(sql: "UPDATE entry SET manualStudio = NULLIF(?, '') WHERE id = ?", arguments: [name, entryID])
        }
    }

    public func setTags(entryID: Int64, tags: [String]) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM entryTag WHERE entryID = ?", arguments: [entryID])
            for tag in tags {
                let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    try db.execute(sql: "INSERT OR IGNORE INTO entryTag(entryID, name) VALUES (?, ?)", arguments: [entryID, clean])
                }
            }
        }
    }
}
