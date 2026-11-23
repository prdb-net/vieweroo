import GRDB
import Foundation

extension Catalog {
    public func playlists(libraryID: Int64) throws -> [CatalogPlaylist] {
        try database.read { try Self.fetchPlaylists($0, libraryID: libraryID) }
    }

    static func fetchPlaylists(_ db: Database, libraryID: Int64) throws -> [CatalogPlaylist] {
        let items = try Row.fetchAll(db, sql: """
            SELECT playlistID, entryID FROM playlistItem WHERE libraryID = ? ORDER BY playlistID, position
            """, arguments: [libraryID])
        let members = Dictionary(grouping: items) { $0["playlistID"] as Int64 }
        return try Row.fetchAll(db, sql: """
            SELECT p.*, c.entryID, c.time, c.revision, c.custom FROM playlist p
            LEFT JOIN playlistCover c ON c.playlistID = p.id
            WHERE p.libraryID = ? ORDER BY p.name COLLATE swiftLocalizedStandardCompare, p.id
            """, arguments: [libraryID]).map { row in
                let id: Int64 = row["id"]
                let ids: [Int64] = members[id]?.map { $0["entryID"] } ?? []
                return CatalogPlaylist(id: id, libraryID: row["libraryID"], name: row["name"],
                                       memberIDs: Set(ids), orderedMemberIDs: ids, cover: CatalogCover(row),
                                       lastOpenedOrder: row["lastOpenedOrder"])
            }
    }

    public func recordPlaylistOpen(_ id: Int64, libraryID: Int64) throws -> [CatalogPlaylist] {
        try database.write { db in
            try db.execute(sql: """
                UPDATE playlist SET lastOpenedOrder = (
                    SELECT MAX(lastOpenedOrder) + 1 FROM playlist WHERE libraryID = ?
                ) WHERE libraryID = ? AND id = ?
                """, arguments: [libraryID, libraryID, id])
            return try Self.fetchPlaylists(db, libraryID: libraryID)
        }
    }

    public func playlistEntryIDs(_ id: Int64) throws -> [Int64] {
        try database.read { try Self.playlistEntryIDs($0, id) }
    }

    static func playlistEntryIDs(_ db: Database, _ id: Int64) throws -> [Int64] {
        try Int64.fetchAll(db, sql: "SELECT entryID FROM playlistItem WHERE playlistID = ? ORDER BY position",
                           arguments: [id])
    }

    @discardableResult
    public func createPlaylist(libraryID: Int64, name: String) throws -> CatalogPlaylist {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try database.write { db in
            try db.execute(sql: "INSERT INTO playlist(libraryID, name) VALUES (?, ?)", arguments: [libraryID, clean])
            return CatalogPlaylist(id: db.lastInsertedRowID, libraryID: libraryID, name: clean, memberIDs: [],
                                   orderedMemberIDs: [], cover: nil, lastOpenedOrder: 0)
        }
    }

    public func renamePlaylist(_ id: Int64, to name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw CatalogError.invalidValue }
        try database.write { db in
            try db.execute(sql: "UPDATE playlist SET name = ? WHERE id = ?", arguments: [clean, id])
            guard db.changesCount == 1 else { throw CatalogError.invalidValue }
        }
    }

    public func deletePlaylist(_ id: Int64) throws {
        try database.write { db in try db.execute(sql: "DELETE FROM playlist WHERE id = ?", arguments: [id]) }
    }

    public func deletePlaylists(in libraryID: Int64, ids: Set<Int64>) throws {
        try database.write { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM playlist WHERE libraryID = ? AND id = ?", arguments: [libraryID, id])
                guard db.changesCount == 1 else { throw CatalogError.invalidValue }
            }
        }
    }

    /// Returns false when the video already belongs to this playlist.
    @discardableResult
    public func addToPlaylist(_ playlistID: Int64, entryID: Int64) throws -> Bool {
        try database.write { try Self.appendToPlaylist($0, playlistID: playlistID, entryID: entryID) }
    }

    static func appendToPlaylist(_ db: Database, playlistID: Int64, entryID: Int64) throws -> Bool {
        try db.execute(sql: """
            INSERT INTO playlistItem(libraryID, playlistID, entryID, position)
            VALUES ((SELECT libraryID FROM playlist WHERE id = :playlist), :playlist, :entry,
                    (SELECT COALESCE(MAX(position) + 1, 0) FROM playlistItem WHERE playlistID = :playlist))
            ON CONFLICT(playlistID, entryID) DO NOTHING
            """, arguments: ["playlist": playlistID, "entry": entryID])
        return db.changesCount == 1
    }

    public func removeFromPlaylist(_ playlistID: Int64, entryID: Int64) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM playlistItem WHERE playlistID = ? AND entryID = ?",
                           arguments: [playlistID, entryID])
        }
    }

    public func reorderPlaylist(_ playlistID: Int64, entryIDs: [Int64]) throws {
        try database.write { db in
            let existing = try Int64.fetchAll(db, sql: "SELECT entryID FROM playlistItem WHERE playlistID = ?",
                                              arguments: [playlistID])
            guard existing.count == entryIDs.count, Set(existing) == Set(entryIDs) else {
                throw CatalogError.invalidPlaylistOrder
            }
            try Self.writePlaylistOrder(db, playlistID: playlistID, entryIDs: entryIDs)
        }
    }

    static func writePlaylistOrder(_ db: Database, playlistID: Int64, entryIDs: [Int64]) throws {
        for (index, entryID) in entryIDs.enumerated() {
            try db.execute(sql: "UPDATE playlistItem SET position = ? WHERE playlistID = ? AND entryID = ?",
                           arguments: [index, playlistID, entryID])
        }
    }

    public func playlistEntries(_ id: Int64) throws -> [CatalogEntry] {
        try database.read { db in
            try Row.fetchAll(db, sql: Self.entryQuery + """
                 JOIN playlistItem p ON p.entryID = e.id WHERE p.playlistID = ? ORDER BY p.position
                """, arguments: [id]).map(CatalogEntry.init)
        }
    }
}
