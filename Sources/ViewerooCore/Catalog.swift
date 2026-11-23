import Foundation
import GRDB
import os

public struct CatalogLibrary: Encodable, Identifiable, Hashable, Sendable {
    public let id: Int64
    public let name: String
}

public struct CatalogSource: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let libraryID: Int64
    public let path: String
    public let online: Bool
    public let scanPending: Bool
    /// The volume that held the folder when it was last scanned successfully.
    let volume: String?
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
        volume = row["volume"]
    }
}

public struct CatalogPlaylist: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let libraryID: Int64
    public let name: String
    public let memberIDs: Set<Int64>
    public let orderedMemberIDs: [Int64]
    public let cover: CatalogCover?
    public var videoCount: Int { memberIDs.count }
    public let lastOpenedOrder: Int64
}

public enum CatalogAvailability: String, Sendable {
    case available, offline, missing
}

public enum CatalogError: LocalizedError {
    case staleScan, invalidPlaylistOrder, invalidValue, unavailableFolder
    /// The playback session was removed from Watch History while it was still recording.
    case sessionRemoved

    case duplicateTag, duplicateStudio, invalidStudioName, studioUnavailable

    public var errorDescription: String? {
        switch self {
        case .duplicateTag: "A tag with this name already exists."
        case .duplicateStudio: "A studio with this name already exists."
        case .invalidStudioName: "Enter a studio name other than Unknown Studio."
        case .studioUnavailable: "Only your own studios can be changed."
        case .staleScan: "This scan was superseded."
        case .invalidPlaylistOrder: "The playlist changed. Reopen it and try again."
        case .invalidValue: "The supplied value is invalid."
        case .unavailableFolder: "The source folder could not be read."
        case .sessionRemoved: "The viewing session was removed."
        }
    }
}

public final class Catalog: Sendable {
    /// A WAL pool for files, so snapshots and main-thread reads never wait behind scans or
    /// other writes. In-memory catalogs, used only by tests, fall back to a serial queue.
    let database: any DatabaseWriter
    let activeScans = OSAllocatedUnfairLock(initialState: 0)
    static let retainedBackups = 2

    public init(path: String) throws {
        if path.isEmpty || path == ":memory:" {
            database = try DatabaseQueue(path: path)
        } else {
            database = try DatabasePool(path: path)
            try Self.backUpBeforeMigrating(database, path: path)
        }
        try Self.migrator.migrate(database)
    }

    /// Copy an existing catalog before pending migrations rewrite it. Fresh catalogs need no copy.
    /// Keep the most recent copies in a `Backups` folder beside the catalog.
    private static func backUpBeforeMigrating(_ database: any DatabaseWriter, path: String) throws {
        let migrator = migrator
        let state = try database.read { db -> (applied: Set<String>, complete: Bool) in
            (try migrator.appliedIdentifiers(db), try migrator.hasCompletedMigrations(db))
        }
        guard !state.applied.isEmpty, !state.complete,
              let pending = migrator.migrations.first(where: { !state.applied.contains($0) }) else { return }
        let catalog = URL(fileURLWithPath: path)
        let folder = catalog.deletingLastPathComponent().appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .gmt, formatOptions: [.withYear, .withMonth, .withDay, .withTime])
        let name = "\(catalog.deletingPathExtension().lastPathComponent) \(stamp) before \(pending).sqlite"
        let target = folder.appending(path: name)
        let partial = folder.appending(path: "." + name + ".partial")
        func removePartial() {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: partial.path + suffix)
            }
        }
        removePartial()
        defer { removePartial() }
        do {
            let copy = try DatabaseQueue(path: partial.path)
            try database.backup(to: copy)
            // The copy inherits WAL mode. Store it as one self-contained file.
            try copy.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = DELETE") }
        }
        try FileManager.default.moveItem(at: partial, to: target)
        let prefix = catalog.deletingPathExtension().lastPathComponent + " "
        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in backups.dropFirst(retainedBackups) { try? FileManager.default.removeItem(at: old) }
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
            var source = CatalogSource(row)
            guard inserted else { return source }
            if let volume = CatalogScanner.volumeIdentity(of: source.url) {
                try db.execute(sql: "UPDATE source SET volume = ? WHERE id = ?", arguments: [volume, source.id])
                source = CatalogSource(try Row.fetchOne(db, sql: "SELECT * FROM source WHERE id = ?", arguments: [source.id])!)
            }
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
            let online = CatalogScanner.isReachable(source)
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

    public func setTags(entryID: Int64, tags: [String]) throws {
        try database.write { db in
            guard let library = try Int64.fetchOne(db, sql: "SELECT libraryID FROM entry WHERE id = ?", arguments: [entryID]) else {
                throw CatalogError.invalidValue
            }
            let names = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let existing = try Row.fetchAll(db, sql: """
                SELECT t.id, t.name FROM tagItem i JOIN tag t ON t.id = i.tagID WHERE i.entryID = ?
                """, arguments: [entryID])
            for row in existing {
                let name: String = row["name"]
                if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    try db.execute(sql: "DELETE FROM tagItem WHERE tagID = ? AND entryID = ?", arguments: [row["id"] as Int64, entryID])
                }
            }
            for name in names { _ = try Self.assignTag(db, name: name, entryID: entryID, libraryID: library) }
        }
    }
}
