import Foundation
import GRDB

public enum LibraryJobs {
    private struct LookupEntry: FetchableRecord, Decodable {
        let id: Int64
        let path: String
        let fileSize: Int64
        let modified: Double
        let hash: String?
        let detectedStudio: String?
        let sourcePath: String?
        var url: URL { URL(fileURLWithPath: path, isDirectory: false) }
    }

    // Advance by primary key even if a file could not be read and remains pending.
    private static func pendingBatches(libraryID: Int64, catalog: Catalog, availableOnly: Bool,
                                       process: ([LookupEntry]) async throws -> Void) async throws {
        let availability = availableOnly ? """
             AND EXISTS (SELECT 1 FROM membership m JOIN source s ON s.id = m.sourceID
                         WHERE m.entryID = e.id AND m.present AND s.online)
            """ : ""
        var lastID: Int64 = 0
        while true {
            try Task.checkCancellation()
            let after = lastID
            let batch = try await catalog.database.read { db in
                try LookupEntry.fetchAll(db, sql: """
                    SELECT id, path, fileSize, modified, hash, detectedStudio, \(Catalog.studioSourcePathSQL) AS sourcePath
                    FROM entry e
                    WHERE libraryID = ? AND needsLookup AND id > ?
                    \(availability)
                    ORDER BY id LIMIT 200
                    """, arguments: [libraryID, after])
            }
            guard let last = batch.last else { return }
            try await process(batch)
            lastID = last.id
        }
    }

    /// Compute folder clues locally, including when PRDB is temporarily unavailable.
    public static func detectStudios(libraryID: Int64, catalog: Catalog) async throws {
        let studios = try catalog.studios()
        guard !studios.isEmpty else { return }
        let recognition = StudioRecognition(studios: studios)
        try await pendingBatches(libraryID: libraryID, catalog: catalog, availableOnly: false) { batch in
            for entry in batch {
                try Task.checkCancellation()
                let name = recognition.match(url: entry.url, sourcePath: entry.sourcePath)?.name
                if name != entry.detectedStudio {
                    try catalog.setDetectedStudio(entryID: entry.id, name: name, fileSize: entry.fileSize, modified: entry.modified)
                }
            }
        }
    }

    public static func identify(libraryID: Int64, catalog: Catalog, key: String, client: PRDBClient,
                                updated: @Sendable () async -> Void) async throws {
        let recognition = StudioRecognition(studios: try catalog.studios())
        try await pendingBatches(libraryID: libraryID, catalog: catalog, availableOnly: true) { batch in
            var files: [PRDBFile] = []
            for entry in batch {
                try Task.checkCancellation()
                var hash = entry.hash
                if hash == nil && entry.fileSize >= 131072 {
                    do { hash = try OSHash.compute(url: entry.url) }
                    catch { continue }
                    try catalog.setHash(entryID: entry.id, hash: hash, fileSize: entry.fileSize, modified: entry.modified)
                }
                files.append(PRDBFile(ref: String(entry.id), filename: entry.url.lastPathComponent, filesize: entry.fileSize, osHash: hash))
            }
            let results = try await client.identify(files, key: key)
            var fallback: [(LookupEntry, PRDBStudio?)] = []
            for entry in batch {
                try Task.checkCancellation()
                guard let result = results[String(entry.id)] else { continue }
                let studio = recognition.match(url: entry.url, sourcePath: entry.sourcePath, siteHint: result.studio)
                if result.autoTitle == nil && result.candidates.isEmpty {
                    if studio?.name != entry.detectedStudio {
                        try catalog.setDetectedStudio(entryID: entry.id, name: studio?.name, fileSize: entry.fileSize, modified: entry.modified)
                    }
                    fallback.append((entry, studio))
                } else {
                    let match = PRDBMatch(autoTitle: result.autoTitle, candidates: result.candidates, studio: studio)
                    try catalog.applyMatch(entryID: entry.id, result: match, fileSize: entry.fileSize, modified: entry.modified)
                }
            }
            await updated()
            guard !fallback.isEmpty else { return }
            for (entry, studio) in fallback {
                try Task.checkCancellation()
                let title = entry.url.deletingPathExtension().lastPathComponent
                let candidates = try await client.search(title, key: key)
                try Task.checkCancellation()
                try catalog.applyMatch(entryID: entry.id, result: PRDBMatch(candidates: candidates, studio: studio),
                                       fileSize: entry.fileSize, modified: entry.modified)
            }
            await updated()
        }
    }
}
