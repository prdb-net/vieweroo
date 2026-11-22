import Foundation
import Testing
@testable import ViewerooApp
@testable import ViewerooCore

@Test func videoFiltersCombineWithinAndAcrossGroupsUsingLocalMetadata() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let catalog = try Catalog(path: ":memory:")
    let library = try catalog.createLibrary(name: "Archive")
    let source = try catalog.addSource(libraryID: library.id, url: folder)
    for name in ["First", "Second", "Third"] { try Data().write(to: folder.appending(path: name + ".mp4")) }
    try CatalogScanner(catalog: catalog).scan(source: source)
    let entries = try catalog.entries(libraryID: library.id)
    #expect(entries.count == 3)
    for (i, entry) in entries.enumerated() {
        let studio = PRDBStudio(id: "s\(i)", name: "Workshop")
        try catalog.confirmMatch(entryID: entry.id, title: PRDBTitle(id: "t\(i)", title: "Clip \(i)", studio: studio))
        try catalog.setTags(entryID: entry.id, tags: i == 1 ? ["Interview"] : [i == 0 ? "Archive" : "archive"])
        if i < 2 {
            let info = VideoInfo(width: i == 0 ? 3840 : 1280, height: i == 0 ? 2160 : 720,
                                 codec: "H.264", container: nil, frameRate: 24)
            try await catalog.storeVideoInfo(info, for: entry)
        }
    }
    let session = try catalog.beginSession(entryID: entries[1].id)
    try catalog.recordInterval(sessionID: session, start: 0, end: 15)

    let snapshot = try await catalog.snapshot(libraryID: library.id)
    let directory = StudioDirectory(snapshot.studioOptions)
    var filters = CollectionFilters(qualities: ["720p", "4K"], studios: ["site:s0": "Workshop", "site:s1": "Workshop"],
                                    tags: ["archive": "Archive", "interview": "Interview"])
    func matches(_ term: String = "") -> [Int64] {
        snapshot.entries.filter { filters.includes($0, directory: directory, term: term) }.map(\.id)
    }
    #expect(matches() == [entries[0].id, entries[1].id])
    #expect(matches("SECOND.mp4") == [entries[1].id])
    filters.selected.insert(.unplayed)
    #expect(matches() == [entries[0].id])
    filters.qualities.insert("Unknown")
    #expect(matches() == [entries[0].id])
    filters.studios = [:]
    #expect(matches() == [entries[0].id, entries[2].id])
    filters.qualities = ["Unknown"]
    #expect(matches() == [entries[2].id])
    let choices = VideoFilterChoices(entries: snapshot.entries, directory: directory, applied: .init())
    #expect(choices.qualityCounts == ["720p": 1, "4K": 1, "Unknown": 1])
    #expect(choices.studios.count == 3)
    #expect(choices.tags.first { $0.id == "archive" }?.count == 2)
}
