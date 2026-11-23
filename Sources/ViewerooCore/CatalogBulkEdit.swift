import Foundation
import GRDB

public enum BulkVideoEdit: Sendable {
    case favorite(Bool)
    case rating(Int)
    case addToPlaylist(Int64)
    case removeFromPlaylist(Int64)
    case addTags([String])
    case removeTag(Int64)
    case removeHistory
}

fileprivate struct RemovedCover: FetchableRecord, Decodable, Sendable {
    let time: Double
    let image: Data
    let custom: Bool
}

public struct BulkEditReceipt: Sendable {
    fileprivate enum Change: Sendable {
        case favorite(previous: Bool)
        case rating(previous: Int, applied: Int)
        case playlist(Int64)
        case removedPlaylistItem(RemovedCover?)
        case tags([Int64])
        case removedTag(id: Int64, assignment: Int64, cover: RemovedCover?)
        case history([RemovedPlaybackSession])
    }

    fileprivate struct PlaylistRemoval: Sendable {
        let playlistID: Int64
        let originalOrder: [Int64]
    }

    fileprivate var playlistRemoval: PlaylistRemoval?
    public let libraryID: Int64
    fileprivate var changes: [Int64: Change] = [:]
    public var changedCount: Int { changes.count }
}

extension Catalog {
    /// Applies one edit atomically, preserving the supplied order when appending to a playlist.
    public func editVideos(in libraryID: Int64, entryIDs: [Int64], edit: BulkVideoEdit) throws -> BulkEditReceipt {
        try database.write { db in
            var receipt = BulkEditReceipt(libraryID: libraryID)
            if case let .removeFromPlaylist(playlistID) = edit {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM playlist WHERE id = ? AND libraryID = ?)",
                                        arguments: [playlistID, libraryID]) == true else { throw CatalogError.invalidValue }
                receipt.playlistRemoval = .init(playlistID: playlistID, originalOrder: try Self.playlistEntryIDs(db, playlistID))
            }
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
                case let .removeFromPlaylist(playlistID):
                    let args: StatementArguments = [playlistID, id]
                    let cover = try RemovedCover.fetchOne(db, sql: "SELECT time,image,custom FROM playlistCover WHERE playlistID = ? AND entryID = ?", arguments: args)
                    try db.execute(sql: "DELETE FROM playlistItem WHERE playlistID = ? AND entryID = ?", arguments: args)
                    if db.changesCount == 1 { receipt.changes[id] = .removedPlaylistItem(cover) }
                case .removeHistory:
                    let sessions = try Self.removeHistory(db, entryID: id)
                    if !sessions.isEmpty { receipt.changes[id] = .history(sessions) }
                case let .addTags(names):
                    let added = try names.compactMap { try Self.assignTag(db, name: $0, entryID: id, libraryID: libraryID) }
                    if !added.isEmpty { receipt.changes[id] = .tags(added) }
                case let .removeTag(tagID):
                    let args: StatementArguments = [tagID, id]
                    if let assignment = try Int64.fetchOne(db, sql: "SELECT id FROM tagItem WHERE tagID = ? AND entryID = ?", arguments: args) {
                        let cover = try RemovedCover.fetchOne(db, sql: "SELECT time,image,custom FROM tagCover WHERE tagID = ? AND entryID = ?", arguments: args)
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
            if let removal = receipt.playlistRemoval {
                try Self.restorePlaylistItems(db, receipt: receipt, removal: removal)
                return
            }
            for (id, change) in receipt.changes {
                switch change {
                case let .favorite(previous):
                    try db.execute(sql: "UPDATE entry SET favorite = ? WHERE id = ? AND libraryID = ? AND favorite = ?",
                                   arguments: [previous, id, receipt.libraryID, !previous])
                case let .rating(previous, applied):
                    try db.execute(sql: "UPDATE entry SET rating = ? WHERE id = ? AND libraryID = ? AND rating = ?",
                                   arguments: [previous, id, receipt.libraryID, applied])
                case .removedPlaylistItem: break // Restored together in playlist order above.
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

    private static func restorePlaylistItems(_ db: Database, receipt: BulkEditReceipt,
                                             removal: BulkEditReceipt.PlaylistRemoval) throws {
        let playlist = removal.playlistID
        let current = try playlistEntryIDs(db, playlist)
        let present = Set(current)
        // Reinsert each missing run after its nearest surviving predecessor. This also
        // preserves later appends, reorders and videos independently added back.
        var predecessor: Int64?
        var restoredAfter: [Int64?: [Int64]] = [:]
        for id in removal.originalOrder {
            if present.contains(id) {
                predecessor = id
            } else if case let .removedPlaylistItem(cover) = receipt.changes[id] {
                try db.execute(sql: """
                    INSERT INTO playlistItem(libraryID,playlistID,entryID,position)
                    SELECT p.libraryID,p.id,e.id,0 FROM playlist p JOIN entry e ON e.libraryID = p.libraryID
                    WHERE p.id = ? AND e.id = ? AND p.libraryID = ?
                    """, arguments: [playlist, id, receipt.libraryID])
                guard db.changesCount == 1 else { continue }
                restoredAfter[predecessor, default: []].append(id)
                if let cover {
                    try db.execute(sql: """
                        INSERT INTO playlistCover(playlistID,entryID,time,image,revision,custom) VALUES (?,?,?,?,?,?)
                        ON CONFLICT(playlistID) DO UPDATE SET entryID=excluded.entryID, time=excluded.time,
                            image=excluded.image, revision=excluded.revision, custom=excluded.custom WHERE NOT playlistCover.custom
                        """, arguments: [playlist, id, cover.time, cover.image, UUID().uuidString, cover.custom])
                }
            }
        }
        guard !restoredAfter.isEmpty else { return }
        var order = restoredAfter[nil] ?? []
        for id in current {
            order.append(id)
            if let restored = restoredAfter[id] { order.append(contentsOf: restored) }
        }
        try writePlaylistOrder(db, playlistID: playlist, entryIDs: order)
    }
}
