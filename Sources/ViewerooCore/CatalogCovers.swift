import Foundation
import GRDB

public struct CatalogCover: Hashable, Sendable {
    public let entryID: Int64
    public let time: Double
    public let revision: String
    public let isCustom: Bool

    init?(_ row: Row) {
        guard let revision: String = row["revision"] else { return nil }
        self.revision = revision
        entryID = row["entryID"]
        time = row["time"]
        isCustom = row["custom"]
    }
}

public enum CoverCollectionID: Hashable, Sendable {
    case tag(Int64), playlist(Int64), studio(libraryID: Int64, studioID: String)

    fileprivate var tablePrefix: String {
        switch self {
        case .tag: "tag"
        case .playlist: "playlist"
        case .studio: "studio"
        }
    }

    fileprivate var predicate: String {
        switch self {
        case .tag, .playlist: "\(tablePrefix)ID = ?"
        case .studio: "libraryID = ? AND studioID = ?"
        }
    }

    fileprivate var arguments: StatementArguments {
        switch self {
        case let .tag(id), let .playlist(id): [id]
        case let .studio(libraryID, studioID): [libraryID, studioID]
        }
    }
}

extension Catalog {
    public func coverImage(_ collection: CoverCollectionID) async throws -> Data? {
        let prefix = collection.tablePrefix
        return try await database.read { db in
            try Data.fetchOne(db, sql: "SELECT image FROM \(prefix)Cover WHERE \(collection.predicate)", arguments: collection.arguments)
        }
    }

    @discardableResult
    public func saveCover(_ collection: CoverCollectionID, entryID: Int64, time: Double, image: Data, custom: Bool) throws -> Bool {
        guard time.isFinite, time >= 0, !image.isEmpty else { throw CatalogError.invalidValue }
        let prefix = collection.tablePrefix
        return try database.write { db in
            if case let .studio(libraryID, studioID) = collection {
                guard custom, let entry = try Self.fetchEntry(db, id: entryID), entry.libraryID == libraryID,
                      try StudioDirectory(Self.studioOptions(db, libraryID: libraryID)).studio(for: entry).id == studioID
                else { throw CatalogError.invalidValue }
                try db.execute(sql: """
                    INSERT INTO studioCover(libraryID,studioID,entryID,time,image,revision) VALUES (?,?,?,?,?,?)
                    ON CONFLICT(libraryID,studioID) DO UPDATE SET entryID=excluded.entryID,
                        time=excluded.time, image=excluded.image, revision=excluded.revision
                    """, arguments: [libraryID, studioID, entryID, time, image, UUID().uuidString])
                return true
            }
            let frameArguments: StatementArguments = [time, image, UUID().uuidString, custom]
            // Never overwrite a user's choice with a background preview.
            let conflict = custom ? "DO UPDATE SET entryID=excluded.entryID, time=excluded.time, image=excluded.image, revision=excluded.revision, custom=1" : "DO NOTHING"
            try db.execute(sql: """
                INSERT INTO \(prefix)Cover(\(prefix)ID,entryID,time,image,revision,custom)
                SELECT \(prefix)ID,entryID,?,?,?,? FROM \(prefix)Item WHERE \(collection.predicate) AND entryID = ?
                ON CONFLICT(\(prefix)ID) \(conflict)
                """, arguments: frameArguments + collection.arguments + [entryID])
            if custom && db.changesCount == 0 { throw CatalogError.invalidValue }
            return db.changesCount > 0
        }
    }

    public func resetCover(_ collection: CoverCollectionID) throws {
        let prefix = collection.tablePrefix
        try database.write { db in
            try db.execute(sql: "DELETE FROM \(prefix)Cover WHERE \(collection.predicate)", arguments: collection.arguments)
        }
    }
}
