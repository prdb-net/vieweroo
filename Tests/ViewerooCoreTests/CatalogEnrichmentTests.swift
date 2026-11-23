import Foundation
import GRDB
import Testing
@testable import ViewerooCore

@Test func enrichmentsSurviveMigrationAndRescanAndRespectConcurrentLibraryEdits() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: "catalog.sqlite").path
    let movie = root.appending(path: "Spring.mov")
    try Data(repeating: 1, count: 256).write(to: movie)
    do {
        let old = try DatabaseQueue(path: path)
        try Catalog.migrator.migrate(old, upTo: "studio-covers-v15")
        try old.write { db in
            try db.execute(sql: """
                INSERT INTO library(id,name) VALUES (1,'First'),(2,'Second');
                INSERT INTO entry(id,libraryID,path,fileSize,modified) VALUES (1,1,?,256,0),(2,2,?,256,0)
                """, arguments: [movie.path, movie.path])
        }
    }
    let catalog = try Catalog(path: path)
    let source = try catalog.addSource(libraryID: 1, url: root)
    let scanner = CatalogScanner(catalog: catalog)
    try scanner.scan(source: source)
    try catalog.confirmMatch(entryID: 1, title: .init(id: "p1", title: "Original"))
    let api = CatalogAPI(catalog: catalog)
    let route = "/v1/libraries/1/entries/1"
    func call(_ method: String, _ route: String, _ json: [String: Any] = [:]) throws -> CatalogResponse {
        api.respond(method: method, target: route, body: try JSONSerialization.data(withJSONObject: json))
    }
    func revision() throws -> String { try #require(try catalog.apiEntry(library: 1, id: 1).metadata.revision) }
    let initial = try revision()
    try catalog.setTags(entryID: 1, tags: ["Original"])
    #expect(try call("PATCH", route, ["revision": initial, "title": "Too late"]).status == "409 Conflict")
    #expect(try call("PATCH", "/v1/libraries/2/entries/1", ["revision": revision(), "title": "Wrong"]).status == "404 Not Found")
    let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
    let patch: [String: Any] = ["revision": try revision(), "title": "Local", "description": "Imported notes",
                                "studio": "Meadow", "poster": png, "addTags": ["New", "new"]]
    #expect(try call("PATCH", route, patch).status == "200 OK")
    try scanner.scan(source: source)
    let reopened = try Catalog(path: path)
    let saved = try #require(try reopened.entry(1))
    #expect(saved.title == "Local" && saved.match?.id == "p1" && saved.filename == "Spring.mov")
    #expect(saved.localDescription == "Imported notes" && saved.studio == "Meadow")
    #expect(Set(saved.tags) == ["Original", "New"])
    #expect(try reopened.importedPoster(entryID: 1)?.isEmpty == false)
    #expect(try reopened.entry(2)?.localTitle == nil)
    #expect(try call("POST", "/v1/libraries/1/studios", ["name": "Other"]).status == "201 Created")
    #expect(try call("POST", "/v1/libraries/1/studios", ["name": "other"]).status == "409 Conflict")
    let options = try call("GET", "/v1/libraries/2/studios")
    #expect(String(decoding: options.data, as: UTF8.self) == "[]")
    for badField: [String: Any] in [["siteID": "unknown"], ["poster": "invalid"], ["addTags": [5]], ["typo": "x"]] {
        let json = try ["revision": revision(), "title": "Rollback"].merging(badField) { _, new in new }
        #expect(try call("PATCH", route, json).status == "400 Bad Request")
        #expect(try catalog.entry(1)?.title == "Local")
    }
    try catalog.saveStudios([.init(id: "p2", name: "Shared Studio")])
    #expect(try call("PATCH", route, ["revision": revision(), "siteID": "p2"]).status == "200 OK")
    #expect(try catalog.entry(1)?.manualSiteID == "p2")
    let null = NSNull()
    #expect(try call("PATCH", route, ["revision": revision(), "title": null, "poster": null, "studio": null]).status == "200 OK")
    #expect(try catalog.entry(1)?.title == "Original" && catalog.entry(1)?.localDescription == "Imported notes")
    #expect(try catalog.importedPoster(entryID: 1) == nil && catalog.entry(1)?.manualStudio == nil)

    try Data([1]).write(to: root.appending(path: "Another.mov"))
    try scanner.scan(source: source)
    let page = try call("GET", "/v1/libraries/1/entries?limit=1")
    let result = try #require(JSONSerialization.jsonObject(with: page.data) as? [String: Any])
    let cursor = try #require(result["nextAfter"] as? Int64)
    let last = try call("GET", "/v1/libraries/1/entries?limit=1&after=\(cursor)")
    let tail = try #require(JSONSerialization.jsonObject(with: last.data) as? [String: Any])
    #expect(tail["nextAfter"] == nil && (tail["entries"] as? [[String: Any]])?.count == 1)
    #expect(try call("GET", "/v1/libraries/1/entries?limit=0").status == "400 Bad Request")
}

@Test func catalogReadsReturnStoredFileIdentityBeforeHashingAndWhileOffline() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let movie = folder.appending(path: "Sample.mov")
    // PRDB's wraparound vector produces a hash with both leading zeros and hex letters.
    var bytes = Data(repeating: 0, count: 131072)
    bytes.replaceSubrange(0..<8, with: Data(repeating: 0xff, count: 8))
    try bytes.write(to: movie)

    let catalog = try Catalog(path: ":memory:")
    let library = try catalog.createLibrary(name: "Sample library")
    let source = try catalog.addSource(libraryID: library.id, url: folder)
    try CatalogScanner(catalog: catalog).scan(source: source)
    let entry = try #require(try catalog.entries(libraryID: library.id).first)
    let api = CatalogAPI(catalog: catalog)
    let list = "/v1/libraries/\(library.id)/entries"
    let detail = list + "/\(entry.id)"

    func checkReads(expectedHash: String?) throws -> String {
        func get(_ route: String) throws -> [String: Any] {
            let response = api.respond(method: "GET", target: route, body: Data())
            #expect(response.status == "200 OK")
            return try #require(JSONSerialization.jsonObject(with: response.data) as? [String: Any])
        }
        let page = try get(list)
        let entries = try #require(page["entries"] as? [[String: Any]])
        let single = try get(detail)
        #expect(entries.count == 1)
        for result in [try #require(entries.first), single] {
            #expect(result["id"] as? Int64 == entry.id)
            #expect(result["fileSize"] as? Int64 == 131072)
            #expect(result.keys.contains("osHash") == (expectedHash != nil))
            #expect(result["osHash"] as? String == expectedHash)
        }
        return try #require(single["revision"] as? String)
    }

    let revision = try checkReads(expectedHash: nil)
    let hash = try #require(try OSHash.compute(url: movie))
    try catalog.setHash(entryID: entry.id, hash: hash, fileSize: entry.fileSize, modified: entry.modified)
    try FileManager.default.removeItem(at: folder)
    _ = try catalog.checkSources(libraryID: library.id)
    #expect(try catalog.entry(entry.id)?.availability == .offline)
    #expect(try checkReads(expectedHash: "000000000001ffff") == revision)

    for field in ["fileSize", "osHash"] {
        let body = try JSONSerialization.data(withJSONObject: ["revision": revision, field: NSNull()] as [String: Any])
        #expect(api.respond(method: "PATCH", target: detail, body: body).status == "400 Bad Request")
    }
}
