import GRDB
import Foundation

extension Catalog {
    public func playlists(libraryID: Int64) throws -> [CatalogPlaylist] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM playlist WHERE libraryID = ? ORDER BY name COLLATE NOCASE, id",
                             arguments: [libraryID])
                .map { CatalogPlaylist(id: $0["id"], libraryID: $0["libraryID"], name: $0["name"]) }
        }
    }

    @discardableResult
    public func createPlaylist(libraryID: Int64, name: String) throws -> CatalogPlaylist {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try database.write { db in
            try db.execute(sql: "INSERT INTO playlist(libraryID, name) VALUES (?, ?)", arguments: [libraryID, clean])
            return CatalogPlaylist(id: db.lastInsertedRowID, libraryID: libraryID, name: clean)
        }
    }

    public func deletePlaylist(_ id: Int64) throws {
        try database.write { db in try db.execute(sql: "DELETE FROM playlist WHERE id = ?", arguments: [id]) }
    }

    /// Returns false when the video already belongs to this playlist.
    @discardableResult
    public func addToPlaylist(_ playlistID: Int64, entryID: Int64) throws -> Bool {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO playlistItem(libraryID, playlistID, entryID, position)
                VALUES ((SELECT libraryID FROM playlist WHERE id = :playlist), :playlist, :entry,
                        (SELECT COALESCE(MAX(position) + 1, 0) FROM playlistItem WHERE playlistID = :playlist))
                ON CONFLICT(playlistID, entryID) DO NOTHING
                """, arguments: ["playlist": playlistID, "entry": entryID])
            return db.changesCount == 1
        }
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
            for (index, entryID) in entryIDs.enumerated() {
                try db.execute(sql: "UPDATE playlistItem SET position = ? WHERE playlistID = ? AND entryID = ?",
                               arguments: [index, playlistID, entryID])
            }
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
