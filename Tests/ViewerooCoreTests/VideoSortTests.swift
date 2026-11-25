import Foundation
import Testing
@testable import ViewerooApp
@testable import ViewerooCore

@MainActor
@Test func videoCollectionsSortByTitleAdditionPlaybackAndDuration() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let catalog = try Catalog(path: ":memory:")
    let library = try catalog.createLibrary(name: "Archive")
    let source = try catalog.addSource(libraryID: library.id, url: folder)
    // Scanned one by one, so the order of addition differs from every other order.
    for name in ["b 10", "A", "b 2"] {
        try Data().write(to: folder.appending(path: name + ".mp4"))
        try CatalogScanner(catalog: catalog).scan(source: source)
    }
    func entry(_ title: String) throws -> CatalogEntry {
        try #require(catalog.entries(libraryID: library.id).first { $0.title == title })
    }
    let info = VideoInfo(width: 1280, height: 720, codec: "H.264", container: nil, frameRate: 24)
    try await catalog.storeVideoInfo(info, duration: 900, for: try entry("b 2"))
    try await catalog.storeVideoInfo(info, duration: 300, for: try entry("A"))
    let session = try catalog.beginSession(entryID: try entry("b 10").id)
    try catalog.recordInterval(sessionID: session, start: 0, end: 15)

    let suite = "vieweroo-sort-" + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let model = LibraryModel(preferences: preferences, directory: folder, cache: PreviewCache(root: folder))
    model.entries = try await catalog.snapshot(libraryID: library.id).entries
    #expect(model.entries.first { $0.title == "b 10" }?.lastPlayed != nil)
    func titles(_ sort: VideoSort) -> [String] { model.ordered(model.entries, by: sort).map(\.title) }

    #expect(titles(.title) == ["A", "b 2", "b 10"], "Numbers sort by value and case is ignored")
    #expect(titles(.added) == ["b 2", "A", "b 10"])
    #expect(titles(.played) == ["b 10", "A", "b 2"], "Unplayed videos follow by title")
    #expect(titles(.duration) == ["b 2", "A", "b 10"], "A video without a duration comes last")
    #expect(titles(.collection) == model.entries.map(\.title))

    // The chosen order is kept for the next launch, per kind of collection.
    // Title positions are computed per entry. A second library with the same titles gets its own.
    let twin = try catalog.createLibrary(name: "Twin")
    try CatalogScanner(catalog: catalog).scan(source: try catalog.addSource(libraryID: twin.id, url: folder))
    model.entries = try await catalog.snapshot(libraryID: twin.id).entries
    #expect(model.entries.map(\.title) != ["A", "b 2", "b 10"], "The twin lists its entries in path order")
    #expect(titles(.title) == ["A", "b 2", "b 10"])
    #expect(Shelf.all.sortOptions.first == .title && Shelf.frequent.sortOptions.first == .collection)
    #expect(Set(Shelf.frequent.sortOptions) == Set(VideoSort.allCases))
    #expect(Shelf.playlist(1).sortOptions.first == .collection && Shelf.studios.sortOptions.isEmpty)
    model.videoSorts["library"] = VideoSort.added.rawValue
    let relaunched = LibraryModel(preferences: preferences, directory: folder, cache: PreviewCache(root: folder))
    #expect(relaunched.videoSorts == ["library": "added"])
}
