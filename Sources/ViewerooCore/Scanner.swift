import Darwin
import Foundation
import GRDB

public struct CatalogScanner: Sendable {
    public let catalog: Catalog
    public init(catalog: Catalog) { self.catalog = catalog }

    static func canOpen(_ url: URL) -> Bool {
        guard let directory = opendir(url.path) else { return false }
        closedir(directory)
        return true
    }

    public func scan(source: CatalogSource, onDiscovery: @Sendable (CatalogEntry) -> Void = { _ in }) throws {
        let generation = try catalog.database.write { db -> Int64 in
            try db.execute(sql: "UPDATE library SET scanClock = scanClock + 1 WHERE id = ?", arguments: [source.libraryID])
            try db.execute(sql: """
                UPDATE source SET generation = (SELECT scanClock FROM library WHERE id = ?), scanPending = 1 WHERE id = ?
                """, arguments: [source.libraryID, source.id])
            guard let value = try Int64.fetchOne(db, sql: "SELECT generation FROM source WHERE id = ?", arguments: [source.id])
            else { throw CatalogError.staleScan }
            return value
        }
        guard Self.canOpen(source.url) else {
            try setReachability(false, source: source, generation: generation)
            return
        }
        try setReachability(true, source: source, generation: generation)

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var traversalError: Error?
        // FileManager will open a symlinked root but cannot enumerate it as a directory.
        // Traverse the target and retain the user-selected path as the catalog identity.
        let linkedRoot = try source.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
        let root = linkedRoot ? source.url.resolvingSymlinksInPath() : source.url
        let rootDepth = root.standardizedFileURL.pathComponents.count
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                         options: [], errorHandler: { _, error in
            traversalError = error
            return false
        }) else { throw CatalogError.unavailableFolder }

        do {
            for case let file as URL in files {
                try Task.checkCancellation()
                guard ["mp4","m4v","mov"].contains(file.pathExtension.lowercased()) else { continue }
                let info = try file.resourceValues(forKeys: keys)
                guard info.isRegularFile == true, info.isSymbolicLink != true,
                      let size = info.fileSize, let modified = info.contentModificationDate else { continue }
                let selectedFile: URL
                if linkedRoot {
                    let relative = file.standardizedFileURL.pathComponents.dropFirst(rootDepth).joined(separator: "/")
                    selectedFile = source.url.appendingPathComponent(relative, isDirectory: false)
                } else {
                    selectedFile = file
                }
                let entry = try discover(file: selectedFile, size: Int64(size), modified: modified.timeIntervalSince1970,
                                         source: source, generation: generation)
                onDiscovery(entry)
            }
            if let traversalError { throw traversalError }
        } catch {
            if !Self.canOpen(source.url) { try setReachability(false, source: source, generation: generation) }
            throw error
        }

        try Task.checkCancellation()
        guard Self.canOpen(source.url) else {
            try setReachability(false, source: source, generation: generation)
            return
        }
        try catalog.database.write { db in
            try verifyGeneration(db, sourceID: source.id, generation: generation)
            // An overlapping scan can discover a file after this scan passed its folder.
            // Only invalidate observations older than the start of this traversal.
            try db.execute(sql: """
                UPDATE membership SET present = 0 WHERE entryID IN (
                    SELECT entryID FROM membership WHERE sourceID = ? AND generation < ?
                ) AND generation < ? AND sourceID IN (SELECT id FROM source WHERE online = 1)
                """, arguments: [source.id, generation, generation])
            try db.execute(sql: "UPDATE source SET scanPending = 0 WHERE id = ?", arguments: [source.id])
        }
    }

    private func setReachability(_ online: Bool, source: CatalogSource, generation: Int64) throws {
        try catalog.database.write { db in
            try verifyGeneration(db, sourceID: source.id, generation: generation)
            try db.execute(sql: "UPDATE source SET online = ? WHERE id = ?", arguments: [online, source.id])
        }
    }

    private func verifyGeneration(_ db: Database, sourceID: Int64, generation: Int64) throws {
        guard try Int64.fetchOne(db, sql: "SELECT generation FROM source WHERE id = ?", arguments: [sourceID]) == generation
        else { throw CatalogError.staleScan }
    }

    private func discover(file: URL, size: Int64, modified: Double, source: CatalogSource, generation: Int64) throws -> CatalogEntry {
        let path = file.standardizedFileURL.path
        return try catalog.database.write { db in
            try verifyGeneration(db, sourceID: source.id, generation: generation)
            try db.execute(sql: """
                INSERT INTO entry(libraryID,path,fileSize,modified) VALUES (?,?,?,?)
                ON CONFLICT(libraryID,path) DO UPDATE SET
                    fileSize = excluded.fileSize, modified = excluded.modified, hash = NULL, playbackFailure = NULL, duration = NULL,
                    matchData = CASE WHEN confirmed THEN matchData END, candidateData = NULL,
                    detectedStudio = NULL, needsLookup = NOT confirmed
                WHERE entry.fileSize <> excluded.fileSize OR entry.modified <> excluded.modified
                """, arguments: [source.libraryID, path, size, modified])
            let id = try Int64.fetchOne(db, sql: "SELECT id FROM entry WHERE libraryID = ? AND path = ?",
                                        arguments: [source.libraryID, path])!
            try db.execute(sql: """
                INSERT INTO membership(libraryID, sourceID, entryID, present, generation)
                SELECT s.libraryID, s.id, ?, 1, l.scanClock FROM source s JOIN library l ON l.id = s.libraryID
                WHERE s.libraryID = ? AND instr(?, rtrim(s.path, '/') || '/') = 1
                ON CONFLICT(sourceID, entryID) DO UPDATE SET present = 1, generation = excluded.generation
                """, arguments: [id, source.libraryID, path])
            return try Catalog.fetchEntry(db, id: id)!
        }
    }
}
