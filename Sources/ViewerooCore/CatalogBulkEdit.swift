import Foundation
import GRDB

public enum BulkVideoEdit: Sendable {
    case favorite(Bool)
    case rating(Int)
    case addToPlaylist(Int64)
    case addTags([String])
    case removeTag(Int64)
    case removeHistory
}

fileprivate struct RemovedTagCover: FetchableRecord, Decodable, Sendable {
    let time: Double
    let image: Data
    let custom: Bool
}

public struct BulkEditReceipt: Sendable {
    fileprivate enum Change: Sendable {
        case favorite(previous: Bool)
        case rating(previous: Int, applied: Int)
        case playlist(Int64)
        case tags([Int64])
        case removedTag(id: Int64, assignment: Int64, cover: RemovedTagCover?)
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
                    let added = try names.compactMap { try Self.assignTag(db, name: $0, entryID: id, libraryID: libraryID) }
                    if !added.isEmpty { receipt.changes[id] = .tags(added) }
                case let .removeTag(tagID):
                    let args: StatementArguments = [tagID, id]
                    if let assignment = try Int64.fetchOne(db, sql: "SELECT id FROM tagItem WHERE tagID = ? AND entryID = ?", arguments: args) {
                        let cover = try RemovedTagCover.fetchOne(db, sql: "SELECT time,image,custom FROM tagCover WHERE tagID = ? AND entryID = ?", arguments: args)
                        try db.execute(sql: "DELETE FROM tagItem WHERE id = ?", arguments: [assignment])
                        receipt.changes[id] = .removedTag(id: tagID, assignment: assignment, cover: cover)
                    }
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
                case let .removedTag(tagID, assignment, cover):
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO tagItem(id,libraryID,tagID,entryID)
                        SELECT ?, t.libraryID, t.id, e.id FROM tag t JOIN entry e ON e.libraryID = t.libraryID
                        WHERE t.id = ? AND e.id = ? AND t.libraryID = ?
                        """, arguments: [assignment, tagID, id, receipt.libraryID])
                    if db.changesCount == 1, let cover {
                        try db.execute(sql: """
                            INSERT INTO tagCover(tagID,entryID,time,image,revision,custom) VALUES (?,?,?,?,?,?)
                            ON CONFLICT(tagID) DO UPDATE SET entryID=excluded.entryID, time=excluded.time,
                                image=excluded.image, revision=excluded.revision, custom=excluded.custom WHERE NOT tagCover.custom
                            """, arguments: [tagID, id, cover.time, cover.image, UUID().uuidString, cover.custom])
                    }
                case let .tags(added):
                    for assignment in added {
                        try db.execute(sql: "DELETE FROM tagItem WHERE entryID = ? AND id = ?", arguments: [id, assignment])
                    }
                }
            }
        }
    }
}
