import Darwin
import Foundation
import GRDB

@MainActor
final class SettingsStore: SecretStore {
    private let directory: URL
    private let legacy: any LegacyCredentials
    private var database: DatabaseQueue?

    init(directory: URL, legacy: any LegacyCredentials) {
        self.directory = directory
        self.legacy = legacy
    }

    func read(_ account: String) throws -> Data? {
        try open().read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM credential WHERE account = ?", arguments: [account])
        }
    }

    func write(_ data: Data?, account: String) throws {
        try open().write { db in
            if let data {
                try db.execute(sql: "INSERT OR REPLACE INTO credential(account, value) VALUES (?, ?)",
                               arguments: [account, data])
            } else {
                try db.execute(sql: "DELETE FROM credential WHERE account = ?", arguments: [account])
            }
        }
    }

    private func open() throws -> DatabaseQueue {
        if let database { return database }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let path = directory.appending(path: "Settings.sqlite").path
        // SQLite uses the database file's mode for its journal. Set it before the first write.
        let fd = Darwin.open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        if fd >= 0 {
            Darwin.close(fd)
        } else if errno != EEXIST {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA secure_delete = ON") }
        let queue = try DatabaseQueue(path: path, configuration: config)
        try migrateIfNeeded(queue)
        database = queue
        return queue
    }

    private func migrateIfNeeded(_ queue: DatabaseQueue) throws {
        if try !queue.read({ try $0.tableExists("credential") }) {
            // With no legacy catalog, this is first-time setup. No Keychain access is needed.
            var imported: [String: Data] = [:]
            if FileManager.default.fileExists(atPath: directory.appending(path: "Catalog.sqlite").path) {
                for account in [AccessController.pinAccount, AccessController.keyAccount] {
                    imported[account] = try legacy.read(account)
                }
            }
            try queue.write { db in
                // Another process may have finished its import while macOS was asking for access.
                guard try !db.tableExists("credential") else { return }
                try db.execute(sql: """
                    CREATE TABLE credential (
                        account TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL,
                        pendingRemoval INTEGER NOT NULL DEFAULT 0
                    )
                    """)
                for (account, value) in imported {
                    try db.execute(sql: "INSERT INTO credential VALUES (?, ?, 1)", arguments: [account, value])
                }
            }
        }

        // Delete the originals only after both values have committed. A failed or interrupted
        // cleanup resumes here, without reimporting an old key or treating an unreadable PIN as absent.
        let pending = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT account FROM credential WHERE pendingRemoval = 1")
        }
        for account in pending {
            try legacy.remove(account)
            try queue.write { db in
                try db.execute(sql: "UPDATE credential SET pendingRemoval = 0 WHERE account = ?", arguments: [account])
            }
        }
    }
}
