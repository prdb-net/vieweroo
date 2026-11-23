import AVFoundation
import GRDB
import Testing
@testable import ViewerooApp
@testable import ViewerooCore

@Test func legacyTagsBecomeLibraryCollectionsAndRetainMembershipsAndCovers() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        let legacy = try DatabaseQueue(path: url.path)
        try Catalog.migrator.migrate(legacy, upTo: "studio-favorites-v12")
        try await legacy.write { db in
            try db.execute(sql: """
                INSERT INTO library(id,name) VALUES (1,'First'),(2,'Second');
                INSERT INTO entry(id,libraryID,path,fileSize,modified,resume) VALUES
                    (1,1,'a.mp4',100,0,10),(2,1,'b.mp4',100,0,0),(3,2,'a.mp4',100,0,5);
                INSERT INTO entryTag(entryID,name) VALUES (2,'Été'),(1,'été'),(1,'Été'),(3,'Été');
                """)
        }
    }
    let catalog = try Catalog(path: url.path)
    let first = try #require(try await catalog.snapshot(libraryID: 1).tags.first)
    let other = try #require(try await catalog.snapshot(libraryID: 2).tags.first)
    #expect(first.memberIDs == [2, 1] && first.id != other.id)
    #expect(other.memberIDs == [3])
    #expect(try catalog.entry(1)?.tags == ["Été"])
    #expect(throws: CatalogError.self) { try catalog.createTag(libraryID: 1, name: " été ") }
    try catalog.createTag(libraryID: 1, name: "Empty")
    #expect(throws: CatalogError.self) { try catalog.renameTag(first.id, to: "empty") }
    let image = Data([1, 2, 3])
    #expect(throws: CatalogError.self) { try catalog.saveTagCover(first.id, entryID: 3, time: 1, image: image, custom: true) }
    try catalog.saveTagCover(first.id, entryID: 2, time: 1.5, image: image, custom: true)
    try catalog.renameTag(first.id, to: "Roadtrip")
    try catalog.setTags(entryID: 2, tags: ["Roadtrip", "Blue"])
    let reopened = try Catalog(path: url.path)
    #expect(try await reopened.tagCoverImage(first.id) == image)
    #expect(try reopened.entry(2)?.availability == .missing)
    #expect(try reopened.entry(1)?.resume == 10 && reopened.entry(1)?.playCount == 0)
    #expect(try !catalog.saveTagCover(first.id, entryID: 1, time: 3, image: Data([4]), custom: false))

    let receipt = try catalog.editVideos(in: 1, entryIDs: [2], edit: .removeTag(first.id))
    #expect(receipt.changedCount == 1)
    #expect(try await catalog.tagCoverImage(first.id) == nil)
    try catalog.saveTagCover(first.id, entryID: 1, time: 3, image: Data([4]), custom: false)
    try catalog.undoVideoEdit(receipt)
    let restored = try #require(try await catalog.snapshot(libraryID: 1).tags.first { $0.id == first.id })
    #expect(restored.hasCustomCover && restored.coverTime == 1.5 && restored.memberIDs == [2, 1])
    #expect(try await catalog.tagCoverImage(first.id) == image)
    try catalog.resetTagCover(first.id)
    #expect(try await catalog.tagCoverImage(first.id) == nil)
    let all = try catalog.editVideos(in: 1, entryIDs: [1, 2], edit: .removeTag(first.id))
    #expect(try await catalog.snapshot(libraryID: 1).tags.first { $0.id == first.id }?.memberIDs == [])
    try catalog.deleteTag(first.id)
    try catalog.undoVideoEdit(all)
    #expect(try await !catalog.snapshot(libraryID: 1).tags.contains { $0.id == first.id })
    #expect(try catalog.entry(1)?.tags == [] && catalog.entry(2)?.tags == ["Blue"])
    #expect(try catalog.entry(3)?.tags == ["Été"])
}

@Test func coverPickerStepsBetweenExactSamplesAndAutomaticCoversUseAvailableStills() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let movie = root.appendingPathComponent("Colors.mp4")
    try await writeColorMovie(to: movie)
    let reader = try await TagFrameReader(url: movie)
    let first = try await reader.frame(at: CMTime(seconds: 0.57, preferredTimescale: 600))
    let next = try await reader.frame(at: first.time, step: 1)
    let previous = try await reader.frame(at: next.time, step: -1)
    #expect(first.time.seconds == 0.5 && next.time.seconds == 0.6)
    #expect(previous.time == first.time && previous.image == first.image && next.image != first.image)
    let last = try await reader.frame(at: CMTime(seconds: reader.duration, preferredTimescale: 600))
    #expect(try await reader.frame(at: last.time, step: 1).time == last.time)

    let catalog = try Catalog(path: ":memory:")
    let library = try catalog.createLibrary(name: "Local")
    try Data().write(to: root.appendingPathComponent("Absent-preview.mp4"))
    let source = try catalog.addSource(libraryID: library.id, url: root)
    try CatalogScanner(catalog: catalog).scan(source: source)
    let entries = try catalog.entries(libraryID: library.id)
    let entry = try #require(entries.first { $0.url == movie })
    for item in entries { try catalog.setTags(entryID: item.id, tags: ["Color"]) }
    let tags = try await catalog.snapshot(libraryID: library.id).tags
    let tag = try #require(tags.first)
    let cache = PreviewCache(root: root.appendingPathComponent("Previews"))
    let directory = cache.directory(for: entry)
    try await cache.prepare(media: movie, directory: directory)
    let covers = AutomaticTagCovers(tags: tags, entries: entries, cache: cache)
    #expect(try await covers.prepare(in: catalog))
    #expect(try await catalog.tagCoverImage(tag.id) == Data(contentsOf: PreviewCache.posterURL(in: directory)))
    try catalog.saveTagCover(tag.id, entryID: entry.id, time: next.time.seconds, image: next.image, custom: true)
    #expect(try await !covers.prepare(in: catalog))
    try FileManager.default.removeItem(at: movie)
    try CatalogScanner(catalog: catalog).scan(source: source)
    #expect(try await catalog.tagCoverImage(tag.id) == next.image)
    #expect(try catalog.entry(entry.id)?.resume == 0 && catalog.entry(entry.id)?.playCount == 0)
}
