import CryptoKit
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

/// Only these fields leave the catalog. Keep paths, playback history and credentials private.
struct APIEntry: Encodable {
    let metadata: APIEntryMetadata
    let fileSize: Int64
    let osHash: String?

    init(_ entry: CatalogEntry) throws {
        metadata = try APIEntryMetadata(entry)
        fileSize = entry.fileSize
        osHash = entry.hash.flatMap { UInt64($0, radix: 16) }.map { String(format: "%016llx", $0) }
    }

    private enum FileKeys: String, CodingKey { case fileSize, osHash }

    func encode(to encoder: Encoder) throws {
        try metadata.encode(to: encoder)
        var fields = encoder.container(keyedBy: FileKeys.self)
        try fields.encode(fileSize, forKey: .fileSize)
        try fields.encodeIfPresent(osHash, forKey: .osHash)
    }
}

/// The enrichment revision covers metadata independently of background file identification.
struct APIEntryMetadata: Encodable {
    let id, libraryID: Int64
    let filename, title: String
    let localTitle, description, studio, manualStudio, siteID, prdbTitleID, posterRevision: String?
    let tags: [String]
    private(set) var revision: String?

    init(_ entry: CatalogEntry) throws {
        id = entry.id
        libraryID = entry.libraryID
        filename = entry.filename
        title = entry.title
        localTitle = entry.localTitle
        description = entry.localDescription
        studio = entry.studio
        manualStudio = entry.manualStudio
        siteID = entry.manualSiteID ?? (entry.manualStudio == nil ? entry.match?.studio?.id : nil)
        prdbTitleID = entry.match?.id
        posterRevision = entry.posterRevision
        tags = entry.tags.sorted()
        // Hash the same representation for reads and writes, including edits made in the UI.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        revision = Data(SHA256.hash(data: try encoder.encode(self))).base64EncodedString()
    }
}

private enum Field<Value> {
    case omitted, set(Value?)
}

struct EnrichmentPatch {
    let revision: String
    fileprivate let title, description, studio, siteID: Field<String>
    fileprivate let tags: [String]
    fileprivate let poster: Field<Data>

    init(_ body: Data) throws {
        let allowed = ["revision", "title", "description", "studio", "siteID", "addTags", "poster"]
        guard let fields = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              fields.count > 1, fields.keys.allSatisfy(allowed.contains),
              let revision = fields["revision"] as? String, !revision.isEmpty,
              fields["studio"] == nil || fields["siteID"] == nil else { throw CatalogError.invalidValue }
        self.revision = revision
        func string(_ key: String, limit: Int) throws -> Field<String> {
            guard let value = fields[key] else { return .omitted }
            if value is NSNull { return .set(nil) }
            guard let text = value as? String else { throw CatalogError.invalidValue }
            return .set(try Self.clean(text, limit: limit))
        }
        title = try string("title", limit: 1024)
        description = try string("description", limit: 65536)
        studio = try string("studio", limit: 256)
        siteID = try string("siteID", limit: 256)
        if let values = fields["addTags"] {
            guard let names = values as? [String], names.count <= 200 else { throw CatalogError.invalidValue }
            tags = try names.map { try Self.clean($0, limit: 256) }
        } else { tags = [] }
        if let value = fields["poster"] {
            if value is NSNull { poster = .set(nil) }
            else {
                guard let base64 = value as? String, let bytes = Data(base64Encoded: base64) else { throw CatalogError.invalidValue }
                poster = .set(try Self.makePoster(bytes))
            }
        } else { poster = .omitted }
    }

    static func clean(_ text: String, limit: Int) throws -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= limit, !clean.utf8.contains(0) else { throw CatalogError.invalidValue }
        return clean
    }

    private static func makePoster(_ bytes: Data) throws -> Data {
        guard bytes.count <= 5 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let type = CGImageSourceGetType(source) as String?, [UTType.jpeg.identifier, UTType.png.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...16384).contains(width), (1...16384).contains(height), width * height <= 40_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600
              ] as CFDictionary) else { throw CatalogError.invalidValue }
        let output = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CatalogError.invalidValue
        }
        CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { throw CatalogError.invalidValue }
        return output as Data
    }
}

enum EnrichmentError: Error { case missing, conflict }

extension Catalog {
    static func requireLibrary(_ db: Database, _ id: Int64) throws {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM library WHERE id = ?)", arguments: [id]) == true
        else { throw EnrichmentError.missing }
    }

    func apiEntries(library: Int64, after: Int64, limit: Int, osHash: String?, fileSize: Int64?) throws -> [APIEntry] {
        try database.read { db in
            try Self.requireLibrary(db, library)
            var sql = Self.entryQuery + " WHERE e.libraryID = ? AND e.id > ?"
            var arguments: StatementArguments = [library, after]
            if let osHash {
                sql += " AND e.hash = ? COLLATE NOCASE"
                arguments += [osHash]
            }
            if let fileSize {
                sql += " AND e.fileSize = ?"
                arguments += [fileSize]
            }
            return try Row.fetchAll(db, sql: sql + " ORDER BY e.id LIMIT ?", arguments: arguments + [limit])
                .map { try APIEntry(CatalogEntry($0)) }
        }
    }

    private static func apiEntry(_ db: Database, library: Int64, id: Int64) throws -> APIEntry {
        guard let row = try Row.fetchOne(db, sql: entryQuery + " WHERE e.libraryID = ? AND e.id = ?", arguments: [library, id])
        else { throw EnrichmentError.missing }
        return try APIEntry(CatalogEntry(row))
    }

    func apiEntry(library: Int64, id: Int64) throws -> APIEntry {
        try database.read { try Self.apiEntry($0, library: library, id: id) }
    }

    func apply(_ patch: EnrichmentPatch, library: Int64, id: Int64) throws -> APIEntryMetadata {
        try database.write { db in
            let entry = try Self.apiEntry(db, library: library, id: id)
            guard entry.metadata.revision == patch.revision else { throw EnrichmentError.conflict }
            if case let .set(value) = patch.title {
                try db.execute(sql: "UPDATE entry SET localTitle = ? WHERE id = ?", arguments: [value, id])
            }
            if case let .set(value) = patch.description {
                try db.execute(sql: "UPDATE entry SET localDescription = ? WHERE id = ?", arguments: [value, id])
            }
            if case let .set(name) = patch.studio {
                try Self.setManualStudio(db, libraryID: library, entryID: id, name: name, siteID: nil)
            }
            if case let .set(site) = patch.siteID {
                try Self.setManualStudio(db, libraryID: library, entryID: id, name: nil, siteID: site)
            }
            for tag in patch.tags { _ = try Self.assignTag(db, name: tag, entryID: id, libraryID: library) }
            if case let .set(image) = patch.poster {
                let digest = image.map { Data(SHA256.hash(data: $0)).base64EncodedString() }
                if let image {
                    try db.execute(sql: "INSERT OR REPLACE INTO entryPoster(entryID,image) VALUES (?,?)", arguments: [id, image])
                } else {
                    try db.execute(sql: "DELETE FROM entryPoster WHERE entryID = ?", arguments: [id])
                }
                try db.execute(sql: "UPDATE entry SET posterRevision = ? WHERE id = ?", arguments: [digest, id])
            }
            return try Self.apiEntry(db, library: library, id: id).metadata
        }
    }

    public func importedPoster(entryID: Int64) throws -> Data? {
        try database.read { try Data.fetchOne($0, sql: "SELECT image FROM entryPoster WHERE entryID = ?", arguments: [entryID]) }
    }
}
