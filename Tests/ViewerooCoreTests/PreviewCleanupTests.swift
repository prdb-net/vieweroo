import Darwin
import Foundation
import Testing
@testable import ViewerooCore

@Test func cleanupKeepsSharedOfflinePreviewsAndAnActiveGeneration() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appending(path: UUID().uuidString)
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }
    let cache = PreviewCache(root: root.appending(path: "Previews"))
    let catalog = try Catalog(path: root.appending(path: "Catalog.sqlite").path)
    try await cache.removeOrphans(in: catalog)
    let media = root.appending(path: "Media")
    try files.createDirectory(at: media, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: media.appending(path: "Clip.mov"))
    let first = try catalog.createLibrary(name: "First")
    let second = try catalog.createLibrary(name: "Second")
    for library in [first, second] {
        let source = try catalog.addSource(libraryID: library.id, url: media)
        try CatalogScanner(catalog: catalog).scan(source: source)
    }
    let entry = try #require(catalog.entries(libraryID: second.id).first)
    let shared = cache.directory(for: entry.url, size: entry.fileSize,
                                 modificationDate: Date(timeIntervalSince1970: entry.modified))
    let obsolete = cache.directory(for: entry.url, size: entry.fileSize + 1,
                                   modificationDate: Date(timeIntervalSince1970: entry.modified))
    try catalog.deleteLibrary(first.id)
    try files.moveItem(at: media, to: root.appending(path: "Unmounted"))
    _ = try catalog.checkSources(libraryID: second.id)

    let recent = cache.root.appending(path: String(repeating: "a", count: 64))
    let abandoned = cache.root.appending(path: ".building-" + UUID().uuidString)
    let active = cache.root.appending(path: ".building-" + UUID().uuidString)
    let unrelated = cache.root.appending(path: ".building-other")
    for url in [shared, obsolete, abandoned, active, unrelated, recent] {
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        if url != recent {
            try files.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -172_800)], ofItemAtPath: url.path)
        }
    }
    let lock = open(active.path, O_RDONLY | O_DIRECTORY | O_EXLOCK | O_NONBLOCK)
    try #require(lock >= 0)
    defer { close(lock) }

    try await cache.removeOrphans(in: catalog)
    #expect(!files.fileExists(atPath: obsolete.path))
    #expect(!files.fileExists(atPath: abandoned.path))
    for kept in [shared, active, unrelated, recent] { #expect(files.fileExists(atPath: kept.path)) }

    try catalog.deleteLibrary(second.id)
    try await cache.removeOrphans(in: catalog)
    #expect(!files.fileExists(atPath: shared.path))
}
