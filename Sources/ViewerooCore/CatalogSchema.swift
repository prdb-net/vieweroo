import Foundation
import GRDB

extension Catalog {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("catalog-v1") { db in
            try db.execute(sql: """
                CREATE TABLE library (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL CHECK (length(trim(name)) > 0)
                );
                CREATE TABLE source (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    libraryID INTEGER NOT NULL REFERENCES library ON DELETE CASCADE,
                    path TEXT NOT NULL,
                    online INTEGER NOT NULL DEFAULT 1,
                    generation INTEGER NOT NULL DEFAULT 0, scanPending INTEGER NOT NULL DEFAULT 1,
                    UNIQUE (libraryID, path), UNIQUE (libraryID, id)
                );
                CREATE TABLE entry (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    libraryID INTEGER NOT NULL REFERENCES library ON DELETE CASCADE,
                    path TEXT NOT NULL, fileSize INTEGER NOT NULL, modified REAL NOT NULL,
                    hash TEXT, favorite INTEGER NOT NULL DEFAULT 0,
                    rating INTEGER NOT NULL DEFAULT 0 CHECK (rating IN (-1,0,1)),
                    resume REAL NOT NULL DEFAULT 0 CHECK (resume >= 0),
                    playbackFailure TEXT, manualStudio TEXT, detectedStudio TEXT, matchData BLOB, candidateData BLOB,
                    confirmed INTEGER NOT NULL DEFAULT 0, needsLookup INTEGER NOT NULL DEFAULT 1,
                    UNIQUE (libraryID, path), UNIQUE (libraryID, id)
                );
                CREATE TABLE membership (
                    libraryID INTEGER NOT NULL, sourceID INTEGER NOT NULL, entryID INTEGER NOT NULL,
                    present INTEGER NOT NULL DEFAULT 1, generation INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (sourceID, entryID),
                    FOREIGN KEY (libraryID, sourceID) REFERENCES source(libraryID, id) ON DELETE CASCADE,
                    FOREIGN KEY (libraryID, entryID) REFERENCES entry(libraryID, id) ON DELETE CASCADE
                );
                CREATE INDEX membership_by_entry ON membership(entryID);
                CREATE TABLE studio (id TEXT PRIMARY KEY, name TEXT NOT NULL);
                CREATE TABLE entryTag (
                    entryID INTEGER NOT NULL REFERENCES entry ON DELETE CASCADE,
                    name TEXT NOT NULL COLLATE NOCASE,
                    PRIMARY KEY (entryID, name)
                );
                CREATE TABLE playlist (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    libraryID INTEGER NOT NULL REFERENCES library ON DELETE CASCADE,
                    name TEXT NOT NULL CHECK (length(trim(name)) > 0),
                    UNIQUE (libraryID, id)
                );
                CREATE TABLE playlistItem (
                    libraryID INTEGER NOT NULL, playlistID INTEGER NOT NULL, entryID INTEGER NOT NULL,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (playlistID, entryID),
                    FOREIGN KEY (libraryID, playlistID) REFERENCES playlist(libraryID, id) ON DELETE CASCADE,
                    FOREIGN KEY (libraryID, entryID) REFERENCES entry(libraryID, id) ON DELETE CASCADE
                );
                CREATE TABLE session (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    entryID INTEGER NOT NULL REFERENCES entry ON DELETE CASCADE,
                    started DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE interval (
                    sessionID INTEGER NOT NULL REFERENCES session ON DELETE CASCADE,
                    start REAL NOT NULL CHECK (start >= 0), end REAL NOT NULL CHECK (end > start)
                );
                """)
        }
        migrator.registerMigration("history-indexes-v2") { db in
            try db.execute(sql: """
                CREATE INDEX session_by_entry ON session(entryID);
                CREATE INDEX interval_by_session ON interval(sessionID);
                CREATE INDEX playlist_item_order ON playlistItem(playlistID, position);
                """)
        }
        migrator.registerMigration("library-scan-clock-v3") { db in
            try db.execute(sql: """
                ALTER TABLE library ADD COLUMN scanClock INTEGER NOT NULL DEFAULT 0;
                UPDATE library SET scanClock = (
                    SELECT COALESCE(MAX(generation), 0) FROM source WHERE libraryID = library.id
                );
                """)
        }
        migrator.registerMigration("visible-playback-sessions-v4") { db in
            try db.execute(sql: """
                -- Older catalogs kept just one resume position per entry. If a brief
                -- visit replaced it, recover the last interval of the last visible session.
                UPDATE entry SET resume = COALESCE((
                    SELECT i.end FROM interval i WHERE i.sessionID = (
                        SELECT MAX(v.id) FROM \(visibleSessions) v WHERE v.entryID = entry.id
                    ) ORDER BY i.rowid DESC LIMIT 1
                ), 0)
                WHERE (SELECT MAX(s.id) FROM session s WHERE s.entryID = entry.id)
                    IS NOT (SELECT MAX(v.id) FROM \(visibleSessions) v WHERE v.entryID = entry.id)
                    OR (resume > 0 AND NOT EXISTS (SELECT 1 FROM session s WHERE s.entryID = entry.id));
                """)
        }
        migrator.registerMigration("weighted-plays-v5") { db in
            try db.execute(sql: """
                ALTER TABLE entry ADD COLUMN duration REAL CHECK (duration > 0);
                CREATE INDEX interval_by_session_range ON interval(sessionID, start, end);
                DROP INDEX interval_by_session;
                """)
        }
        migrator.registerMigration("overlapping-source-coverage-v6") { db in
            // Recheck old path-prefix memberships once their sources are reachable.
            try db.execute(sql: """
                UPDATE source SET scanPending = 1 WHERE EXISTS (
                    SELECT 1 FROM source other WHERE other.libraryID = source.libraryID AND other.id <> source.id
                    AND (instr(source.path, rtrim(other.path, '/') || '/') = 1
                         OR instr(other.path, rtrim(source.path, '/') || '/') = 1)
                )
                """)
        }
        migrator.registerMigration("recent-playlists-v7") { db in
            try db.execute(sql: "ALTER TABLE playlist ADD COLUMN lastOpenedOrder INTEGER NOT NULL DEFAULT 0")
        }
        migrator.registerMigration("studio-release-prefix-v8") { db in
            var recognition = StudioRecognition(studios: try fetchStudios(db))
            // Old site-only responses stored the studio name even if the directory lacked it.
            let extraNames = try String.fetchAll(db, sql: """
                SELECT DISTINCT detectedStudio FROM entry WHERE detectedStudio IS NOT NULL
                EXCEPT SELECT name FROM studio
                """)
            for name in extraNames {
                recognition.add(PRDBStudio(id: "legacy-name:" + name, name: name))
            }

            var after: Int64 = 0
            while true {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id,path,detectedStudio, \(studioSourcePathSQL) AS sourcePath FROM entry e
                    WHERE id > ? AND detectedStudio IS NOT NULL ORDER BY id LIMIT 200
                    """, arguments: [after])
                guard let last = rows.last else { break }
                for row in rows {
                    let path: String = row["path"]
                    let url = URL(fileURLWithPath: path, isDirectory: false)
                    let name = recognition.match(url: url, sourcePath: row["sourcePath"])?.name
                    if name != row["detectedStudio"] as String? {
                        try db.execute(sql: "UPDATE entry SET detectedStudio = ? WHERE id = ?",
                                       arguments: [name, row["id"] as Int64])
                    }
                }
                after = last["id"]
            }
        }
        migrator.registerMigration("local-video-info-v9") { db in
            try db.execute(sql: "ALTER TABLE entry ADD COLUMN videoInfo BLOB")
        }
        migrator.registerMigration("custom-studios-v10", migrate: migrateStudioNames)
        migrator.registerMigration("creator-accounts-v11") { db in
            try db.execute(sql: """
                ALTER TABLE studio ADD COLUMN creatorData BLOB;
                ALTER TABLE entry ADD COLUMN manualSiteID TEXT;
                """)
            let rows = try Row.fetchCursor(db, sql: "SELECT matchData, candidateData FROM entry WHERE matchData IS NOT NULL OR candidateData IS NOT NULL")
            let decoder = JSONDecoder()
            while let row = try rows.next() {
                if let data: Data = row["matchData"] {
                    try rememberSite(db, decoder.decode(PRDBTitle.self, from: data).studio)
                }
                if let data: Data = row["candidateData"] {
                    for title in try decoder.decode([PRDBTitle].self, from: data) { try rememberSite(db, title.studio) }
                }
            }
        }
        migrator.registerMigration("studio-favorites-v12") { db in
            try db.execute(sql: """
                CREATE TABLE studioFavorite (
                    libraryID INTEGER NOT NULL REFERENCES library ON DELETE CASCADE,
                    studioID TEXT NOT NULL,
                    PRIMARY KEY(libraryID, studioID)
                )
                """)
        }
        migrator.registerMigration("library-tags-v13", migrate: migrateTags)
        return migrator
    }
}
