import Foundation
import Testing
@testable import ViewerooCore

@Test func writerBeginsSessionsOnItsQueueAndKeepsThemAcrossHistoryRemoval() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let media = base.appending(path: "Media")
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try Data([1]).write(to: media.appending(path: "Queued.mp4"))
    let catalog = try Catalog(path: base.appending(path: "Catalog.sqlite").path)
    let library = try catalog.createLibrary(name: "Library")
    try CatalogScanner(catalog: catalog).scan(source: try catalog.addSource(libraryID: library.id, url: media))
    let entry = try #require(catalog.entries(libraryID: library.id).first)
    #expect(entry.duration == nil)

    let writer = PlaybackHistoryWriter(catalog: catalog, entryID: entry.id)
    let token = writer.begin(duration: 90, of: entry)
    #expect(token < 0, "A local token must never collide with a catalog session")
    writer.append(session: token, start: 0, end: 12) { #expect($0 == nil) }
    writer.flush()
    var saved = try #require(try catalog.entry(entry.id))
    #expect(saved.playCount == 1 && saved.watchTime == 12 && saved.duration == 90)

    // Watch History is cleared during playback. The same token continues in one new session.
    _ = try catalog.editVideos(in: library.id, entryIDs: [entry.id], edit: .removeHistory)
    writer.append(session: token, start: 12, end: 20) { #expect($0 == nil) }
    writer.append(session: token, start: 20, end: 25) { #expect($0 == nil) }
    writer.flush()
    saved = try #require(try catalog.entry(entry.id))
    #expect(saved.playCount == 1 && saved.watchTime == 13)

    // A second playback of the same item is a session of its own.
    let next = writer.begin()
    #expect(next != token)
    writer.append(session: next, start: 0, end: 15) { #expect($0 == nil) }
    writer.flush()
    #expect(try catalog.entry(entry.id)?.playCount == 2)
}
