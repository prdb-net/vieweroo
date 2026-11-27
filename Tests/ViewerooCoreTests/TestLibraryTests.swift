#if DEBUG
import Foundation
import Testing
@testable import ViewerooCore
@testable import ViewerooApp

@MainActor
@Test func testLibraryUsesRealFileHashesAndKeepsEditsAcrossLaunches() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let media = root.appending(path: "Media", directoryHint: .isDirectory)
    let fm = FileManager.default
    try fm.createDirectory(at: media, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let movie = media.appending(path: "Unrelated filename.mp4")
    try await writeColorMovie(to: movie)
    // Use a valid MP4 free-space box to reach the minimum size for OSHash.
    var bytes = try Data(contentsOf: movie)
    bytes.append(contentsOf: [0, 2, 0, 0] + Array("free".utf8))
    bytes.append(Data(repeating: 0, count: 131072 - 8))
    try bytes.write(to: movie)
    let hash = try #require(try OSHash.compute(url: movie))
    let titleID = UUID().uuidString, portraitID = UUID().uuidString
    let manifest = root.appending(path: "prdb.json")
    try Data("""
        [{"osHash":"\(hash)","filesize":\(bytes.count),"video":{"id":"\(titleID)","title":"Test Horizon",
        "alternativeTitle":"Distant Light","durationSeconds":61,"tags":["color-study"],
        "site":{"id":"s","title":"Test Studio","platformId":"p","platformKey":"onlyfans","platformTitle":"OnlyFans","accountHandle":"@test_archive"},"images":[],"actors":[{"id":"\(portraitID)","name":"Test Actor",
        "images":[{"imageType":3,"url":"https://portraits.vieweroo.invalid/\(portraitID).png"}]}]}}]
        """.utf8).write(to: manifest)
    let suite = "vieweroo.fixture-tests." + UUID().uuidString
    let prefs = try #require(UserDefaults(suiteName: suite))
    defer { prefs.removePersistentDomain(forName: suite) }
    let model = TestLibraryProfile.model(at: root, preferences: prefs)
    let client = model.client
    await #expect(throws: PRDBError.invalidKey) { try await client.validate(key: "wrong-key") }
    let key = TestLibraryAPI.key
    let searched = try await client.search("horizon", key: key)
    #expect(searched.map(\.id) == [titleID])
    #expect(searched.first?.alternativeTitle == "Distant Light")
    #expect(searched.first?.durationSeconds == 61)
    #expect(searched.first?.tagKeys == ["color-study"])
    let studio = try #require(try await client.searchStudios("studio", key: key).items.first)
    let actor = try #require(try await client.searchPerformers("actor", key: key).items.first)
    #expect(try await client.searchPerformers("absent", key: key).items.isEmpty)
    #expect(try await client.searchStudios("absent", key: key).items.isEmpty)
    #expect(try await client.searchTitles("", studioID: studio.id, key: key).items.map(\.id) == [titleID])
    #expect(try await client.searchTitles("", performerID: actor.id, key: key).items.map(\.id) == [titleID])
    #expect(try await client.searchTitles("horizon", studioID: studio.id, performerID: actor.id, key: key).total == 1)
    #expect(try await client.searchTitles("horizon", studioID: "another", performerID: actor.id, key: key).total == 0)
    #expect(try await client.searchTitles("", studioID: studio.id, performerID: "another", key: key).total == 0)
    #expect(try await client.searchTitles("", studioID: studio.id, page: 2, key: key).items.isEmpty)
    let expected = "https://onlyfans.com/test_archive"
    #expect(searched.first?.studio?.creator?.profileURL?.absoluteString == expected)
    #expect(try await client.studios(key: key).first?.creator?.profileURL?.absoluteString == expected)
    let detail = try await client.title(id: titleID, key: key)
    #expect(detail.studio?.name == "Test Studio")
    #expect(detail.alternativeTitle == "Distant Light" && detail.durationSeconds == 61 && detail.tagKeys == ["color-study"])
    let mismatches = try await client.identify([
        .init(ref: "hash", filename: movie.lastPathComponent, filesize: Int64(bytes.count), osHash: "0000000000000000"),
        .init(ref: "size", filename: movie.lastPathComponent, filesize: 1, osHash: hash),
    ], key: key)
    #expect(mismatches.count == 2 && mismatches.values.allSatisfy { $0.autoTitle == nil })
    model.start()
    try await until { model.entries.first?.match != nil && model.prdbTagDirectory != nil }
    let entry = try #require(model.entries.first)
    #expect(model.phase == .ready && entry.hash == hash && entry.match?.id == titleID)
    #expect(model.studioDirectory.studio(for: entry).creator?.profileURL?.absoluteString == expected)
    #expect(entry.match?.studio?.creator?.handle == "test_archive")
    #expect(entry.match?.performers.map(\.name) == ["Test Actor"])
    #expect(entry.match?.alternativeTitle == "Distant Light" && entry.match?.tagKeys == ["color-study"])
    #expect(model.prdbTagDirectory?.names["color-study"] == "Color Study")
    #expect(model.artworkURL(entry.match?.performers.first?.portraitURL) ==
            root.appending(path: "Portraits").appending(path: portraitID + ".png"))
    #expect(model.artworkURL(URL(string: "https://example.org/file.png")) == nil)
    let catalog = try #require(model.catalog)
    try catalog.setFavorite(entryID: entry.id, value: true)
    // Simulate an existing confirmed match written before v0.27.
    try catalog.confirmMatch(entryID: entry.id, title: PRDBTitle(id: titleID, title: "Test Horizon", studio: entry.match?.studio))
    model.work.cancel()
    let reopened = TestLibraryProfile.model(at: root, preferences: prefs)
    reopened.start()
    defer { reopened.work.cancel() }
    #expect(reopened.prdbTagDirectory?.names["color-study"] == "Color Study")
    try await until { reopened.entries.first?.match?.tagKeys == ["color-study"] }
    #expect(reopened.libraries.count == 1 && reopened.sources.count == 1)
    #expect(reopened.entries.count == 1 && reopened.entries.first?.id == entry.id && reopened.entries.first?.favorite == true)
    #expect(reopened.entries.first?.confirmed == true)
    #expect(reopened.entries.first?.match?.durationSeconds == 61)
    #expect(reopened.entries.first?.tags.isEmpty == true)
    #expect(CollectionFilters().includes(try #require(reopened.entries.first),
                                         directory: reopened.studioDirectory, term: "distant light"))
}
#endif
