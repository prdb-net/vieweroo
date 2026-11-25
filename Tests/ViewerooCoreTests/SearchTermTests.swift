import Foundation
import Testing
@testable import ViewerooCore

@Test func releaseNamesBecomeTitleWords() {
    #expect(SearchTerm.clean("Paper.Lantern.24.01.05.Lanterns.at.Dusk.XXX.1080p.MP4-GRP", studio: "Paper Lantern")
            == "Lanterns at Dusk GRP")
    #expect(SearchTerm.clean("PaperLantern_2024-01-05_Copper_Kite_[2160p]", studio: "Paper Lantern") == "Copper Kite")
    #expect(SearchTerm.clean("Low Water (720p) x265") == "Low Water")
    #expect(SearchTerm.clean("Half-Light Harbor 60fps") == "Half-Light Harbor")
    // A plain title stays as it is, and a name of nothing but labels is searched unchanged.
    #expect(SearchTerm.clean("Charlie") == "Charlie")
    #expect(SearchTerm.clean("1080p.x264") == "1080p.x264")
    // The studio stays when nothing else would be left to search for.
    #expect(SearchTerm.clean("Tideglass", studio: "Tideglass") == "Tideglass")
    #expect(SearchTerm.clean("Scene 24 of 30") == "Scene 24 of 30")
}

@Test func unmatchedVideosCanBeQueuedAgain() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let media = base.appending(path: "Media")
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    for (index, name) in ["Unmatched.mp4", "Matched.mp4", "Declined.mp4"].enumerated() {
        try Data([UInt8(index)]).write(to: media.appending(path: name))
    }
    let catalog = try Catalog(path: base.appending(path: "Catalog.sqlite").path)
    let library = try catalog.createLibrary(name: "Library")
    try CatalogScanner(catalog: catalog).scan(source: try catalog.addSource(libraryID: library.id, url: media))
    func entry(_ name: String) throws -> CatalogEntry {
        try #require(catalog.entries(libraryID: library.id).first { $0.filename == name })
    }
    for name in ["Unmatched.mp4", "Matched.mp4", "Declined.mp4"] {
        let found = name == "Matched.mp4" ? PRDBTitle(id: "t", title: "Title") : nil
        let pending = try entry(name)
        try catalog.applyMatch(entryID: pending.id, result: PRDBMatch(autoTitle: found),
                               fileSize: pending.fileSize, modified: pending.modified)
    }
    try catalog.confirmMatch(entryID: try entry("Declined.mp4").id, title: nil)
    #expect(try catalog.entries(libraryID: library.id).allSatisfy { !$0.needsLookup })

    // A lookup reads the file, so a video on an unreachable source is not queued.
    let parked = base.appending(path: "Unmounted")
    try FileManager.default.moveItem(at: media, to: parked)
    #expect(try catalog.checkSources(libraryID: library.id))
    #expect(try catalog.retryUnmatched(libraryID: library.id) == 0)
    try FileManager.default.moveItem(at: parked, to: media)
    #expect(try catalog.checkSources(libraryID: library.id))

    #expect(try catalog.retryUnmatched(libraryID: library.id) == 1)
    #expect(try catalog.entries(libraryID: library.id).filter(\.needsLookup).map(\.filename) == ["Unmatched.mp4"])
    #expect(try catalog.retryUnmatched(libraryID: library.id) == 0)
}
