import Foundation
import Testing
@testable import ViewerooCore

@Test func bulkEditsUndoOnlyChangedValuesAndMemberships() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["First", "Second", "Third"] { try Data().write(to: folder.appending(path: name + ".mp4")) }
    let catalog = try Catalog(path: ":memory:")
    let library = try catalog.createLibrary(name: "Movies")
    let source = try catalog.addSource(libraryID: library.id, url: folder)
    try CatalogScanner(catalog: catalog).scan(source: source)
    let ids = try catalog.entries(libraryID: library.id).map(\.id)
    try #require(ids.count == 3)
    func apply(_ edit: BulkVideoEdit, to selected: [Int64]? = nil) throws -> BulkEditReceipt {
        try catalog.editVideos(in: library.id, entryIDs: selected ?? ids, edit: edit)
    }

    try catalog.setFavorite(entryID: ids[1], value: true)
    try catalog.setRating(entryID: ids[0], value: -1)
    try catalog.setRating(entryID: ids[1], value: 1)
    let likes = try apply(.rating(1))
    #expect(likes.changedCount == 2)
    #expect(try catalog.entries(libraryID: library.id).allSatisfy { $0.rating == 1 })
    let favorites = try apply(.favorite(true))
    #expect(favorites.changedCount == 2)
    let removed = try apply(.favorite(false))
    #expect(try catalog.entries(libraryID: library.id).allSatisfy { !$0.favorite && $0.rating == 1 })
    try catalog.undoVideoEdit(removed)
    #expect(try catalog.entries(libraryID: library.id).allSatisfy(\.favorite))
    try catalog.undoVideoEdit(favorites)
    let cleared = try apply(.rating(0))
    #expect(cleared.changedCount == 3)
    #expect(try catalog.entries(libraryID: library.id).map(\.rating) == [0, 0, 0])
    try catalog.undoVideoEdit(cleared)
    try catalog.undoVideoEdit(likes)
    let restored = try catalog.entries(libraryID: library.id)
    #expect(restored.map(\.favorite) == [false, true, false])
    #expect(restored.map(\.rating) == [-1, 1, 0])

    try catalog.setTags(entryID: ids[0], tags: ["Été", "Keep"])
    let tags = try apply(.addTags([" été ", "Weekend", "weekend"]), to: Array(ids.prefix(2)))
    #expect(tags.changedCount == 2)
    #expect(try Set(catalog.entry(ids[0])!.tags) == ["Été", "Keep", "Weekend"])
    #expect(try Set(catalog.entry(ids[1])!.tags) == ["été", "Weekend"])
    #expect(try catalog.entry(ids[2])!.tags.isEmpty)
    #expect(try apply(.addTags(["été"]), to: [ids[0]]).changedCount == 0)
    try catalog.undoVideoEdit(tags)
    #expect(try Set(catalog.entry(ids[0])!.tags) == ["Été", "Keep"])
    #expect(try catalog.entry(ids[1])!.tags.isEmpty)

    let list = try catalog.createPlaylist(libraryID: library.id, name: "Weekend")
    try catalog.addToPlaylist(list.id, entryID: ids[1])
    let playlist = try apply(.addToPlaylist(list.id), to: ids.reversed())
    #expect(playlist.changedCount == 2)
    #expect(try catalog.playlistEntryIDs(list.id) == [ids[1], ids[2], ids[0]])
    #expect(try apply(.addToPlaylist(list.id)).changedCount == 0)
    try catalog.undoVideoEdit(playlist)
    #expect(try catalog.playlistEntryIDs(list.id) == [ids[1]])

    let other = try catalog.createLibrary(name: "Second library")
    let otherSource = try catalog.addSource(libraryID: other.id, url: folder)
    try CatalogScanner(catalog: catalog).scan(source: otherSource)
    let foreign = try #require(catalog.entries(libraryID: other.id).first)
    #expect(throws: CatalogError.self) { try apply(.favorite(true), to: [ids[0], foreign.id]) }
    #expect(try catalog.entry(ids[0])?.favorite == false)
    #expect(try catalog.entry(foreign.id)?.favorite == false)
}
