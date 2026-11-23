import Foundation
import GRDB
import Testing
@testable import ViewerooCore

@Test func studioFramesFollowTheirLibraryAndResolvedStudio() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("Catalog.sqlite").path
    do {
        let legacy = try DatabaseQueue(path: path)
        try Catalog.migrator.migrate(legacy, upTo: "playlist-covers-v14")
        try await legacy.write { db in
            try db.execute(sql: """
                INSERT INTO library(id,name) VALUES (1,'First'),(2,'Second');
                INSERT INTO entry(id,libraryID,path,fileSize,modified) VALUES
                    (1,1,'one.mp4',100,0),(2,1,'two.mp4',100,0),(3,2,'one.mp4',100,0);
                """)
        }
    }
    let catalog = try Catalog(path: path)
    func key(_ name: String, library: Int64 = 1, siteID: String? = nil) -> CoverCollectionID {
        .studio(libraryID: library, studioID: StudioOption(name: name, isCustom: false, siteID: siteID).id)
    }
    let unknown = key("Unknown Studio")
    let first = key("Local")
    let second = key("Local", library: 2)
    let still = Data([1, 2, 3])
    let other = Data([4, 5, 6])
    try catalog.saveCover(unknown, entryID: 1, time: 1, image: still, custom: true)
    try catalog.setManualStudio(entryID: 1, name: "Local")
    try catalog.setManualStudio(entryID: 3, name: "Local")
    #expect(try await catalog.coverImage(unknown) == nil)
    #expect(throws: CatalogError.self) { try catalog.saveCover(first, entryID: 2, time: 0, image: still, custom: true) }
    #expect(throws: CatalogError.self) { try catalog.saveCover(first, entryID: 3, time: 0, image: still, custom: true) }
    try catalog.saveCover(first, entryID: 1, time: 1.25, image: still, custom: true)
    try catalog.saveCover(second, entryID: 3, time: 2, image: other, custom: true)
    try catalog.renameCustomStudio(libraryID: 1, name: "Local", to: "Night")
    let reopened = try Catalog(path: path)
    #expect(try reopened.entry(1)?.availability == .missing)
    #expect(try await reopened.coverImage(key("Night")) == still)
    #expect(try await reopened.coverImage(first) == nil)
    #expect(try await reopened.coverImage(second) == other)
    try catalog.deleteCustomStudio(libraryID: 2, name: "Local")
    #expect(try await reopened.coverImage(second) == nil)

    try catalog.saveStudios([.init(id: "A", name: "Night")])
    let siteA = key("Night", siteID: "A")
    let siteB = key("Night", siteID: "B")
    #expect(try await reopened.coverImage(siteA) == still)
    try catalog.setManualStudio(entryID: 1, name: "Night", siteID: "A")
    try catalog.saveStudios([.init(id: "B", name: "Night")])
    try catalog.setManualStudio(entryID: 2, name: "Night", siteID: "B")
    try catalog.saveCover(siteB, entryID: 2, time: 0, image: other, custom: true)
    let snapshot = try await reopened.snapshot(libraryID: 1)
    #expect(snapshot.studioCovers["site:A"]?.time == 1.25 && snapshot.studioCovers["site:A"]?.entryID == 1)
    #expect(snapshot.studioCovers["site:B"]?.entryID == 2)
    try catalog.resetCover(siteB)
    #expect(try await reopened.coverImage(siteA) == still)
    #expect(try await reopened.coverImage(siteB) == nil)
    try catalog.setManualStudio(entryID: 1, name: "Night", siteID: "B")
    #expect(try await reopened.coverImage(siteA) == nil)
    #expect(try await reopened.snapshot(libraryID: 1).studioCovers.isEmpty)
}

@Test func rescanRetainsStudioFrameOnlyWhileItsSourceBelongsToTheStudio() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let movie = folder.appendingPathComponent("Colors.mp4")
    try await writeColorMovie(to: movie)
    let catalog = try Catalog(path: ":memory:")
    let library = try catalog.createLibrary(name: "Library")
    let source = try catalog.addSource(libraryID: library.id, url: folder)
    let scanner = CatalogScanner(catalog: catalog)
    try scanner.scan(source: source)
    let entry = try #require(try catalog.entries(libraryID: library.id).first)
    let studio = StudioOption(name: "Colors", isCustom: false)
    let cover = CoverCollectionID.studio(libraryID: library.id, studioID: studio.id)
    try catalog.setDetectedStudio(entryID: entry.id, name: studio.name, fileSize: entry.fileSize, modified: entry.modified)
    let frame = try await TagFrameReader(url: movie).frame(at: .zero)
    try catalog.saveCover(cover, entryID: entry.id, time: 0, image: frame.image, custom: true)
    try catalog.setManualStudio(entryID: entry.id, name: studio.name)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: entry.modified + 60)], ofItemAtPath: movie.path)
    try scanner.scan(source: source)
    #expect(try await catalog.coverImage(cover) == frame.image)

    let changed = try #require(try catalog.entry(entry.id))
    try catalog.setDetectedStudio(entryID: entry.id, name: studio.name, fileSize: changed.fileSize, modified: changed.modified)
    try catalog.setManualStudio(entryID: entry.id, name: nil)
    #expect(try await catalog.coverImage(cover) == frame.image)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: changed.modified + 60)], ofItemAtPath: movie.path)
    try scanner.scan(source: source)
    #expect(try catalog.entry(entry.id)?.studio == nil)
    #expect(try await catalog.coverImage(cover) == nil)
}
