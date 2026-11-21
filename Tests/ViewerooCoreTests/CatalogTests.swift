import Foundation
import GRDB
import XCTest
@testable import ViewerooCore

private struct LibraryFixture {
    let base: URL
    let media: URL
    let databasePath: String
    let catalog: Catalog
    let library: CatalogLibrary
    let source: CatalogSource

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        media = base.appendingPathComponent("Synthetic media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        databasePath = base.appendingPathComponent("library.sqlite").path
        catalog = try Catalog(path: databasePath)
        library = try catalog.createLibrary(name: "Study")
        source = try catalog.addSource(libraryID: library.id, url: media)
    }

    @discardableResult
    func add(_ filename: String, data: Data = Data([0,1,2,3])) throws -> URL {
        let url = media.appendingPathComponent(filename)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func scan() throws {
        try CatalogScanner(catalog: catalog).scan(source: source)
    }

    func clean() { try? FileManager.default.removeItem(at: base) }
}

final class CatalogTests: XCTestCase {
    func testLibraryIsolationSurvivesRestartAndMatchCorrection() throws {
        let fixture = try LibraryFixture()
        defer { fixture.clean() }
        let c = fixture.catalog
        let media = try fixture.add("Workshop.mp4")
        let second = try c.createLibrary(name: "Home")
        let secondSource = try c.addSource(libraryID: second.id, url: fixture.media)
        try fixture.scan()
        try CatalogScanner(catalog: c).scan(source: secondSource)
        let first = try XCTUnwrap(c.entries(libraryID: fixture.library.id).first)
        let other = try XCTUnwrap(c.entries(libraryID: second.id).first)
        XCTAssertNotEqual(first.id, other.id)
        try c.setRating(entryID: first.id, value: 1)
        try c.setTags(entryID: first.id, tags: ["blue","Blue","  "])
        try c.setFavorite(entryID: first.id, value: true)
        let session = try c.beginSession(entryID: first.id)
        try c.recordInterval(sessionID: session, start: 0, end: 5)
        try c.setResume(entryID: first.id, seconds: 5)
        let playlist = try c.createPlaylist(libraryID: fixture.library.id, name: "Queue")
        try c.addToPlaylist(playlist.id, entryID: first.id)
        XCTAssertThrowsError(try c.addToPlaylist(playlist.id, entryID: other.id))
        let auto = PRDBTitle(id: "automatic", title: "First match")
        try c.applyMatch(entryID: first.id, result: .init(autoTitle: auto), fileSize: first.fileSize, modified: first.modified)
        let corrected = PRDBTitle(id: "manual", title: "Corrected match")
        try c.confirmMatch(entryID: first.id, title: corrected)
        try c.applyMatch(entryID: first.id, result: .init(autoTitle: auto), fileSize: first.fileSize, modified: first.modified)
        try fixture.scan()

        let reopened = try Catalog(path: fixture.databasePath)
        let entry = try XCTUnwrap(reopened.entry(first.id))
        XCTAssertEqual(entry.match, corrected)
        XCTAssertEqual(entry.rating, 1)
        XCTAssertTrue(entry.favorite)
        XCTAssertEqual(entry.tags, ["blue"])
        XCTAssertEqual(entry.playCount, 1)
        XCTAssertEqual(entry.watchTime, 5)
        XCTAssertEqual(entry.resume, 5)
        XCTAssertEqual(try reopened.playlistEntries(playlist.id).map(\.id), [first.id])
        XCTAssertEqual(try reopened.entry(other.id), other)
        try reopened.deleteLibrary(fixture.library.id)
        XCTAssertNil(try reopened.entry(first.id))
        XCTAssertEqual(try reopened.entry(other.id), other)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
    }

    func testOfflineAndMissingRemainDistinctAndKeepPersonalData() throws {
        let f = try LibraryFixture()
        defer { f.clean() }
        let c = f.catalog
        let file = try f.add("Synthetic.m4v")
        try f.scan()
        let entry = try XCTUnwrap(c.entries(libraryID: f.library.id).first)
        try c.setManualStudio(entryID: entry.id, name: "Personal selection")
        let list = try c.createPlaylist(libraryID: f.library.id, name: "Favorites for later")
        try c.addToPlaylist(list.id, entryID: entry.id)
        let session = try c.beginSession(entryID: entry.id)
        try c.recordInterval(sessionID: session, start: 0, end: 10)
        let parked = f.base.appendingPathComponent("Unmounted")
        try FileManager.default.moveItem(at: f.media, to: parked)
        try c.checkSources(libraryID: f.library.id)
        XCTAssertEqual(try c.entry(entry.id)?.availability, .offline)
        try f.scan()
        XCTAssertEqual(try c.sources(libraryID: f.library.id).first?.scanPending, true)
        XCTAssertEqual(try c.playlistEntries(list.id).map(\.playCount), [1])
        try FileManager.default.moveItem(at: parked, to: f.media)
        try FileManager.default.removeItem(at: file)
        try f.scan()
        let missing = try XCTUnwrap(c.entry(entry.id))
        XCTAssertEqual(missing.availability, .missing)
        XCTAssertEqual(missing.studio, "Personal selection")
        XCTAssertEqual(missing.watchTime, 10)
        XCTAssertEqual(try c.playlistEntries(list.id).map(\.id), [entry.id])
        try f.add(file.lastPathComponent)
        try f.scan()
        XCTAssertEqual(try c.entry(entry.id)?.availability, .available)
        XCTAssertEqual(try c.entry(entry.id)?.manualStudio, "Personal selection")
    }

    func testNestedSourcesProtectSharedEntriesForBothRemovalChoices() throws {
        for remove in [true,false] {
            let f = try LibraryFixture()
            defer { f.clean() }
            let c = f.catalog
            let outer = try f.add("Outer.mov")
            let inner = try f.add("Nested/Inner.mp4")
            try f.scan()
            let nested = try c.addSource(libraryID: f.library.id, url: inner.deletingLastPathComponent())
            let entries = try c.entries(libraryID: f.library.id)
            let outerEntry = try XCTUnwrap(entries.first { $0.filename == outer.lastPathComponent })
            let innerEntry = try XCTUnwrap(entries.first { $0.filename == inner.lastPathComponent })
            XCTAssertEqual(try c.sourceRemovalCount(nested.id), 0)
            XCTAssertEqual(try c.sourceRemovalCount(f.source.id), 1)
            try c.removeSource(f.source.id, removeOrphans: remove)
            if remove {
                XCTAssertNil(try c.entry(outerEntry.id))
            } else {
                XCTAssertEqual(try c.entry(outerEntry.id)?.availability, .missing)
            }
            XCTAssertEqual(try c.entry(innerEntry.id)?.availability, .available)
            XCTAssertTrue(FileManager.default.fileExists(atPath: inner.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: outer.path))
        }
    }

    func testFiltersAndResumesInterruptedScanWithoutDuplicates() async throws {
        let f = try LibraryFixture()
        defer { f.clean() }
        for filename in ["Top.MP4","Nested/Other.MoV","Third.m4v","Excluded.mkv"] { try f.add(filename) }
        let scan = Task.detached {
            try CatalogScanner(catalog: f.catalog).scan(source: f.source) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            try await scan.value
            XCTFail("Expected the scan to be canceled")
        } catch is CancellationError {}
        let partial = try f.catalog.entries(libraryID: f.library.id)
        XCTAssertEqual(partial.count, 1)
        XCTAssertTrue(try XCTUnwrap(f.catalog.sources(libraryID: f.library.id).first).scanPending)
        try f.scan()
        let all = try f.catalog.entries(libraryID: f.library.id)
        XCTAssertEqual(Set(all.map(\.filename)), ["Top.MP4","Other.MoV","Third.m4v"])
        XCTAssertTrue(all.contains { $0.id == partial.first?.id })
        XCTAssertFalse(try XCTUnwrap(f.catalog.sources(libraryID: f.library.id).first).scanPending)
    }

    func testOverlappingScanPreservesFilesDiscoveredDuringAnOlderTraversal() throws {
        let f = try LibraryFixture()
        defer { f.clean() }
        let file = try f.add("Nested/One.mp4")
        let nested = try f.catalog.addSource(libraryID: f.library.id, url: file.deletingLastPathComponent())
        let scanner = CatalogScanner(catalog: f.catalog)
        try scanner.scan(source: f.source) { entry in
            guard entry.filename == "One.mp4" else { return }
            do {
                try f.add("Nested/Two.mp4")
                try scanner.scan(source: nested)
            } catch { XCTFail("The overlapping scan failed: \(error)") }
        }
        let entries = try f.catalog.entries(libraryID: f.library.id)
        XCTAssertEqual(entries.map(\.filename), ["One.mp4", "Two.mp4"])
        XCTAssertTrue(entries.allSatisfy { $0.availability == .available })
    }

    func testChangedFileInvalidatesHashAndRejectsLateEnrichment() throws {
        let f = try LibraryFixture()
        defer { f.clean() }
        try f.add("Workshop.mp4")
        try f.scan()
        let old = try XCTUnwrap(f.catalog.entries(libraryID: f.library.id).first)
        try f.catalog.setHash(entryID: old.id, hash: "sample", fileSize: old.fileSize, modified: old.modified)
        try f.scan()
        XCTAssertEqual(try f.catalog.entry(old.id)?.hash, "sample")
        try f.add("Workshop.mp4", data: Data(repeating: 2, count: 8))
        try f.scan()
        try f.catalog.applyMatch(entryID: old.id, result: .init(autoTitle: .init(id: "stale", title: "Stale")),
                                 fileSize: old.fileSize, modified: old.modified)
        try f.catalog.setPlaybackFailure(entryID: old.id, message: "Stale failure", fileSize: old.fileSize, modified: old.modified)
        let new = try XCTUnwrap(f.catalog.entry(old.id))
        XCTAssertNil(new.hash)
        XCTAssertNil(new.match)
        XCTAssertNil(new.playbackFailure)
        XCTAssertTrue(new.needsLookup)
    }

    func testHistoryPreservesRepeatedPassesAndSkippedGaps() throws {
        let f = try LibraryFixture()
        defer { f.clean() }
        try f.add("Demonstration.mp4")
        try f.scan()
        let id = try XCTUnwrap(f.catalog.entries(libraryID: f.library.id).first).id
        let session = try f.catalog.beginSession(entryID: id)
        for (start,end) in [(0.0,60.0),(600,660),(600,660)] {
            try f.catalog.recordInterval(sessionID: session, start: start, end: end)
        }
        let stats = try f.catalog.playbackStats(entryID: id)
        XCTAssertEqual(stats.playCount, 1)
        XCTAssertEqual(stats.watchTime, 180)
        XCTAssertEqual(stats.segments, [.init(start: 600, end: 660, passes: 2), .init(start: 0, end: 60, passes: 1)])
    }

    func testOpeningPreviousSchemaMigratesDataInPlace() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("catalog.db").path
        do {
            let previous = try DatabaseQueue(path: path)
            try Catalog.migrator.migrate(previous, upTo: "catalog-v1")
            try previous.write { db in
                try db.execute(sql: """
                    INSERT INTO library(id,name) VALUES (1,'Legacy library');
                    INSERT INTO entry(id,libraryID,path,fileSize,modified,rating) VALUES (1,1,'/Synthetic.mp4',100,0,1);
                    INSERT INTO session(id,entryID) VALUES (1,1);
                    INSERT INTO interval(sessionID,start,end) VALUES (1,10,20);
                    """)
            }
        }
        let upgraded = try Catalog(path: path)
        XCTAssertEqual(try upgraded.libraries().map(\.name), ["Legacy library"])
        XCTAssertEqual(try upgraded.entry(1)?.rating, 1)
        XCTAssertEqual(try upgraded.playbackStats(entryID: 1).watchTime, 10)
    }
}
