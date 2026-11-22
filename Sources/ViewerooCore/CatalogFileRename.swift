import Darwin
import Foundation
import GRDB

public enum FileRenameError: LocalizedError {
    case invalidName, occupied, unavailable, scanning, recovery(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a file name without slashes, colons or control characters."
        case .occupied: "This name is already in use. Choose another name."
        case .unavailable: "The file has changed or is unavailable. Refresh the library and try again."
        case .scanning: "A folder scan is in progress. Try again when it finishes."
        case .recovery(let name): "The catalog could not be saved. The file is on disk as “\(name)”."
        }
    }
}

extension Catalog {
    /// Rename the directory entry in place. Each library keeps its own entry and personal data.
    public func renameFile(_ selection: CatalogEntry, basename input: String) throws {
        let basename = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))
        guard !basename.isEmpty, basename != ".", basename != "..",
              basename.rangeOfCharacter(from: forbidden) == nil else { throw FileRenameError.invalidName }
        let source = selection.url
        let name = basename + "." + source.pathExtension
        let destination = source.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)

        try database.writeWithoutTransaction { db in
            var moved = false
            do {
                try db.inTransaction {
                    guard activeScans.withLock({ $0 == 0 }) else { throw FileRenameError.scanning }
                    guard let entry = try Self.fetchEntry(db, id: selection.id), entry.path == selection.path,
                          entry.availability == .available else { throw FileRenameError.unavailable }
                    let info = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                    guard info.isRegularFile == true, info.isSymbolicLink == false,
                          info.fileSize.map(Int64.init) == selection.fileSize,
                          info.contentModificationDate?.timeIntervalSince1970 == selection.modified else {
                        throw FileRenameError.unavailable
                    }
                    guard name != entry.filename else { return .commit }

                    // A selected source (or its parent) may be a symlink. Retain each library's
                    // selected directory spelling while updating references to this directory entry.
                    let suffix = "/" + entry.filename
                    let paths = try String.fetchAll(db, sql: """
                        SELECT DISTINCT path FROM entry WHERE substr(path, -length(?)) = ?
                        """, arguments: [suffix, suffix])
                    let parent = source.deletingLastPathComponent().resolvingSymlinksInPath()
                    for path in paths {
                        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
                        guard folder.resolvingSymlinksInPath() == parent else { continue }
                        do {
                            try db.execute(sql: "UPDATE entry SET path = ? WHERE path = ?",
                                           arguments: [folder.appendingPathComponent(name).path, path])
                        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
                            throw FileRenameError.occupied
                        }
                    }
                    try Self.moveExclusively(from: source, to: destination)
                    moved = true
                    return .commit
                }
            } catch {
                if moved {
                    do { try Self.moveExclusively(from: destination, to: source) }
                    catch { throw FileRenameError.recovery(name) }
                }
                throw error
            }
        }
    }

    private static func moveExclusively(from source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw FileRenameError.occupied }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }
}
