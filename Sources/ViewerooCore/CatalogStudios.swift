import Foundation
import GRDB

public struct StudioOption: Identifiable, Hashable, Sendable {
    public let name: String
    public let isCustom: Bool
    public let siteID: String?
    public let creator: CreatorAccount?
    public var id: String { siteID.map { "site:" + $0 } ?? "name:" + name.folding(options: .caseInsensitive, locale: nil) }

    public init(name: String, isCustom: Bool, siteID: String? = nil, creator: CreatorAccount? = nil) {
        self.name = name
        self.isCustom = isCustom
        self.siteID = siteID
        self.creator = creator
    }
}

/// Resolve modern catalog identities first. Older manual selections have only a name,
/// so attach account metadata to those only when the name identifies a single site.
public struct StudioDirectory: Sendable {
    public let options: [StudioOption]
    private let sites: [String: StudioOption]
    private let names: [String: [StudioOption]]

    public init(_ options: [StudioOption] = []) {
        self.options = options
        sites = Dictionary(uniqueKeysWithValues: options.compactMap { option in option.siteID.map { ($0, option) } })
        names = Dictionary(grouping: options) { $0.name.folding(options: .caseInsensitive, locale: nil) }
    }

    public func site(_ id: String) -> StudioOption? { sites[id] }

    public func studio(for entry: CatalogEntry) -> StudioOption {
        let matched = entry.manualStudio == nil ? entry.match?.studio : nil
        if let id = entry.manualSiteID ?? matched?.id {
            return sites[id] ?? StudioOption(name: entry.studio ?? "Unknown Studio", isCustom: false,
                                             siteID: id, creator: matched?.creator)
        }
        let name = entry.studio ?? "Unknown Studio"
        if let matches = names[name.folding(options: .caseInsensitive, locale: nil)], matches.count == 1 {
            return matches[0]
        }
        return StudioOption(name: name, isCustom: false)
    }
}

extension Catalog {
    static func migrateStudioNames(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE customStudio (
                libraryID INTEGER NOT NULL REFERENCES library ON DELETE CASCADE,
                name TEXT NOT NULL COLLATE swiftCaseInsensitiveCompare,
                PRIMARY KEY(libraryID, name)
            );
            CREATE TABLE metadataStudio (name TEXT PRIMARY KEY COLLATE swiftCaseInsensitiveCompare NOT NULL);
            CREATE INDEX studio_by_name ON studio(name COLLATE swiftCaseInsensitiveCompare);
            CREATE VIEW prdbStudioName AS
                SELECT name COLLATE swiftCaseInsensitiveCompare AS name FROM studio
                UNION SELECT name FROM metadataStudio;
            INSERT OR IGNORE INTO metadataStudio SELECT DISTINCT detectedStudio FROM entry WHERE detectedStudio IS NOT NULL;
            """)
        // Old catalogs also contain PRDB titles and suggestions received before a directory refresh.
        let decoder = JSONDecoder()
        let rows = try Row.fetchCursor(db, sql: "SELECT matchData, candidateData FROM entry WHERE matchData IS NOT NULL OR candidateData IS NOT NULL")
        while let row = try rows.next() {
            if let data: Data = row["matchData"] {
                try rememberStudio(db, decoder.decode(PRDBTitle.self, from: data).studio?.name)
            }
            if let data: Data = row["candidateData"] {
                for title in try decoder.decode([PRDBTitle].self, from: data) { try rememberStudio(db, title.studio?.name) }
            }
        }
        try db.execute(sql: """
            INSERT OR IGNORE INTO customStudio(libraryID, name)
            SELECT libraryID, manualStudio FROM entry
            WHERE manualStudio IS NOT NULL AND manualStudio != ''
                AND NOT EXISTS (SELECT 1 FROM prdbStudioName WHERE name = entry.manualStudio)
            ORDER BY id;
            UPDATE entry SET manualStudio = COALESCE(
                (SELECT name FROM prdbStudioName WHERE name = entry.manualStudio),
                (SELECT name FROM customStudio WHERE libraryID = entry.libraryID AND name = entry.manualStudio))
            WHERE manualStudio IS NOT NULL;
            """)
    }

    static func rememberStudio(_ db: Database, _ name: String?) throws {
        guard let name, !name.isEmpty else { return }
        try db.execute(sql: "INSERT OR IGNORE INTO metadataStudio(name) VALUES (?)", arguments: [name])
    }

    static func studioOptions(_ db: Database, libraryID: Int64) throws -> [StudioOption] {
        try Row.fetchAll(db, sql: """
            SELECT name, 0 AS isCustom, id, creatorData FROM studio
            UNION ALL
            SELECT name, 0, NULL, NULL FROM metadataStudio m
                WHERE NOT EXISTS (SELECT 1 FROM studio WHERE name = m.name COLLATE swiftCaseInsensitiveCompare)
            UNION ALL
            SELECT name, 1, NULL, NULL FROM customStudio c WHERE libraryID = ?
                AND NOT EXISTS (SELECT 1 FROM prdbStudioName WHERE name = c.name)
            ORDER BY name COLLATE swiftCaseInsensitiveCompare
            """, arguments: [libraryID]).map { row in
                let data: Data? = row["creatorData"]
                return try StudioOption(name: row["name"], isCustom: row["isCustom"], siteID: row["id"],
                                        creator: data.map { try JSONDecoder().decode(CreatorAccount.self, from: $0) })
            }
    }

    private static func existingStudio(_ db: Database, libraryID: Int64, name: String) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT name FROM prdbStudioName WHERE name = ?
            UNION ALL SELECT name FROM customStudio WHERE libraryID = ? AND name = ? LIMIT 1
            """, arguments: [name, libraryID, name])
    }

    private static func validateStudioName(_ name: String) throws {
        guard !name.isEmpty, name.caseInsensitiveCompare("Unknown Studio") != .orderedSame else {
            throw CatalogError.invalidStudioName
        }
    }

    private static func insertStudio(_ db: Database, libraryID: Int64, name: String) throws {
        try validateStudioName(name)
        try db.execute(sql: "INSERT INTO customStudio(libraryID,name) VALUES (?,?)", arguments: [libraryID, name])
    }

    // A directory refresh can give a previously name-only studio a PRDB identity.
    // Carry its favorite across only when that name now identifies exactly one site.
    static func favoriteStudioIDs(_ db: Database, libraryID: Int64, options: [StudioOption]) throws -> Set<String> {
        let saved = try Set(String.fetchAll(db, sql: "SELECT studioID FROM studioFavorite WHERE libraryID = ?", arguments: [libraryID]))
        guard saved.contains(where: { $0.hasPrefix("name:") }) else { return saved }
        let byName = Dictionary(grouping: options.filter { $0.siteID != nil }) { StudioOption(name: $0.name, isCustom: false).id }
        return Set(saved.map { key in
            guard let sites = byName[key], sites.count == 1 else { return key }
            return sites[0].id
        })
    }

    public func setStudioFavorite(libraryID: Int64, studio: StudioOption, favorite: Bool) throws {
        try database.write { db in
            if favorite {
                try db.execute(sql: "INSERT OR IGNORE INTO studioFavorite(libraryID, studioID) VALUES (?, ?)",
                               arguments: [libraryID, studio.id])
            } else {
                try db.execute(sql: "DELETE FROM studioFavorite WHERE libraryID = ? AND studioID = ?",
                               arguments: [libraryID, studio.id])
                if let id = studio.siteID {
                    let ids = try String.fetchAll(db, sql: "SELECT id FROM studio WHERE name = ? COLLATE swiftCaseInsensitiveCompare",
                                                  arguments: [studio.name])
                    if ids == [id] {
                        try db.execute(sql: "DELETE FROM studioFavorite WHERE libraryID = ? AND studioID = ?",
                                       arguments: [libraryID, StudioOption(name: studio.name, isCustom: false).id])
                    }
                }
            }
        }
    }

    public func createStudio(libraryID: Int64, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try database.write { db in
            guard try Self.existingStudio(db, libraryID: libraryID, name: name) == nil else {
                throw CatalogError.duplicateStudio
            }
            try Self.insertStudio(db, libraryID: libraryID, name: name)
        }
    }

    public func setManualStudio(entryID: Int64, name: String?, siteID: String? = nil) throws {
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try database.write { db in
            guard let libraryID = try Int64.fetchOne(db, sql: "SELECT libraryID FROM entry WHERE id = ?", arguments: [entryID]) else {
                throw CatalogError.invalidValue
            }
            var selection: String?
            if let siteID {
                guard let name = try String.fetchOne(db, sql: "SELECT name FROM studio WHERE id = ?", arguments: [siteID]) else {
                    throw CatalogError.studioUnavailable
                }
                selection = name
            } else if !clean.isEmpty {
                if let existing = try Self.existingStudio(db, libraryID: libraryID, name: clean) {
                    selection = existing
                } else {
                    try Self.insertStudio(db, libraryID: libraryID, name: clean)
                    selection = clean
                }
            }
            try db.execute(sql: "UPDATE entry SET manualStudio = ?, manualSiteID = ? WHERE id = ?", arguments: [selection, siteID, entryID])
        }
    }

    public func renameCustomStudio(libraryID: Int64, name: String, to newName: String) throws {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validateStudioName(clean)
        try database.write { db in
            if clean.caseInsensitiveCompare(name) != .orderedSame,
               try Self.existingStudio(db, libraryID: libraryID, name: clean) != nil {
                throw CatalogError.duplicateStudio
            }
            try db.execute(sql: """
                UPDATE customStudio SET name = ? WHERE libraryID = ? AND name = ?
                    AND NOT EXISTS (SELECT 1 FROM prdbStudioName WHERE name = ?)
                """, arguments: [clean, libraryID, name, name])
            guard db.changesCount == 1 else { throw CatalogError.studioUnavailable }
            try db.execute(sql: "UPDATE studioFavorite SET studioID = ? WHERE libraryID = ? AND studioID = ?",
                           arguments: [StudioOption(name: clean, isCustom: true).id, libraryID, StudioOption(name: name, isCustom: true).id])
            try db.execute(sql: """
                UPDATE entry SET manualStudio = ? WHERE manualSiteID IS NULL AND libraryID = ? AND manualStudio = ? COLLATE swiftCaseInsensitiveCompare
                """, arguments: [clean, libraryID, name])
        }
    }

    public func deleteCustomStudio(libraryID: Int64, name: String) throws {
        try database.write { db in
            try db.execute(sql: """
                DELETE FROM customStudio WHERE libraryID = ? AND name = ?
                    AND NOT EXISTS (SELECT 1 FROM prdbStudioName WHERE name = ?)
                """, arguments: [libraryID, name, name])
            guard db.changesCount == 1 else { throw CatalogError.studioUnavailable }
            try db.execute(sql: "DELETE FROM studioFavorite WHERE libraryID = ? AND studioID = ?",
                           arguments: [libraryID, StudioOption(name: name, isCustom: true).id])
            try db.execute(sql: """
                UPDATE entry SET manualStudio = NULL WHERE manualSiteID IS NULL AND libraryID = ? AND manualStudio = ? COLLATE swiftCaseInsensitiveCompare
                """, arguments: [libraryID, name])
        }
    }
}
