import Foundation
import GRDB

package enum CatalogAPIChange: Sendable {
    case metadata(libraryID: Int64)
    case renamed(affectedEntries: [Int64: Set<Int64>])
}

struct CatalogResponse {
    let status: String
    let data: Data
    let change: CatalogAPIChange?

    init<T: Encodable>(_ value: T, status: String = "200 OK", change: CatalogAPIChange? = nil) throws {
        self.status = status
        data = try JSONEncoder().encode(value)
        self.change = change
    }

    init(error status: String, message: String) {
        self.status = status
        change = nil
        data = (try? JSONEncoder().encode(["error": message])) ?? Data()
    }
}

struct CatalogAPI {
    let catalog: Catalog

    func respond(method: String, target: String, body: Data) -> CatalogResponse {
        do { return try route(method: method, target: target, body: body) }
        catch EnrichmentError.missing { return .init(error: "404 Not Found", message: "Unknown catalog resource.") }
        catch EnrichmentError.conflict { return .init(error: "409 Conflict", message: "Metadata changed. Read the entry again.") }
        catch CatalogError.duplicateStudio { return .init(error: "409 Conflict", message: "Studio already exists.") }
        catch CatalogError.duplicateTag { return .init(error: "409 Conflict", message: "Tag already exists.") }
        catch let error as FileRenameError {
            let status = switch error {
            case .invalidName, .nameTooLong: "400 Bad Request"
            case .occupied, .unavailable, .scanning: "409 Conflict"
            case .recovery: "500 Internal Server Error"
            }
            return .init(error: status, message: error.localizedDescription)
        }
        catch let error as CatalogError { return .init(error: "400 Bad Request", message: error.localizedDescription) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSPropertyListReadCorruptError {
            return .init(error: "400 Bad Request", message: "Invalid JSON.")
        }
        catch { return .init(error: "500 Internal Server Error", message: "The catalog request could not be completed.") }
    }

    private struct Page: Encodable { let entries: [APIEntry]; let nextAfter: Int64? }
    private struct Tag: Encodable { let id: Int64; let name: String }
    private struct Studio: Encodable {
        let name: String
        let siteID: String?
        let isCustom: Bool
    }

    private func resourceName(_ body: Data) throws -> String {
        guard let fields = try JSONSerialization.jsonObject(with: body) as? [String: String],
              fields.count == 1, let name = fields["name"] else { throw CatalogError.invalidValue }
        return try EnrichmentPatch.clean(name, limit: 256)
    }

    private func route(method: String, target: String, body: Data) throws -> CatalogResponse {
        guard target.hasPrefix("/"), let url = URLComponents(string: target), url.host == nil, url.fragment == nil
        else { throw CatalogError.invalidValue }
        let parts = url.path.split(separator: "/")
        guard parts.starts(with: ["v1", "libraries"]) else { throw EnrichmentError.missing }
        if url.query != nil, !(parts.count == 4 && parts[3] == "entries" && method == "GET") { throw CatalogError.invalidValue }
        if parts.count == 2, method == "GET" { return try CatalogResponse(catalog.libraries()) }
        guard parts.count >= 4, let library = Int64(parts[2]), library > 0 else { throw EnrichmentError.missing }
        switch (method, parts[3], parts.count) {
        case ("GET", "entries", 4):
            var after: Int64 = 0, limit = 100
            var seen = Set<String>()
            for item in url.queryItems ?? [] {
                guard seen.insert(item.name).inserted, let value = item.value else { throw CatalogError.invalidValue }
                switch item.name {
                case "after":
                    guard let number = Int64(value), number >= 0 else { throw CatalogError.invalidValue }
                    after = number
                case "limit":
                    guard let number = Int(value), (1...200).contains(number) else { throw CatalogError.invalidValue }
                    limit = number
                default: throw CatalogError.invalidValue
                }
            }
            let rows = try catalog.apiEntries(library: library, after: after, limit: limit + 1)
            let entries = Array(rows.prefix(limit))
            return try CatalogResponse(Page(entries: entries, nextAfter: rows.count > limit ? entries.last?.metadata.id : nil))
        case ("GET", "studios", 4):
            let studios = try catalog.database.read { db in
                try Catalog.requireLibrary(db, library)
                return try Catalog.studioOptions(db, libraryID: library).map { Studio(name: $0.name, siteID: $0.siteID, isCustom: $0.isCustom) }
            }
            return try CatalogResponse(studios)
        case ("POST", "studios", 4):
            let name = try resourceName(body)
            try catalog.createStudio(libraryID: library, name: name)
            return try CatalogResponse(Studio(name: name, siteID: nil, isCustom: true), status: "201 Created", change: .metadata(libraryID: library))
        case ("GET", "tags", 4):
            let tags = try catalog.database.read { db in
                try Catalog.requireLibrary(db, library)
                return try Row.fetchAll(db, sql: """
                    SELECT id, name FROM tag WHERE libraryID = ? ORDER BY name COLLATE swiftLocalizedStandardCompare
                    """, arguments: [library]).map { Tag(id: $0["id"], name: $0["name"]) }
            }
            return try CatalogResponse(tags)
        case ("POST", "tags", 4):
            let name = try resourceName(body)
            let id = try catalog.database.write { db in
                try Catalog.requireLibrary(db, library)
                return try Catalog.createTag(db, libraryID: library, name: name)
            }
            return try CatalogResponse(Tag(id: id, name: name), status: "201 Created", change: .metadata(libraryID: library))
        case ("GET", "entries", 5), ("PATCH", "entries", 5):
            guard let id = Int64(parts[4]), id > 0 else { throw EnrichmentError.missing }
            if method == "GET" { return try CatalogResponse(catalog.apiEntry(library: library, id: id)) }
            let updated = try catalog.apply(EnrichmentPatch(body), library: library, id: id)
            return try CatalogResponse(updated, change: .metadata(libraryID: library))
        case ("POST", "entries", 6) where parts[5] == "rename":
            guard let id = Int64(parts[4]), id > 0 else { throw EnrichmentError.missing }
            guard let fields = try JSONSerialization.jsonObject(with: body) as? [String: String],
                  fields.count == 2, let revision = fields["revision"], !revision.isEmpty,
                  let basename = fields["basename"] else { throw CatalogError.invalidValue }
            let renamed = try catalog.renameFile(entryID: id, libraryID: library, revision: revision, basename: basename)
            let change: CatalogAPIChange? = renamed.affectedEntries.isEmpty ? nil : .renamed(affectedEntries: renamed.affectedEntries)
            return try CatalogResponse(APIEntry(renamed.entry), change: change)
        default: throw EnrichmentError.missing
        }
    }
}
