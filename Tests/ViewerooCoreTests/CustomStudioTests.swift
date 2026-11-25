import Foundation
import Testing
@testable import ViewerooCore

private struct StudioLibrary {
    let base: URL
    let media: URL
    let catalog: Catalog
    let library: CatalogLibrary
    let source: CatalogSource

    init(files: [String]) throws {
        base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        media = base.appending(path: "Media")
        for (index, file) in files.enumerated() {
            let url = media.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([UInt8(index)]).write(to: url)
        }
        catalog = try Catalog(path: base.appending(path: "Catalog.sqlite").path)
        library = try catalog.createLibrary(name: "Library")
        source = try catalog.addSource(libraryID: library.id, url: media)
        try CatalogScanner(catalog: catalog).scan(source: source)
    }

    func studios() throws -> [String: String?] {
        Dictionary(uniqueKeysWithValues: try catalog.entries(libraryID: library.id).map { ($0.filename, $0.studio) })
    }

    /// Finish every lookup without a title, as the lookup job does for files unknown to PRDB.
    /// The job passes on the studio it recognized locally.
    func finishLookups() throws {
        for entry in try catalog.entries(libraryID: library.id) where entry.needsLookup {
            let studio = entry.detectedStudio.map { PRDBStudio(id: "custom:" + $0, name: $0) }
            try catalog.applyMatch(entryID: entry.id, result: PRDBMatch(studio: studio),
                                   fileSize: entry.fileSize, modified: entry.modified)
        }
    }

    func clean() { try? FileManager.default.removeItem(at: base) }
}

@Test func ownStudiosClaimTheirFoldersAndStayCustom() async throws {
    let fixture = try StudioLibrary(files: ["Velvet Kiln/One.mp4", "Night Owl/Two.mp4", "Other/Three.mp4"])
    defer { fixture.clean() }
    let catalog = fixture.catalog, library = fixture.library.id
    try catalog.createStudio(libraryID: library, name: "Velvet Kiln")

    // A pending lookup recognizes the folder of a studio the user created.
    #expect(try await LibraryJobs.detectStudios(libraryID: library, catalog: catalog) == 1)
    #expect(try fixture.studios() == ["One.mp4": "Velvet Kiln", "Two.mp4": nil, "Three.mp4": nil])
    let options = try await catalog.snapshot(libraryID: library).studioOptions
    #expect(options.filter(\.isCustom).map(\.name) == ["Velvet Kiln"], "The recognized name must not turn into a shared name")

    // After the lookups finished, a studio created later still claims its folder.
    try fixture.finishLookups()
    #expect(try fixture.studios()["One.mp4"] == "Velvet Kiln")
    try catalog.createStudio(libraryID: library, name: "Night Owl")
    #expect(try await LibraryJobs.detectStudios(libraryID: library, catalog: catalog) == 0)
    #expect(try await LibraryJobs.detectStudios(libraryID: library, catalog: catalog, scope: .unassigned) == 1)
    #expect(try fixture.studios() == ["One.mp4": "Velvet Kiln", "Two.mp4": "Night Owl", "Three.mp4": nil])

    // A manual choice is never replaced by a folder clue.
    let three = try #require(catalog.entries(libraryID: library).first { $0.filename == "Three.mp4" })
    try catalog.createStudio(libraryID: library, name: "Other Studio")
    try catalog.setManualStudio(entryID: three.id, name: "Night Owl")
    #expect(try await LibraryJobs.detectStudios(libraryID: library, catalog: catalog, scope: .unassigned) == 0)

    // Renaming releases the folder, and deleting returns its videos to no studio.
    try catalog.renameCustomStudio(libraryID: library, name: "Velvet Kiln", to: "Kiln")
    #expect(try fixture.studios()["One.mp4"] == .some(nil))
    try catalog.deleteCustomStudio(libraryID: library, name: "Night Owl")
    #expect(try fixture.studios() == ["One.mp4": nil, "Two.mp4": nil, "Three.mp4": nil])
    #expect(try await LibraryJobs.detectStudios(libraryID: library, catalog: catalog, scope: .unassigned) == 0)
}

@Test func batchStudioAssignmentIsUndone() throws {
    let fixture = try StudioLibrary(files: ["A.mp4", "B.mp4", "C.mp4"])
    defer { fixture.clean() }
    let catalog = fixture.catalog, library = fixture.library.id
    let entries = try catalog.entries(libraryID: library)
    try catalog.setManualStudio(entryID: entries[0].id, name: "Earlier Choice")

    let receipt = try catalog.editVideos(in: library, entryIDs: entries.map(\.id), edit: .studio(name: "Glacier Loom", siteID: nil))
    #expect(receipt.changedCount == 3)
    #expect(try catalog.entries(libraryID: library).map(\.manualStudio) == ["Glacier Loom", "Glacier Loom", "Glacier Loom"])
    // Assigning the same studio again changes nothing.
    #expect(try catalog.editVideos(in: library, entryIDs: entries.map(\.id), edit: .studio(name: "glacier loom", siteID: nil)).changedCount == 0)

    // A later single edit survives the undo of the batch.
    try catalog.setManualStudio(entryID: entries[2].id, name: "Solar Parcel")
    try catalog.undoVideoEdit(receipt)
    #expect(try catalog.entries(libraryID: library).map(\.manualStudio) == ["Earlier Choice", nil, "Solar Parcel"])

    let automatic = try catalog.editVideos(in: library, entryIDs: entries.map(\.id), edit: .studio(name: nil, siteID: nil))
    #expect(automatic.changedCount == 2)
    #expect(try catalog.entries(libraryID: library).allSatisfy { $0.manualStudio == nil })
}

@Test func studioDirectoryRefreshTimeSurvivesReopening() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let path = base.appending(path: "Catalog.sqlite").path
    let refreshed = Date(timeIntervalSince1970: 1_800_000_000)
    do {
        let catalog = try Catalog(path: path)
        #expect(try catalog.studioDirectoryRefreshed() == nil)
        // More sites than one transaction holds.
        try catalog.saveStudios((0..<450).map { PRDBStudio(id: "site-\($0)", name: "Site \($0)") }, refreshed: refreshed)
        #expect(try catalog.studios().count == 450)
    }
    #expect(try Catalog(path: path).studioDirectoryRefreshed() == refreshed)
}
