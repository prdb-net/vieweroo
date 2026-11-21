import Foundation
import GRDB
import XCTest
@testable import ViewerooApp
@testable import ViewerooCore

final class SourceScanTests: XCTestCase {
    private let files = FileManager.default

    private func temporaryDirectory() throws -> URL {
        let url = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testPartialScanImportsReadableSiblingsAndPreservesUnobservedEntries() throws {
        let root = try temporaryDirectory()
        defer { try? files.removeItem(at: root) }
        let media = root.appendingPathComponent("Media")
        let restricted = media.appendingPathComponent("Restricted")
        try files.createDirectory(at: restricted, withIntermediateDirectories: true)
        let hidden = restricted.appendingPathComponent("Hidden.mov")
        let gone = media.appendingPathComponent("Gone.mov")
        try Data([1]).write(to: hidden)
        try Data([1]).write(to: gone)
        let catalog = try Catalog(path: root.appendingPathComponent("Catalog.sqlite").path)
        let library = try catalog.createLibrary(name: "Partial scan")
        let source = try catalog.addSource(libraryID: library.id, url: media)
        let scanner = CatalogScanner(catalog: catalog)
        try scanner.scan(source: source)

        try files.removeItem(at: gone)
        try files.removeItem(at: hidden)
        for index in 0..<8 {
            let sibling = media.appendingPathComponent("Sibling-\(index)")
            try files.createDirectory(at: sibling, withIntermediateDirectories: true)
            try Data([1]).write(to: sibling.appendingPathComponent("Found-\(index).mov"))
        }
        try files.setAttributes([.posixPermissions: 0], ofItemAtPath: restricted.path)
        defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }
        try XCTSkipIf(CatalogScanner.canOpen(restricted), "This account bypasses directory permissions.")
        XCTAssertThrowsError(try scanner.scan(source: source))
        let entries = try catalog.entries(libraryID: library.id)
        XCTAssertEqual(entries.filter { $0.filename.hasPrefix("Found-") && $0.availability == .available }.count, 8)
        XCTAssertEqual(entries.first { $0.filename == "Gone.mov" }?.availability, .missing)
        XCTAssertEqual(entries.first { $0.filename == "Hidden.mov" }?.availability, .available)
        XCTAssertEqual(try catalog.sources(libraryID: library.id).first?.scanPending, true)

        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path)
        try scanner.scan(source: source)
        XCTAssertEqual(try catalog.entries(libraryID: library.id).first { $0.filename == "Hidden.mov" }?.availability, .missing)
        XCTAssertEqual(try catalog.sources(libraryID: library.id).first?.scanPending, false)
    }

    func testParentScanAndRemovalRespectExplicitSourcesThroughSymbolicLinks() throws {
        for parentFirst in [true, false] {
            let root = try temporaryDirectory()
            defer { try? files.removeItem(at: root) }
            let media = root.appendingPathComponent("Media")
            let external = root.appendingPathComponent("External")
            try files.createDirectory(at: media, withIntermediateDirectories: true)
            try files.createDirectory(at: external.appendingPathComponent("Subset"), withIntermediateDirectories: true)
            let link = media.appendingPathComponent("Linked")
            try files.createSymbolicLink(at: link, withDestinationURL: external)
            // Exercise both a link as the root and a link in the selected root's ancestors.
            let selection = parentFirst ? link : link.appendingPathComponent("Subset")
            let film = selection.appendingPathComponent("Film.mp4")
            try Data([1]).write(to: film)
            let catalog = try Catalog(path: root.appendingPathComponent("Catalog.sqlite").path)
            let library = try catalog.createLibrary(name: "Source coverage")
            let scanner = CatalogScanner(catalog: catalog)
            if parentFirst { try catalog.addSource(libraryID: library.id, url: media) }
            let child = try catalog.addSource(libraryID: library.id, url: selection)
            try scanner.scan(source: child)
            let parent = try catalog.addSource(libraryID: library.id, url: media)
            let entry = try XCTUnwrap(catalog.entries(libraryID: library.id).first)
            XCTAssertEqual(entry.path, film.standardizedFileURL.path)
            XCTAssertEqual(try catalog.sourceRemovalCount(child.id), 1)

            // Old catalogs credited the parent with any filename below its path.
            try catalog.database.write { db in
                try db.execute(sql: "INSERT INTO membership(libraryID,sourceID,entryID,present) VALUES (?,?,?,1)",
                               arguments: [library.id, parent.id, entry.id])
            }
            try scanner.scan(source: parent)
            XCTAssertEqual(try catalog.entry(entry.id)?.availability, .available)
            XCTAssertEqual(try catalog.sourceRemovalCount(child.id), 1)
            XCTAssertEqual(try catalog.sourceRemovalCount(parent.id), 0)
            try catalog.removeSource(child.id, removeOrphans: parentFirst)
            if parentFirst { XCTAssertNil(try catalog.entry(entry.id)) }
            else { XCTAssertEqual(try catalog.entry(entry.id)?.availability, .missing) }
            XCTAssertTrue(files.fileExists(atPath: film.path))
        }
    }

    func testReplacingAnOrdinarySubfolderWithALinkKeepsItsHistoricalSource() throws {
        let root = try temporaryDirectory()
        defer { try? files.removeItem(at: root) }
        let media = root.appendingPathComponent("Media")
        let folder = media.appendingPathComponent("Folder")
        let target = root.appendingPathComponent("New target")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("Original.mov"))
        let catalog = try Catalog(path: root.appendingPathComponent("Catalog.sqlite").path)
        let library = try catalog.createLibrary(name: "Changed folder")
        let source = try catalog.addSource(libraryID: library.id, url: media)
        let scanner = CatalogScanner(catalog: catalog)
        try scanner.scan(source: source)
        let entry = try XCTUnwrap(catalog.entries(libraryID: library.id).first)
        try catalog.setFavorite(entryID: entry.id, value: true)
        try files.removeItem(at: folder)
        try files.createSymbolicLink(at: folder, withDestinationURL: target)
        try scanner.scan(source: source)
        XCTAssertEqual(try catalog.entry(entry.id)?.availability, .missing)
        XCTAssertEqual(try catalog.entry(entry.id)?.favorite, true)
        XCTAssertEqual(try catalog.sourceRemovalCount(source.id), 1)
        try catalog.removeSource(source.id, removeOrphans: true)
        XCTAssertNil(try catalog.entry(entry.id))
    }

    func testUpgradeQueuesOnlyOverlappingSourcesForOneCoverageCheck() throws {
        let root = try temporaryDirectory()
        defer { try? files.removeItem(at: root) }
        let path = root.appendingPathComponent("Catalog.sqlite").path
        let old = try DatabaseQueue(path: path)
        try Catalog.migrator.migrate(old, upTo: "weighted-plays-v5")
        try old.write { db in
            try db.execute(sql: """
                INSERT INTO library(id,name) VALUES (1,'Test'),(2,'Second');
                INSERT INTO source(libraryID,path,scanPending) VALUES
                  (1,'/Media',0), (1,'/Media/Nested',0), (1,'/Media-Other',0), (2,'/Media',0);
                """)
        }
        let catalog = try Catalog(path: path)
        XCTAssertEqual(try catalog.sources(libraryID: 1).filter(\.scanPending).map(\.path), ["/Media", "/Media/Nested"])
        XCTAssertFalse(try XCTUnwrap(catalog.sources(libraryID: 2).first).scanPending)
        try old.write { db in try db.execute(sql: "UPDATE source SET scanPending = 0") }
        XCTAssertTrue(try Catalog(path: path).sources(libraryID: 1).allSatisfy { !$0.scanPending })
    }

    #if DEBUG
    @MainActor
    func testAddingSourcesDuringImportSkipsCompletedRootsAndPreservesQueuedWork() async throws {
        let root = try temporaryDirectory()
        defer { try? files.removeItem(at: root) }
        let media = root.appendingPathComponent("Media")
        try files.createDirectory(at: media, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: root.appendingPathComponent("prdb.json"))
        let suite = "vieweroo.source-scans.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = TestLibraryProfile.model(at: root, preferences: preferences)
        model.start()
        defer { model.selectLibrary(nil) }
        let catalog = try XCTUnwrap(model.catalog)
        let libraryID = try XCTUnwrap(model.libraryID)
        func waitForScans(_ count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < deadline {
                if model.sources.count == count && !model.scanBusy && !model.sources.contains(where: \.scanPending) { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("The requested scans did not finish.")
        }
        try await waitForScans(1)
        let first = try XCTUnwrap(catalog.sources(libraryID: libraryID).first)
        func generation() throws -> Int64? {
            try catalog.database.read { db in
                try Int64.fetchOne(db, sql: "SELECT generation FROM source WHERE id = ?", arguments: [first.id])
            }
        }
        let before = try generation()
        let folders = ["Second", "Third"].map { root.appendingPathComponent($0) }
        for folder in folders { try files.createDirectory(at: folder, withIntermediateDirectories: true) }
        // Add another folder before the first queued scan has yielded to its worker.
        model.addSources([folders[0]])
        model.addSources([folders[1]])
        try await waitForScans(3)
        XCTAssertEqual(try generation(), before)
        model.refresh()
        try await waitForScans(3)
        XCTAssertGreaterThan(try XCTUnwrap(generation()), try XCTUnwrap(before))
    }
    #endif
}
