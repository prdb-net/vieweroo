import Darwin
import Foundation
import GRDB

public enum FileRenameError: LocalizedError {
    case invalidName, nameTooLong, occupied, unavailable, scanning, recovery(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a file name without slashes, colons or control characters."
        case .nameTooLong: "This file name is too long. Choose a shorter name."
        case .occupied: "This name is already in use. Choose another name."
        case .unavailable: "The file has changed or is unavailable. Refresh the library and try again."
        case .scanning: "A folder scan is in progress. Try again when it finishes."
        case .recovery(let name): "The catalog could not be saved. The file is on disk as “\(name)”."
        }
    }
}

extension Catalog {
    /// Rename the directory entry in place. Each library keeps its own entry and personal data.
    ///
    /// The catalog commits the new paths with a pending-rename record before the file moves.
    /// If the app stops in between, `finishInterruptedRenames` completes or undoes the rename.
    @discardableResult
    package func renameFile(_ selection: CatalogEntry, basename: String) throws -> [Int64: Set<Int64>] {
        try renameFile(entryID: selection.id, basename: basename) { entry in
            guard entry.path == selection.path, entry.fileSize == selection.fileSize,
                  entry.modified == selection.modified else { throw FileRenameError.unavailable }
        }.affectedEntries
    }

    func renameFile(entryID: Int64, libraryID: Int64, revision: String, basename: String) throws ->
        (entry: CatalogEntry, affectedEntries: [Int64: Set<Int64>]) {
        try renameFile(entryID: entryID, basename: basename, missing: EnrichmentError.missing) { entry in
            guard entry.libraryID == libraryID else { throw EnrichmentError.missing }
            guard try APIEntryMetadata(entry).revision == revision else { throw EnrichmentError.conflict }
        }
    }

    private func renameFile(entryID: Int64, basename input: String, missing: any Error = FileRenameError.unavailable,
                            validate: (CatalogEntry) throws -> Void) throws ->
        (entry: CatalogEntry, affectedEntries: [Int64: Set<Int64>]) {
        let basename = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))
        guard !basename.isEmpty, basename != ".", basename != "..",
              basename.rangeOfCharacter(from: forbidden) == nil else { throw FileRenameError.invalidName }

        let started = fileActivity.withLock { activity in
            guard activity.scans == 0, !activity.renaming else { return false }
            activity.renaming = true
            return true
        }
        guard started else { throw FileRenameError.scanning }
        defer { fileActivity.withLock { $0.renaming = false } }

        let (entry, source, affected) = try database.write { db -> (CatalogEntry, URL, [Int64: Set<Int64>]) in
            guard let entry = try Self.fetchEntry(db, id: entryID) else { throw missing }
            try validate(entry)
            let source = entry.url
            guard entry.availability == .available,
                  let info = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                  info.isRegularFile == true, info.isSymbolicLink == false,
                  info.fileSize.map(Int64.init) == entry.fileSize,
                  info.contentModificationDate?.timeIntervalSince1970 == entry.modified else {
                throw FileRenameError.unavailable
            }
            let name = basename + "." + source.pathExtension
            guard name != entry.filename else { return (entry, source, [:]) }
            let affected = try Self.updatePaths(db, of: source, to: name)
            guard affected[entry.libraryID]?.contains(entryID) == true,
                  let updated = try Self.fetchEntry(db, id: entryID) else { throw FileRenameError.unavailable }
            try db.execute(sql: "INSERT OR REPLACE INTO pendingRename(entryID, fromPath, toPath) VALUES (?, ?, ?)",
                           arguments: [entryID, source.path, updated.path])
            return (updated, source, affected)
        }
        guard !affected.isEmpty else { return (entry, affected) }
        let destination = entry.url

        do {
            try Self.moveExclusively(from: source, to: destination)
        } catch {
            // The file stayed in place. Restore the catalog paths, or leave the record for the next launch.
            do {
                try database.write { db in
                    try Self.updatePaths(db, of: destination, to: source.lastPathComponent)
                    try db.execute(sql: "DELETE FROM pendingRename WHERE entryID = ?", arguments: [entryID])
                }
            } catch { throw FileRenameError.recovery(source.lastPathComponent) }
            throw error
        }
        // A remaining record only means that the next launch confirms the completed move.
        try? database.write { db in
            try db.execute(sql: "DELETE FROM pendingRename WHERE entryID = ?", arguments: [entryID])
        }
        return (entry, affected)
    }

    /// Complete a rename whose file moved, and undo one whose file did not.
    /// Keep the record while neither name is reachable, for example on a disconnected drive.
    func finishInterruptedRenames() throws {
        try database.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT entryID, fromPath, toPath FROM pendingRename")
            for row in rows {
                let id: Int64 = row["entryID"]
                let from = URL(fileURLWithPath: row["fromPath"], isDirectory: false)
                let to = URL(fileURLWithPath: row["toPath"], isDirectory: false)
                let moved = Self.exactlyExists(to), original = Self.exactlyExists(from)
                if moved == original {
                    // Neither name is reachable, or both exist and the result is ambiguous.
                    if moved { try db.execute(sql: "DELETE FROM pendingRename WHERE entryID = ?", arguments: [id]) }
                    continue
                }
                if original {
                    do { try Self.updatePaths(db, of: to, to: from.lastPathComponent) }
                    catch FileRenameError.occupied { /* A later scan reconciles the conflicting entry. */ }
                }
                try db.execute(sql: "DELETE FROM pendingRename WHERE entryID = ?", arguments: [id])
            }
        }
    }

    /// A selected source (or its parent) may be a symlink. Retain each library's selected
    /// directory spelling while updating references to this directory entry.
    @discardableResult
    private static func updatePaths(_ db: Database, of file: URL, to name: String) throws -> [Int64: Set<Int64>] {
        let suffix = "/" + file.lastPathComponent
        let paths = try String.fetchAll(db, sql: """
            SELECT DISTINCT path FROM entry WHERE substr(path, -length(?)) = ?
            """, arguments: [suffix, suffix])
        let parent = file.deletingLastPathComponent().resolvingSymlinksInPath()
        var affected: [Int64: Set<Int64>] = [:]
        for path in paths {
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
            guard folder.resolvingSymlinksInPath() == parent else { continue }
            do {
                let renamed = try Row.fetchAll(db, sql: "UPDATE entry SET path = ? WHERE path = ? RETURNING libraryID, id",
                                               arguments: [folder.appendingPathComponent(name).path, path])
                for row in renamed { affected[row["libraryID"], default: []].insert(row["id"]) }
            } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
                throw FileRenameError.occupied
            }
        }
        return affected
    }

    /// Compare the exact spelling, because a case-only rename leaves both names resolvable.
    private static func exactlyExists(_ file: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)) ?? []
        return names.contains(file.lastPathComponent)
    }

    private static func moveExclusively(from source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            switch code {
            case EEXIST: throw FileRenameError.occupied
            case ENAMETOOLONG: throw FileRenameError.nameTooLong
            case ENOENT: throw FileRenameError.unavailable
            default: throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
        }
    }
}
