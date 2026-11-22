import Foundation
import GRDB

public enum BulkVideoEdit: Sendable {
    case favorite(Bool)
    case rating(Int)
    case addToPlaylist(Int64)
    case addTags([String])
    case removeHistory
}

public struct BulkEditReceipt: Sendable {
    fileprivate enum Change: Sendable {
        case favorite(previous: Bool)
        case rating(previous: Int, applied: Int)
        case playlist(Int64)
        case tags([String])
        case history([RemovedPlaybackSession])
    }

    public let libraryID: Int64
    fileprivate var changes: [Int64: Change] = [:]
    public var changedCount: Int { changes.count }
}

extension Catalog {
    /// Applies one edit atomically, preserving the supplied order when appending to a playlist.
    public func editVideos(in libraryID: Int64, entryIDs: [Int64], edit: BulkVideoEdit) throws -> BulkEditReceipt {
        try database.write { db in
            var receipt = BulkEditReceipt(libraryID: libraryID)
            for id in entryIDs {
                guard let row = try Row.fetchOne(db, sql: "SELECT favorite, rating FROM entry WHERE libraryID = ? AND id = ?",
                                                 arguments: [libraryID, id]) else { throw CatalogError.invalidValue }
                switch edit {
                case let .favorite(value):
                    let previous: Bool = row["favorite"]
                    if value != previous {
                        try db.execute(sql: "UPDATE entry SET favorite = ? WHERE id = ?", arguments: [value, id])
                        receipt.changes[id] = .favorite(previous: previous)
                    }
                case let .rating(value):
                    let previous: Int = row["rating"]
                    if value != previous {
                        try db.execute(sql: "UPDATE entry SET rating = ? WHERE id = ?", arguments: [value, id])
                        receipt.changes[id] = .rating(previous: previous, applied: value)
                    }
                case let .addToPlaylist(playlistID):
                    if try Self.appendToPlaylist(db, playlistID: playlistID, entryID: id) {
                        receipt.changes[id] = .playlist(playlistID)
                    }
                case .removeHistory:
                    let sessions = try Self.removeHistory(db, entryID: id)
                    if !sessions.isEmpty { receipt.changes[id] = .history(sessions) }
                case let .addTags(names):
                    var existing = try String.fetchAll(db, sql: "SELECT name FROM entryTag WHERE entryID = ?", arguments: [id])
                    var added: [String] = []
                    for name in names {
                        let tag = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !tag.isEmpty, !existing.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { continue }
                        try db.execute(sql: "INSERT INTO entryTag(entryID, name) VALUES (?, ?)", arguments: [id, tag])
                        added.append(tag)
                        existing.append(tag)
                    }
                    if !added.isEmpty { receipt.changes[id] = .tags(added) }
                }
            }
            return receipt
        }
    }

    public func undoVideoEdit(_ receipt: BulkEditReceipt) throws {
        try database.write { db in
            for (id, change) in receipt.changes {
                switch change {
                case let .favorite(previous):
                    try db.execute(sql: "UPDATE entry SET favorite = ? WHERE id = ? AND libraryID = ? AND favorite = ?",
                                   arguments: [previous, id, receipt.libraryID, !previous])
                case let .rating(previous, applied):
                    try db.execute(sql: "UPDATE entry SET rating = ? WHERE id = ? AND libraryID = ? AND rating = ?",
                                   arguments: [previous, id, receipt.libraryID, applied])
                case let .playlist(playlistID):
                    try db.execute(sql: "DELETE FROM playlistItem WHERE libraryID = ? AND playlistID = ? AND entryID = ?",
                                   arguments: [receipt.libraryID, playlistID, id])
                case let .history(sessions):
                    try Self.restoreHistory(db, sessions: sessions, entryID: id, libraryID: receipt.libraryID)
                case let .tags(added):
                    for tag in added {
                        try db.execute(sql: "DELETE FROM entryTag WHERE entryID = ? AND name = ?", arguments: [id, tag])
                    }
                }
            }
        }
    }
}
