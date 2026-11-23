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
    func revision() throws -> String { try #require(try catalog.apiEntry(library: 1, id: 1).revision) }
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
