import Foundation
import os
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
                                       matching filter: String = "needsLookup",
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
                    WHERE libraryID = ? AND \(filter) AND id > ?
                    \(availability)
                    ORDER BY id LIMIT 200
                    """, arguments: [libraryID, after])
            }
            guard let last = batch.last else { return }
            try await process(batch)
            lastID = last.id
        }
    }

    public enum StudioScope: Sendable {
        /// Entries that still await their PRDB lookup. Their guess is replaced.
        case pending
        /// Finished lookups without a title, a manual studio or a guess. A studio that the
        /// user created later, or that joined the directory, can still claim their folder.
        case unassigned
    }

    /// Compute folder clues locally, including when PRDB is temporarily unavailable.
    /// Returns the number of entries whose studio changed.
    @discardableResult
    public static func detectStudios(libraryID: Int64, catalog: Catalog, scope: StudioScope = .pending) async throws -> Int {
        let studios = try catalog.recognizableStudios(libraryID: libraryID)
        guard !studios.isEmpty else { return 0 }
        let recognition = StudioRecognition(studios: studios)
        let filter = scope == .pending ? "needsLookup"
            : "NOT needsLookup AND matchData IS NULL AND manualStudio IS NULL AND detectedStudio IS NULL"
        var changed = 0
        try await pendingBatches(libraryID: libraryID, catalog: catalog, availableOnly: false, matching: filter) { batch in
            for entry in batch {
                try Task.checkCancellation()
                let studio = recognition.match(url: entry.url, sourcePath: entry.sourcePath)
                guard studio?.name != entry.detectedStudio else { continue }
                let saved = scope == .pending
                    ? try catalog.setDetectedStudio(entryID: entry.id, studio: studio, fileSize: entry.fileSize, modified: entry.modified)
                    : try catalog.fillDetectedStudio(entryID: entry.id, studio: studio, fileSize: entry.fileSize, modified: entry.modified)
                if saved { changed += 1 }
            }
        }
        return changed
    }

    /// Lookups that PRDB rejected for request-specific reasons. Other pending videos keep
    /// moving, and each rejected video is retried once its suspension ends.
    public final class Failures: Sendable {
        private let suspended = OSAllocatedUnfairLock(initialState: [Int64: Date]())
        private let suspension: TimeInterval

        public init(suspension: TimeInterval = 6 * 3600) { self.suspension = suspension }

        public var count: Int { suspended.withLock { $0.count } }

        func isSuspended(_ id: Int64, now: Date = Date()) -> Bool {
            suspended.withLock { failures in
                guard let until = failures[id] else { return false }
                if until > now { return true }
                failures[id] = nil
                return false
            }
        }

        func record(_ id: Int64) { suspended.withLock { $0[id] = Date().addingTimeInterval(suspension) } }
        func clear(_ id: Int64) { _ = suspended.withLock { $0.removeValue(forKey: id) } }
    }

    private struct LookupCounts {
        var attempted = 0
        var hashReadErrors = 0
        var rejected = 0
    }

    public static func identify(libraryID: Int64, catalog: Catalog, key: String, client: PRDBClient,
                                failures: Failures = Failures(), searchPacing: Duration = .milliseconds(250),
                                updated: @Sendable () async -> Void) async throws {
        let start = ContinuousClock.now
        var counts = LookupCounts()
        var outcome = ViewerooLog.Outcome.completed
        var failure = "none"
        defer {
            // A retry timer can wake up while every pending entry is still suspended.
            let level: OSLogType = outcome == .completed && counts.attempted == 0 ? .debug : outcome.level
            ViewerooLog.matching.log(level: level, """
                Title lookup \(outcome.rawValue, privacy: .public): attempted=\(counts.attempted) \
                hashReadErrors=\(counts.hashReadErrors) rejected=\(counts.rejected) \
                failure=\(failure, privacy: .public) durationMs=\(ViewerooLog.milliseconds(since: start))
                """)
        }
        do {
            try await identifyPending(libraryID: libraryID, catalog: catalog, key: key, client: client,
                                      failures: failures, searchPacing: searchPacing, counts: &counts, updated: updated)
            if counts.hashReadErrors > 0 || counts.rejected > 0 { outcome = .partial }
        } catch {
            outcome = error is CancellationError || Task.isCancelled ? .cancelled : .failed
            if outcome == .failed { failure = ViewerooLog.failureCode(error) }
            throw error
        }
    }

    private static func identifyPending(libraryID: Int64, catalog: Catalog, key: String, client: PRDBClient,
                                        failures: Failures, searchPacing: Duration, counts: inout LookupCounts,
                                        updated: @Sendable () async -> Void) async throws {
        let recognition = StudioRecognition(studios: try catalog.recognizableStudios(libraryID: libraryID))
        try await pendingBatches(libraryID: libraryID, catalog: catalog, availableOnly: true) { pending in
            let batch = pending.filter { !failures.isSuspended($0.id) }
            var files: [PRDBFile] = []
            for entry in batch {
                try Task.checkCancellation()
                counts.attempted += 1
                var hash = entry.hash
                if hash == nil && entry.fileSize >= 131072 {
                    do { hash = try OSHash.compute(url: entry.url) }
                    catch {
                        counts.hashReadErrors += 1
                        continue
                    }
                    try catalog.setHash(entryID: entry.id, hash: hash, fileSize: entry.fileSize, modified: entry.modified)
                }
                files.append(PRDBFile(ref: String(entry.id), filename: entry.url.lastPathComponent, filesize: entry.fileSize, osHash: hash))
            }
            guard !files.isEmpty else { return }
            let results = try await identifyIsolating(files, key: key, client: client, failures: failures,
                                                      rejected: &counts.rejected)
            var fallback: [(LookupEntry, PRDBStudio?)] = []
            for entry in batch {
                try Task.checkCancellation()
                guard let result = results[String(entry.id)] else { continue }
                let studio = recognition.match(url: entry.url, sourcePath: entry.sourcePath, siteHint: result.studio)
                if result.autoTitle == nil && result.candidates.isEmpty {
                    if studio?.name != entry.detectedStudio {
                        try catalog.setDetectedStudio(entryID: entry.id, studio: studio, fileSize: entry.fileSize, modified: entry.modified)
                    }
                    fallback.append((entry, studio))
                } else {
                    let match = PRDBMatch(autoTitle: result.autoTitle, candidates: result.candidates, studio: studio)
                    try catalog.applyMatch(entryID: entry.id, result: match, fileSize: entry.fileSize, modified: entry.modified)
                    failures.clear(entry.id)
                }
            }
            await updated()
            guard !fallback.isEmpty else { return }
            for (index, (entry, studio)) in fallback.enumerated() {
                try Task.checkCancellation()
                if index > 0, searchPacing > .zero { try await Task.sleep(for: searchPacing) }
                // A release-style file name matches no title until it is reduced to its words.
                let title = SearchTerm.clean(entry.url.deletingPathExtension().lastPathComponent, studio: studio?.name)
                let candidates: [PRDBTitle]
                do { candidates = try await client.search(title, key: key) }
                catch let error as PRDBError where error.isRequestSpecific {
                    failures.record(entry.id)
                    counts.rejected += 1
                    continue
                }
                try Task.checkCancellation()
                try catalog.applyMatch(entryID: entry.id, result: PRDBMatch(candidates: candidates, studio: studio),
                                       fileSize: entry.fileSize, modified: entry.modified)
                failures.clear(entry.id)
            }
            await updated()
        }
    }

    /// Narrow a request-specific rejection down to the files that cause it, so one
    /// problematic video cannot hold back the rest of its batch.
    private static func identifyIsolating(_ files: [PRDBFile], key: String, client: PRDBClient,
                                          failures: Failures, rejected: inout Int) async throws -> [String: PRDBMatch] {
        do {
            return try await client.identify(files, key: key)
        } catch let error as PRDBError where error.isRequestSpecific {
            guard files.count > 1 else {
                rejected += 1
                if let id = files.first.flatMap({ Int64($0.ref) }) { failures.record(id) }
                return [:]
            }
            let middle = files.count / 2
            let first = try await identifyIsolating(Array(files[..<middle]), key: key, client: client,
                                                    failures: failures, rejected: &rejected)
            let second = try await identifyIsolating(Array(files[middle...]), key: key, client: client,
                                                     failures: failures, rejected: &rejected)
            return first.merging(second) { current, _ in current }
        }
    }
}
