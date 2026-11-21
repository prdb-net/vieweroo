import Foundation

public enum LibraryJobs {
    /// Compute folder clues locally, including when PRDB is temporarily unavailable.
    public static func detectStudios(libraryID: Int64, catalog: Catalog) async throws {
        let recognition = StudioRecognition(studios: try catalog.studios())
        for entry in try catalog.entries(libraryID: libraryID) where entry.needsLookup {
            try Task.checkCancellation()
            if let studio = recognition.match(url: entry.url), studio.name != entry.detectedStudio {
                try catalog.setDetectedStudio(entryID: entry.id, name: studio.name, fileSize: entry.fileSize, modified: entry.modified)
            }
        }
    }

    public static func identify(libraryID: Int64, catalog: Catalog, key: String, client: PRDBClient,
                                updated: @Sendable () async -> Void) async throws {
        let pending = try catalog.entries(libraryID: libraryID).filter { $0.needsLookup && $0.availability == .available }
        let recognition = StudioRecognition(studios: try catalog.studios())
        for first in stride(from: 0, to: pending.count, by: 200) {
            var files: [PRDBFile] = []
            let batch = pending[first..<min(first + 200, pending.count)]
            for entry in batch {
                try Task.checkCancellation()
                var hash = entry.hash
                if hash == nil && entry.fileSize >= 131072 {
                    do { hash = try OSHash.compute(url: entry.url) }
                    catch { continue }
                    try catalog.setHash(entryID: entry.id, hash: hash, fileSize: entry.fileSize, modified: entry.modified)
                }
                files.append(PRDBFile(ref: String(entry.id), filename: entry.filename, filesize: entry.fileSize, osHash: hash))
            }
            let results = try await client.identify(files, key: key)
            var fallback: [(CatalogEntry, PRDBStudio?)] = []
            for entry in batch {
                try Task.checkCancellation()
                guard let result = results[String(entry.id)] else { continue }
                let studio = result.studio ?? recognition.match(url: entry.url)
                if result.autoTitle == nil && result.candidates.isEmpty {
                    if let studio {
                        try catalog.setDetectedStudio(entryID: entry.id, name: studio.name, fileSize: entry.fileSize, modified: entry.modified)
                    }
                    fallback.append((entry, studio))
                } else {
                    let match = PRDBMatch(autoTitle: result.autoTitle, candidates: result.candidates, studio: studio)
                    try catalog.applyMatch(entryID: entry.id, result: match, fileSize: entry.fileSize, modified: entry.modified)
                }
            }
            await updated()
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
