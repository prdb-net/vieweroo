import Foundation
import GRDB
import Testing
@testable import ViewerooApp
@testable import ViewerooCore

@Test func existingPlaylistsChooseAndRetainCoversFromTheirOwnMembers() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("Catalog.sqlite").path
    do {
        let old = try DatabaseQueue(path: path)
        try Catalog.migrator.migrate(old, upTo: "library-tags-v13")
        try await old.write { db in
            try db.execute(sql: """
                INSERT INTO library(id,name) VALUES (1,'Local'),(2,'Other');
                INSERT INTO entry(id,libraryID,path,fileSize,modified) VALUES
                    (1,1,'one.mp4',100,0),(2,1,'two.mp4',200,0),(3,2,'other.mp4',100,0);
                INSERT INTO playlist(id,libraryID,name,lastOpenedOrder) VALUES (1,1,'Weekend',7);
                INSERT INTO playlistItem(libraryID,playlistID,entryID,position) VALUES (1,1,1,1),(1,1,2,0);
                INSERT INTO tag(id,libraryID,name) VALUES (1,1,'Weekend');
                INSERT INTO tagItem(libraryID,tagID,entryID) VALUES (1,1,1);
                """)
        }
    }

    let catalog = try Catalog(path: path)
    let playlist = try #require(try catalog.playlists(libraryID: 1).first)
    #expect(playlist.cover == nil && playlist.orderedMemberIDs == [2, 1] && playlist.lastOpenedOrder == 7)
    let cache = PreviewCache(root: folder.appendingPathComponent("Previews"))
    let entries = try catalog.entries(libraryID: 1)
    let tags = try await catalog.snapshot(libraryID: 1).tags
    let coverID = CoverCollectionID.playlist(playlist.id)
    let readerURL = folder.appendingPathComponent("Colors.mp4")
    try await writeColorMovie(to: readerURL)
    for entry in entries {
        try await cache.prepare(media: readerURL, directory: cache.directory(for: entry))
    }
    func prepare() async throws -> Bool {
        let covers = AutomaticCollectionCovers(tags: tags, playlists: try catalog.playlists(libraryID: 1),
                                              entries: entries, cache: cache)
        return try await covers.prepare(in: catalog)
    }

    #expect(try await prepare())
    #expect(try catalog.playlists(libraryID: 1).first?.cover?.entryID == 2)
    let tagImage = try #require(try await catalog.coverImage(.tag(1)))
    let frame = try await TagFrameReader(url: readerURL).frame(at: .zero)
    #expect(throws: CatalogError.self) {
        try catalog.saveCover(coverID, entryID: 3, time: 0, image: frame.image, custom: true)
    }
    try catalog.saveCover(coverID, entryID: 1, time: frame.time.seconds, image: frame.image, custom: true)
    try catalog.renamePlaylist(1, to: "Evening")
    try catalog.reorderPlaylist(1, entryIDs: [1, 2])
    let reopened = try Catalog(path: path)
    let saved = try #require(try reopened.playlists(libraryID: 1).first?.cover)
    #expect(saved.isCustom && saved.time == frame.time.seconds && saved.entryID == 1)
    #expect(try await reopened.coverImage(coverID) == frame.image)
    #expect(try !catalog.saveCover(coverID, entryID: 2, time: 0, image: tagImage, custom: false))
    try catalog.resetCover(coverID)
    #expect(try await prepare())
    #expect(try catalog.playlists(libraryID: 1).first?.cover?.entryID == 1)
    try catalog.removeFromPlaylist(1, entryID: 1)
    #expect(try await catalog.coverImage(coverID) == nil)
    #expect(try await prepare())
    #expect(try catalog.playlists(libraryID: 1).first?.cover?.entryID == 2)
    try catalog.removeFromPlaylist(1, entryID: 2)
    #expect(try await !prepare())
    #expect(try await catalog.coverImage(coverID) == nil)
    #expect(try await catalog.coverImage(.tag(1)) == tagImage)
}

@Test func playlistBatchRemovalRestoresOrderAndCoverAcrossLaterAppends() async throws {
    let catalog = try Catalog(path: ":memory:")
    let library = try catalog.createLibrary(name: "Weekend")
    let playlist = try catalog.createPlaylist(libraryID: library.id, name: "Cuts").id
    let otherPlaylist = try catalog.createPlaylist(libraryID: library.id, name: "Copies").id
    try await catalog.database.write { db in
        for id in 1...5 {
            try db.execute(sql: "INSERT INTO entry(id,libraryID,path,fileSize,modified) VALUES (?,?,?,100,0)",
                           arguments: [id, library.id, "clip-\(id).mp4"])
        }
    }
    for id: Int64 in [3, 2, 1, 4] { try catalog.addToPlaylist(playlist, entryID: id) }
    try catalog.addToPlaylist(otherPlaylist, entryID: 3)
    let frame = Data([1, 2])
    try catalog.saveCover(.playlist(playlist), entryID: 3, time: 1, image: frame, custom: true)
    let removed = try catalog.editVideos(in: library.id, entryIDs: [4, 3, 1, 3, 5], edit: .removeFromPlaylist(playlist))
    #expect(removed.changedCount == 3)
    #expect(try catalog.playlistEntryIDs(playlist) == [2])
    #expect(try catalog.playlistEntryIDs(otherPlaylist) == [3])
    #expect(try await catalog.coverImage(.playlist(playlist)) == nil)
    try catalog.saveCover(.playlist(playlist), entryID: 2, time: 0, image: Data([3]), custom: false)
    try catalog.addToPlaylist(playlist, entryID: 5)
    try catalog.undoVideoEdit(removed)
    #expect(try catalog.playlistEntryIDs(playlist) == [3, 2, 1, 4, 5])
    #expect(try await catalog.coverImage(.playlist(playlist)) == frame)
    let foreign = try catalog.createLibrary(name: "Other")
    let foreignPlaylist = try catalog.createPlaylist(libraryID: foreign.id, name: "Solo").id
    #expect(throws: CatalogError.self) {
        try catalog.deletePlaylists(in: library.id, ids: [playlist, foreignPlaylist])
    }
    #expect(try catalog.playlistEntryIDs(playlist) == [3, 2, 1, 4, 5])
    try catalog.deletePlaylists(in: library.id, ids: [playlist, otherPlaylist])
    #expect(try catalog.playlists(libraryID: library.id).isEmpty)
    #expect(try catalog.entries(libraryID: library.id).count == 5)
    #expect(try catalog.playlists(libraryID: foreign.id).count == 1)
}
