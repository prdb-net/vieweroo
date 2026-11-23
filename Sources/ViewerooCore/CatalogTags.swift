import Foundation
import GRDB

public struct CatalogTag: Identifiable, Sendable {
    public let id: Int64
    public let name: String
    /// Assignment order determines which cached still to try first for an automatic cover.
    public let memberIDs: [Int64]
    public let cover: CatalogCover?
}

extension Catalog {
    static func migrateTags(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE tag (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                libraryID INTEGER NOT NULL REFERENCES library ON DELETE CASCADE,
                name TEXT NOT NULL COLLATE swiftCaseInsensitiveCompare CHECK(length(trim(name)) > 0),
                UNIQUE(libraryID, name), UNIQUE(libraryID, id)
            );
            CREATE TABLE tagItem (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                libraryID INTEGER NOT NULL, tagID INTEGER NOT NULL, entryID INTEGER NOT NULL,
                UNIQUE(tagID, entryID),
                FOREIGN KEY(libraryID, tagID) REFERENCES tag(libraryID, id) ON DELETE CASCADE,
                FOREIGN KEY(libraryID, entryID) REFERENCES entry(libraryID, id) ON DELETE CASCADE
            );
            CREATE INDEX tags_by_entry ON tagItem(entryID);
            CREATE TABLE tagCover (
                tagID INTEGER PRIMARY KEY, entryID INTEGER NOT NULL,
                time REAL NOT NULL CHECK(time >= 0), image BLOB NOT NULL,
                revision TEXT NOT NULL, custom INTEGER NOT NULL,
                FOREIGN KEY(tagID, entryID) REFERENCES tagItem(tagID, entryID) ON DELETE CASCADE
            );
            INSERT OR IGNORE INTO tag(libraryID, name)
                SELECT e.libraryID, t.name FROM entryTag t JOIN entry e ON e.id = t.entryID ORDER BY t.rowid;
            INSERT OR IGNORE INTO tagItem(libraryID, tagID, entryID)
                SELECT e.libraryID, tag.id, e.id FROM entryTag t JOIN entry e ON e.id = t.entryID
                JOIN tag ON tag.libraryID = e.libraryID AND tag.name = t.name ORDER BY t.rowid;
            DROP TABLE entryTag;
            """)
    }

    static func fetchTags(_ db: Database, libraryID: Int64) throws -> [CatalogTag] {
        let items = try Row.fetchAll(db, sql: "SELECT tagID, entryID FROM tagItem WHERE libraryID = ? ORDER BY id",
                                    arguments: [libraryID])
        let members = Dictionary(grouping: items) { $0["tagID"] as Int64 }
        return try Row.fetchAll(db, sql: """
            SELECT t.id, t.name, c.entryID, c.time, c.revision, c.custom FROM tag t
            LEFT JOIN tagCover c ON c.tagID = t.id WHERE t.libraryID = ? ORDER BY t.name COLLATE swiftLocalizedStandardCompare
            """, arguments: [libraryID]).map { row in
            let id: Int64 = row["id"]
            return CatalogTag(id: id, name: row["name"], memberIDs: members[id]?.map { $0["entryID"] } ?? [],
                              cover: CatalogCover(row))
        }
    }

    private static func checkedTagName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw CatalogError.invalidValue }
        return value
    }

    public func createTag(libraryID: Int64, name: String) throws {
        try database.write { db in
            try db.execute(sql: "INSERT INTO tag(libraryID,name) VALUES (?,?) ON CONFLICT(libraryID,name) DO NOTHING",
                           arguments: [libraryID, try Self.checkedTagName(name)])
            guard db.changesCount == 1 else { throw CatalogError.duplicateTag }
        }
    }

    public func renameTag(_ id: Int64, to name: String) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE OR IGNORE tag SET name = ? WHERE id = ?", arguments: [try Self.checkedTagName(name), id])
            guard db.changesCount == 1 else { throw CatalogError.duplicateTag }
        }
    }

    public func deleteTag(_ id: Int64) throws {
        try database.write { db in try db.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [id]) }
    }

    static func assignTag(_ db: Database, name: String, entryID: Int64, libraryID: Int64) throws -> Int64? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        try db.execute(sql: "INSERT INTO tag(libraryID,name) VALUES (?,?) ON CONFLICT(libraryID,name) DO NOTHING",
                       arguments: [libraryID, clean])
        guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE libraryID = ? AND name = ?", arguments: [libraryID, clean]) else {
            throw CatalogError.invalidValue
        }
        try db.execute(sql: "INSERT INTO tagItem(libraryID,tagID,entryID) VALUES (?,?,?) ON CONFLICT(tagID,entryID) DO NOTHING",
                       arguments: [libraryID, id, entryID])
        return db.changesCount == 1 ? db.lastInsertedRowID : nil
    }
}
