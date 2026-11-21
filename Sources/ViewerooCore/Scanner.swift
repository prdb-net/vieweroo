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

    // A selected root may itself be a link. An ancestor above the last link
    // cannot discover its files, because recursive enumeration skips links.
    static func traversalBoundary(for root: URL, upTo ancestor: String = "/") -> String {
        var directory = root
        while directory.path != ancestor && directory.path != "/" {
            var info = stat()
            guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else {
                return directory.path
            }
            directory.deleteLastPathComponent()
        }
        return directory.path
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
        var unreadablePaths = Set<String>()
        var links = Set<String>()
        let prefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
        let nestedSources = try catalog.sources(libraryID: source.libraryID).filter {
            $0.id != source.id && $0.path.hasPrefix(prefix)
        }
        let boundary = Self.traversalBoundary(for: source.url)
        if boundary != "/" { links.insert(boundary) }
        // Retain the selected path as the entry identity even when the root is linked.
        let root = source.url.resolvingSymlinksInPath()
        let rootDepth = root.pathComponents.count
        let remap = root.standardizedFileURL.path != source.path
        func selectedURL(for item: URL) -> URL {
            guard remap else { return item }
            let relative = item.standardizedFileURL.pathComponents.dropFirst(rootDepth)
            return source.url.appendingPathComponent(relative.joined(separator: "/"), isDirectory: false)
        }
        func rememberError(at item: URL, _ error: Error) {
            unreadablePaths.insert(selectedURL(for: item).standardizedFileURL.path)
            traversalError = traversalError ?? error
        }
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                         options: [], errorHandler: { url, error in
            rememberError(at: url, error)
            return true
        }) else { throw CatalogError.unavailableFolder }

        do {
            for case let file as URL in files {
                try Task.checkCancellation()
                let supported = ["mp4","m4v","mov"].contains(file.pathExtension.lowercased())
                guard supported || !nestedSources.isEmpty else { continue }
                let info: URLResourceValues
                do { info = try file.resourceValues(forKeys: keys) }
                catch { rememberError(at: file, error); continue }
                if info.isSymbolicLink == true {
                    let path = selectedURL(for: file).standardizedFileURL.path
                    if nestedSources.contains(where: { $0.path == path || $0.path.hasPrefix(path + "/") }) {
                        links.insert(path)
                    }
                    continue
                }
                guard supported, info.isRegularFile != false else { continue }
                guard info.isRegularFile == true, let size = info.fileSize, let modified = info.contentModificationDate else {
                    rememberError(at: file, CocoaError(.fileReadUnknown))
                    continue
                }
                let entry = try discover(file: selectedURL(for: file), size: Int64(size), modified: modified.timeIntervalSince1970,
                                         source: source, generation: generation, boundary: boundary)
                onDiscovery(entry)
            }
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
            // Older catalogs inferred membership solely from a path prefix. Remove
            // claims across links, retaining the membership of any explicitly selected linked root.
            for link in links {
                try db.execute(sql: """
                    DELETE FROM membership WHERE generation < ? AND sourceID IN (
                        SELECT id FROM source WHERE libraryID = ? AND instr(?, rtrim(path, '/') || '/') = 1
                    ) AND entryID IN (
                        SELECT child.entryID FROM membership child JOIN source s ON s.id = child.sourceID
                        WHERE s.libraryID = ? AND instr(rtrim(s.path, '/') || '/', rtrim(?, '/') || '/') = 1
                    )
                    """, arguments: [generation, source.libraryID, link, source.libraryID, link])
            }
            // Carry forward the previous observation under each unreadable path.
            // Missing files in successfully traversed siblings can still be reconciled.
            for path in unreadablePaths {
                try db.execute(sql: """
                    UPDATE membership SET generation = ? WHERE sourceID = ? AND generation < ? AND entryID IN (
                        SELECT id FROM entry WHERE libraryID = ? AND (path = ? OR instr(path, rtrim(?, '/') || '/') = 1)
                    )
                    """, arguments: [generation, source.id, generation, source.libraryID, path, path])
            }
            // An overlapping scan can discover a file after this scan passed its folder.
            // Only invalidate observations older than the start of this traversal.
            try db.execute(sql: """
                UPDATE membership SET present = 0 WHERE entryID IN (
                    SELECT entryID FROM membership WHERE sourceID = ? AND generation < ?
                ) AND generation < ? AND sourceID IN (SELECT id FROM source WHERE online = 1)
                """, arguments: [source.id, generation, generation])
            try db.execute(sql: "UPDATE source SET scanPending = ? WHERE id = ?", arguments: [traversalError != nil, source.id])
        }
        if let traversalError { throw traversalError }
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

    private func discover(file: URL, size: Int64, modified: Double, source: CatalogSource, generation: Int64, boundary: String) throws -> CatalogEntry {
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
                    AND instr(rtrim(s.path, '/') || '/', rtrim(?, '/') || '/') = 1
                ON CONFLICT(sourceID, entryID) DO UPDATE SET present = 1, generation = excluded.generation
                """, arguments: [id, source.libraryID, path, boundary])
            return try Catalog.fetchEntry(db, id: id)!
        }
    }
}
