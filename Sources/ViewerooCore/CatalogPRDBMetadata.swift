import Foundation
import GRDB

package struct PRDBTagDirectory: Codable, Sendable {
    package let names: [String: String]
    package let refreshed: Date

    package init(names: [String: String], refreshed: Date = Date()) {
        self.names = names
        self.refreshed = refreshed
    }
}

extension Catalog {
    package func prdbTagDirectory() throws -> PRDBTagDirectory? {
        try database.read { db in
            let json = try String.fetchOne(db, sql: "SELECT value FROM catalogState WHERE key = 'prdbTagDirectory'")
            return json.flatMap { try? JSONDecoder().decode(PRDBTagDirectory.self, from: Data($0.utf8)) }
        }
    }

    package func savePRDBTagDirectory(_ directory: PRDBTagDirectory) async throws {
        let json = String(decoding: try JSONEncoder().encode(directory), as: UTF8.self)
        try await database.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO catalogState(key, value) VALUES ('prdbTagDirectory', ?)",
                           arguments: [json])
        }
    }

    package func matchesMissingPRDBMetadata(libraryID: Int64) async throws -> [String: [Int64]] {
        try await database.read { db in
            // Only read title IDs. A bad cache row should leave other matches usable.
            let rows = try Row.fetchCursor(db, sql: """
                WITH matches AS (
                    SELECT id, CASE WHEN json_valid(CAST(matchData AS TEXT)) THEN CAST(matchData AS TEXT) END AS title
                    FROM entry WHERE libraryID = ? AND matchData IS NOT NULL
                )
                SELECT id, json_extract(title, '$.id') AS titleID FROM matches
                WHERE json_type(title, '$.id') = 'text' AND COALESCE(json_type(title, '$.tagKeys'), 'null') = 'null'
                """, arguments: [libraryID])
            var entries: [String: [Int64]] = [:]
            while let row = try rows.next() {
                let id: String = row["titleID"]
                guard UUID(uuidString: id) != nil else { continue }
                entries[id.lowercased(), default: []].append(row["id"])
            }
            return entries
        }
    }

    package func backfillPRDBMetadata(_ titles: [PRDBTitle], entries: [String: [Int64]]) async throws -> Bool {
        try await database.write { db in
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            var changed = false
            for title in titles {
                let titleID = title.id.lowercased()
                guard let tagKeys = title.tagKeys, let ids = entries[titleID] else { continue }
                for id in ids {
                    // A match can be removed or corrected while the batch is in flight.
                    guard let data = try Data.fetchOne(db, sql: "SELECT matchData FROM entry WHERE id = ?", arguments: [id]),
                          let cached = try? decoder.decode(PRDBTitle.self, from: data),
                          cached.id.lowercased() == titleID, cached.tagKeys == nil else { continue }
                    let updated = PRDBTitle(id: cached.id, title: cached.title, studio: cached.studio,
                                            performers: cached.performers, previewURL: cached.previewURL,
                                            alternativeTitle: title.alternativeTitle, durationSeconds: title.durationSeconds,
                                            tagKeys: tagKeys)
                    try db.execute(sql: "UPDATE entry SET matchData = ? WHERE id = ?", arguments: [try encoder.encode(updated), id])
                    changed = true
                }
            }
            return changed
        }
    }
}
