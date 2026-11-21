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
        return migrator
    }
}
