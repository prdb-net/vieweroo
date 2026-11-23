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
    func testVideoQualityForCroppedAndPortraitFrames() {
        for (width, height, quality) in [(3840, 1600, "4K"), (2160, 3840, "4K"), (2560, 1440, "1440p"),
                                         (1920, 800, "1080p"), (720, 1280, "720p"), (720, 576, "SD")] {
            XCTAssertEqual(VideoInfo(width: width, height: height, codec: "test", container: nil,
                                     frameRate: nil).quality, quality)
        }
    }

    func testFileReplacementInvalidatesVideoInfoAndRejectsStaleRead() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.clean() }
        try fixture.add("Movie.mp4")
        try fixture.scan()
        let original = try XCTUnwrap(fixture.catalog.entries(libraryID: fixture.library.id).first)
        let info = VideoInfo(width: 1920, height: 1080, codec: "H.264", container: "MPEG-4", frameRate: 24)
        try await fixture.catalog.storeVideoInfo(info, for: original)
        try fixture.scan()
        XCTAssertEqual(try fixture.catalog.entry(original.id)?.videoInfo, info)
        try fixture.add("Movie.mp4", data: Data([1, 2]))
        try fixture.scan()
        try await fixture.catalog.storeVideoInfo(info, for: original)
        XCTAssertNil(try fixture.catalog.entry(original.id)?.videoInfo)
    }

    func testRenameKeepsSharedAndLinkedLibraryEntriesAcrossScans() throws {
        let fixture = try LibraryFixture()
        defer { fixture.clean() }
        let original = try fixture.add("Scene.MOV")
        let catalog = fixture.catalog
        let second = try catalog.createLibrary(name: "Second")
        let link = fixture.base.appendingPathComponent("Linked folder")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.media)
        let secondSource = try catalog.addSource(libraryID: second.id, url: link)
        let scanner = CatalogScanner(catalog: catalog)
        try fixture.scan()
        try scanner.scan(source: secondSource)
        let firstEntry = try XCTUnwrap(catalog.entries(libraryID: fixture.library.id).first)
        let secondEntry = try XCTUnwrap(catalog.entries(libraryID: second.id).first)
        try catalog.setFavorite(entryID: firstEntry.id, value: true)
        let session = try catalog.beginSession(entryID: secondEntry.id)
        try catalog.recordInterval(sessionID: session, start: 7, end: 20)

        try catalog.renameFile(firstEntry, basename: "New scene")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try Data(contentsOf: fixture.media.appendingPathComponent("New scene.MOV")), Data([0,1,2,3]))
        try fixture.scan()
        try scanner.scan(source: secondSource)
        XCTAssertEqual(try catalog.entries(libraryID: fixture.library.id).map(\.id), [firstEntry.id])
        XCTAssertEqual(try catalog.entries(libraryID: second.id).map(\.id), [secondEntry.id])
        let renamed = try XCTUnwrap(catalog.entry(firstEntry.id))
        XCTAssertTrue(renamed.favorite)
        XCTAssertEqual(renamed.playCount, 0)
        XCTAssertEqual(try catalog.entry(secondEntry.id)?.path, link.appendingPathComponent("New scene.MOV").standardizedFileURL.path)
        XCTAssertEqual(try catalog.entry(secondEntry.id)?.watchTime, 13)
        XCTAssertEqual(try catalog.entry(secondEntry.id)?.favorite, false)
        try catalog.renameFile(renamed, basename: "New Scene")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.media.path), ["New Scene.MOV"])
    }

    func testRenameRejectsInvalidNamesAndCollisionsWithoutChangingTheSource() throws {
        let fixture = try LibraryFixture()
        defer { fixture.clean() }
        let source = try fixture.add("First.mov")
        let taken = try fixture.add("Taken.mov", data: Data([5]))
        try fixture.scan()
        let entry = try XCTUnwrap(fixture.catalog.entries(libraryID: fixture.library.id).first)
        _ = try fixture.add("Unscanned.mov", data: Data([6]))
        for name in [" ", "../Other", "Bad:Name", "Bad\0Name", "Taken", "Unscanned"] {
            XCTAssertThrowsError(try fixture.catalog.renameFile(entry, basename: name))
        }
        try FileManager.default.removeItem(at: taken)
        XCTAssertThrowsError(try fixture.catalog.renameFile(entry, basename: "Taken"))
        XCTAssertEqual(try fixture.catalog.entry(entry.id)?.path, entry.path)
        XCTAssertEqual(try Data(contentsOf: source), Data([0,1,2,3]))
        try Data([7]).write(to: source)
        XCTAssertThrowsError(try fixture.catalog.renameFile(entry, basename: "Replacement"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testSiteOnlySuggestionsNeedPathEvidenceAtImport() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.clean() }
        for filename in ["Black.24.03.01.Dawn.mp4", "Title.Silver.Lake.Dawn.mp4", "SilverLake.Dawn.mp4"] {
            try fixture.add(filename)
        }
        try fixture.scan()
        let client = PRDBClient { request in
            let url = try XCTUnwrap(request.url)
            let body: [String: Any]
            if url.path == "/videos/identify" {
                let json = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
                let files = try XCTUnwrap(json?["files"] as? [[String: Any]])
                body = ["results": try files.map { file -> [String: Any] in
                    let filename = try XCTUnwrap(file["filename"] as? String)
                    let name = filename.hasPrefix("Black") ? "Black" : "Silver Lake"
                    return ["ref": try XCTUnwrap(file["ref"]), "confidence": 1, "matchedBy": 4,
                            "candidates": [], "site": ["id": name, "title": name]]
                }]
            } else {
                XCTAssertEqual(url.path, "/videos")
                body = ["items": [], "totalCount": 0]
            }
            return (try JSONSerialization.data(withJSONObject: body),
                    try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        try await LibraryJobs.identify(libraryID: fixture.library.id, catalog: fixture.catalog, key: "fixture",
                                       client: client, updated: {})
        let entries = try fixture.catalog.entries(libraryID: fixture.library.id)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.filter { $0.studio == "Silver Lake" }.map(\.filename), ["SilverLake.Dawn.mp4"])
        XCTAssertEqual(entries.filter { $0.studio == nil }.count, 2)
        XCTAssertFalse(entries.contains(where: \.needsLookup))
    }

    func testUpgradeRechecksCachedStudiosWithoutRepeatingTitleLookups() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("library.sqlite").path
        let title = PRDBTitle(id: "matched", title: "Dawn", studio: .init(id: "b", name: "Black"))
        let data = try JSONEncoder().encode(title)
        do {
            let old = try DatabaseQueue(path: path)
            try Catalog.migrator.migrate(old, upTo: "recent-playlists-v7")
            try old.write { db in
                try db.execute(sql: """
                    INSERT INTO library(id,name) VALUES (1,'Fixture');
                    INSERT INTO source(id,libraryID,path) VALUES (1,1,'/Library');
                    INSERT INTO studio(id,name) VALUES ('sl','Silver Lake');
                    INSERT INTO entry(id,libraryID,path,fileSize,modified,detectedStudio,needsLookup) VALUES
                      (1,1,'/Library/Dawn.Black.mp4',12,0,'Black',0),
                      (2,1,'/Library/Silver Lake/Dawn.Black.mp4',12,0,'Black',0),
                      (3,1,'/Library/Night.SilverLake.mp4',12,0,'Silver Lake',0),
                      (4,1,'/Library/Confirmed.Black.mp4',12,0,'Black',0),
                      (5,1,'/Library/CedarGrove.River.mp4',12,0,'Cedar Grove',0);
                    INSERT INTO membership(libraryID,sourceID,entryID) SELECT libraryID,1,id FROM entry;
                    UPDATE entry SET manualStudio = 'Chosen', favorite = 1 WHERE id = 3;
                    """)
                try db.execute(sql: "UPDATE entry SET confirmed = 1, matchData = ? WHERE id = 4", arguments: [data])
            }
        }
        let upgraded = try Catalog(path: path)
        XCTAssertNil(try XCTUnwrap(upgraded.entry(1)).studio)
        XCTAssertEqual(try upgraded.entry(2)?.studio, "Silver Lake")
        let manual = try XCTUnwrap(upgraded.entry(3))
        XCTAssertEqual(manual.studio, "Chosen")
        let options = try upgraded.database.read { try Catalog.studioOptions($0, libraryID: 1) }
        XCTAssertEqual(options.filter(\.isCustom).map(\.name), ["Chosen"])
        XCTAssertTrue(options.contains { $0.name == "Black" && !$0.isCustom })
        XCTAssertTrue(options.contains { $0.name == "Cedar Grove" && !$0.isCustom })
        XCTAssertTrue(manual.favorite)
        XCTAssertNil(manual.detectedStudio)
        let confirmed = try XCTUnwrap(upgraded.entry(4))
        XCTAssertEqual(confirmed.match, title)
        XCTAssertEqual(confirmed.studio, "Black")
        XCTAssertTrue(confirmed.confirmed)
        XCTAssertEqual(try upgraded.entry(5)?.studio, "Cedar Grove")
        XCTAssertFalse(try upgraded.entries(libraryID: 1).contains(where: \.needsLookup))
    }

    func testStudioFavoritesSurviveMigrationRenameAndDirectoryResolutionWithinTheirLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let previous = try DatabaseQueue(path: root.path)
            try Catalog.migrator.migrate(previous, upTo: "creator-accounts-v11")
            try await previous.write { db in
                try db.execute(sql: "INSERT INTO library(id,name) VALUES (1,'First'),(2,'Second')")
                try db.execute(sql: "INSERT INTO customStudio(libraryID,name) VALUES (1,'Local'),(2,'Local')")
            }
        }
        let catalog = try Catalog(path: root.path)
        let local = StudioOption(name: "Local", isCustom: true)
        let initial = try await catalog.snapshot(libraryID: 1)
        XCTAssertTrue(initial.favoriteStudioIDs.isEmpty)
        XCTAssertEqual(initial.studioOptions, [local])
        for id: Int64 in [1, 2] { try catalog.setStudioFavorite(libraryID: id, studio: local, favorite: true) }
        try catalog.renameCustomStudio(libraryID: 1, name: "local", to: "Archive")
        let renamed = try await Catalog(path: root.path).snapshot(libraryID: 1)
        XCTAssertEqual(renamed.favoriteStudioIDs, [StudioOption(name: "Archive", isCustom: true).id])
        try catalog.deleteCustomStudio(libraryID: 1, name: "archive")
        try catalog.createStudio(libraryID: 1, name: "Archive")
        let recreated = try await catalog.snapshot(libraryID: 1)
        XCTAssertTrue(recreated.favoriteStudioIDs.isEmpty)
        try catalog.saveStudios([.init(id: "site-a", name: "Local")])
        let resolved = try await catalog.snapshot(libraryID: 2)
        let site = try XCTUnwrap(resolved.studioOptions.first)
        XCTAssertEqual(site.siteID, "site-a")
        XCTAssertEqual(resolved.favoriteStudioIDs, [site.id])
        try catalog.setStudioFavorite(libraryID: 2, studio: site, favorite: false)
        let cleared = try await catalog.snapshot(libraryID: 2)
        XCTAssertTrue(cleared.favoriteStudioIDs.isEmpty)
    }

    func testCustomStudiosPersistAndDeletionRestoresAutomaticAssignmentsInOneLibrary() async throws {
        let f = try LibraryFixture()
        defer { f.clean() }
        let catalog = f.catalog, library = f.library.id
        let other = try catalog.createLibrary(name: "Other").id
        try catalog.createStudio(libraryID: library, name: "  Étude  ")
        try catalog.createStudio(libraryID: other, name: "Étude")
        XCTAssertThrowsError(try catalog.createStudio(libraryID: library, name: "étude"))
        XCTAssertThrowsError(try catalog.createStudio(libraryID: library, name: " "))
        XCTAssertThrowsError(try catalog.createStudio(libraryID: library, name: "Unknown Studio"))
        let reopened = try Catalog(path: f.databasePath)
        let initial = try await reopened.snapshot(libraryID: library)
        XCTAssertEqual(initial.studioOptions.filter(\.isCustom).map(\.name), ["Étude"])
        try f.add("Workshop.mp4")
        try f.scan()
        let entry = try XCTUnwrap(catalog.entries(libraryID: library).first)
        try catalog.confirmMatch(entryID: entry.id, title: .init(id: "title", title: "Workshop", studio: .init(id: "s", name: "Field Notes")))
        try catalog.setManualStudio(entryID: entry.id, name: "étude")
        XCTAssertEqual(try catalog.entry(entry.id)?.manualStudio, "Étude")
        try catalog.deleteCustomStudio(libraryID: library, name: "ÉTUDE")
        XCTAssertEqual(try catalog.entry(entry.id)?.studio, "Field Notes")
        XCTAssertThrowsError(try catalog.deleteCustomStudio(libraryID: library, name: "field notes"))
        let untouched = try await reopened.snapshot(libraryID: other)
        XCTAssertEqual(untouched.studioOptions.filter(\.isCustom).map(\.name), ["Étude"])
        try catalog.setManualStudio(entryID: entry.id, name: "Personal")
        try catalog.saveStudios([.init(id: "import", name: "PERSONAL")])
        XCTAssertThrowsError(try catalog.deleteCustomStudio(libraryID: library, name: "Personal"))
        let refreshed = try await catalog.snapshot(libraryID: library)
        XCTAssertEqual(refreshed.studioOptions.map(\.name), ["Field Notes", "PERSONAL"])
        XCTAssertFalse(refreshed.studioOptions.contains(where: \.isCustom))
    }

    func testRenamingStudiosPreservesAssignmentsAndProtectsOtherNames() async throws {
        let f = try LibraryFixture()
        defer { f.clean() }
        try f.add("One.mp4")
        try f.add("Two.mp4")
        try f.scan()
        let catalog = f.catalog, library = f.library.id
        let other = try catalog.createLibrary(name: "Other").id
        let otherSource = try catalog.addSource(libraryID: other, url: f.media)
        try CatalogScanner(catalog: catalog).scan(source: otherSource)
        for id in [library, other] {
            for entry in try catalog.entries(libraryID: id) {
                try catalog.setManualStudio(entryID: entry.id, name: "Étude")
            }
        }
        try catalog.createStudio(libraryID: library, name: "Empty")
        try catalog.renameCustomStudio(libraryID: library, name: "Empty", to: "Spare")
        try catalog.saveStudios([.init(id: "s", name: "Imported")])
        for invalid in ["spare", "IMPORTED", "  ", "unknown studio"] {
            XCTAssertThrowsError(try catalog.renameCustomStudio(libraryID: library, name: "Étude", to: invalid))
        }
        XCTAssertThrowsError(try catalog.renameCustomStudio(libraryID: library, name: "Imported", to: "Other Name"))
        XCTAssertThrowsError(try catalog.renameCustomStudio(libraryID: library, name: "Missing", to: "Other Name"))
        XCTAssertEqual(try catalog.entries(libraryID: library).compactMap(\.manualStudio), ["Étude", "Étude"])
        try catalog.renameCustomStudio(libraryID: library, name: "étude", to: "  ÉTUDE ")
        XCTAssertEqual(try catalog.entries(libraryID: library).compactMap(\.manualStudio), ["ÉTUDE", "ÉTUDE"])
        try catalog.renameCustomStudio(libraryID: library, name: "ÉTUDE", to: "Night Archive")
        let reopened = try Catalog(path: f.databasePath)
        let updated = try await reopened.snapshot(libraryID: library)
        XCTAssertEqual(updated.entries.compactMap(\.studio), ["Night Archive", "Night Archive"])
        XCTAssertEqual(updated.studioOptions.filter(\.isCustom).map(\.name), ["Night Archive", "Spare"])
        XCTAssertEqual(try reopened.entries(libraryID: other).compactMap(\.manualStudio), ["Étude", "Étude"])
        try catalog.saveStudios([.init(id: "late", name: "NIGHT ARCHIVE")])
        XCTAssertThrowsError(try catalog.renameCustomStudio(libraryID: library, name: "Night Archive", to: "New Name"))
    }

    func testCreatorProfilesKeepTheirSiteIdentityAcrossOverridesAndRefresh() async throws {
        let f = try LibraryFixture()
        defer { f.clean() }
        try f.add("Sample.mp4")
        try f.scan()
        let catalog = f.catalog
        let entry = try XCTUnwrap(catalog.entries(libraryID: f.library.id).first)
        let first = PRDBStudio(id: "a", name: "Workshop", creator: CreatorAccount(platformID: "of", key: "onlyfans",
                                                                                   title: "OnlyFans", handle: "workshop"))
        let second = PRDBStudio(id: "b", name: "Workshop", creator: CreatorAccount(platformID: "f", key: "fansly",
                                                                                    title: "Fansly", handle: "workshop.films"))
        try catalog.confirmMatch(entryID: entry.id, title: .init(id: "t", title: "Sample", studio: first))
        try catalog.saveStudios([first, second])
        let reopened = try Catalog(path: f.databasePath)
        let snapshot = try await reopened.snapshot(libraryID: f.library.id)
        let directory = StudioDirectory(snapshot.studioOptions)
        XCTAssertEqual(snapshot.studioOptions.count, 2)
        XCTAssertEqual(directory.studio(for: try XCTUnwrap(reopened.entry(entry.id))).creator, first.creator)
        try catalog.setManualStudio(entryID: entry.id, name: second.name, siteID: second.id)
        XCTAssertEqual(directory.studio(for: try XCTUnwrap(reopened.entry(entry.id))).creator?.profileURL?.absoluteString,
                       "https://fansly.com/workshop.films")
        try catalog.setManualStudio(entryID: entry.id, name: "Workshop")
        XCTAssertNil(directory.studio(for: try XCTUnwrap(reopened.entry(entry.id))).creator)
        try catalog.setManualStudio(entryID: entry.id, name: "Local Only")
        XCTAssertNil(directory.studio(for: try XCTUnwrap(reopened.entry(entry.id))).creator)
        try catalog.setManualStudio(entryID: entry.id, name: nil)
        XCTAssertEqual(directory.studio(for: try XCTUnwrap(reopened.entry(entry.id))).siteID, first.id)
        try catalog.saveStudios([PRDBStudio(id: first.id, name: first.name)])
        let refresh = try await reopened.snapshot(libraryID: f.library.id)
        XCTAssertNil(StudioDirectory(refresh.studioOptions).studio(for: try XCTUnwrap(refresh.entries.first)).creator)
        for handle in [nil, "", "..", "x/y", "a?b", "https://example.org"] {
            XCTAssertNil(CreatorAccount(platformID: nil, key: "fansly", title: nil, handle: handle)?.profileURL)
        }
        XCTAssertNil(CreatorAccount(platformID: nil, key: "other", title: "OnlyFans", handle: "workshop")?.profileURL)
    }

    func testSymlinkedSourceKeepsItsSelectedPathAcrossScans() throws {
        let fixture = try LibraryFixture()
        defer { fixture.clean() }
        _ = try fixture.add("Nested/Workshop.mp4")
        let link = fixture.base.appendingPathComponent("Linked media")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.media)
        let library = try fixture.catalog.createLibrary(name: "Linked folders")
        let source = try fixture.catalog.addSource(libraryID: library.id, url: link)
        let scanner = CatalogScanner(catalog: fixture.catalog)
        try scanner.scan(source: source)
        let first = try XCTUnwrap(fixture.catalog.entries(libraryID: library.id).first)
        XCTAssertEqual(first.path, link.appendingPathComponent("Nested/Workshop.mp4").standardizedFileURL.path)
        XCTAssertEqual(first.availability, .available)
        try scanner.scan(source: source)
        XCTAssertEqual(try fixture.catalog.entries(libraryID: library.id).map(\.id), [first.id])
    }

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
        try c.recordInterval(sessionID: session, start: 0, end: 15)
        try c.setResume(entryID: first.id, seconds: 15)
        let playlist = try c.createPlaylist(libraryID: fixture.library.id, name: "Queue")
        XCTAssertTrue(try c.addToPlaylist(playlist.id, entryID: first.id))
        XCTAssertFalse(try c.addToPlaylist(playlist.id, entryID: first.id))
        XCTAssertEqual(try c.playlists(libraryID: fixture.library.id).first?.videoCount, 1)
        XCTAssertThrowsError(try c.addToPlaylist(-1, entryID: first.id))
        XCTAssertThrowsError(try c.addToPlaylist(playlist.id, entryID: other.id))
        try c.renamePlaylist(playlist.id, to: "  Watch later  ")
        XCTAssertThrowsError(try c.renamePlaylist(playlist.id, to: "  "))
        let auto = PRDBTitle(id: "automatic", title: "First match")
        try c.applyMatch(entryID: first.id, result: .init(autoTitle: auto), fileSize: first.fileSize, modified: first.modified)
        let corrected = PRDBTitle(id: "manual", title: "Corrected match")
        try c.confirmMatch(entryID: first.id, title: corrected)
        try c.applyMatch(entryID: first.id, result: .init(autoTitle: auto), fileSize: first.fileSize, modified: first.modified)
        try fixture.scan()

        try c.renameLibrary(fixture.library.id, to: "  Workshop  ")
        XCTAssertThrowsError(try c.renameLibrary(fixture.library.id, to: " \n"))
        let reopened = try Catalog(path: fixture.databasePath)
        XCTAssertEqual(try reopened.libraries().map(\.name), ["Home", "Workshop"])
        XCTAssertEqual(try reopened.libraries().last?.id, fixture.library.id)
        let entry = try XCTUnwrap(reopened.entry(first.id))
        XCTAssertEqual(entry.match, corrected)
        XCTAssertEqual(entry.rating, 1)
        XCTAssertTrue(entry.favorite)
        XCTAssertEqual(entry.tags, ["blue"])
        XCTAssertEqual(entry.playCount, 1)
        XCTAssertEqual(entry.watchTime, 15)
        XCTAssertEqual(entry.resume, 15)
        XCTAssertEqual(try reopened.playlists(libraryID: fixture.library.id).map(\.name), ["Watch later"])
        XCTAssertEqual(try reopened.playlistEntries(playlist.id).map(\.id), [first.id])
        XCTAssertEqual(try reopened.entry(other.id), other)
        try reopened.deleteLibrary(fixture.library.id)
        XCTAssertNil(try reopened.entry(first.id))
        XCTAssertEqual(try reopened.entry(other.id), other)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
    }

    func testBulkHistoryRemovalKeepsResumeAndUndoMergesWithNewPlayback() throws {
        let f = try LibraryFixture()
        defer { f.clean() }
        try f.add("First.mp4")
        try f.add("Second.mp4")
        try f.scan()
        let c = f.catalog
        let entries = try c.entries(libraryID: f.library.id)
        let ids = entries.map(\.id)
        let first = try XCTUnwrap(ids.first)
        let second = try XCTUnwrap(ids.last)
        let other = try c.createLibrary(name: "Separate")
        let source = try c.addSource(libraryID: other.id, url: f.media)
        try CatalogScanner(catalog: c).scan(source: source)
        let foreign = try XCTUnwrap(c.entries(libraryID: other.id).first?.id)
        for id in ids + [foreign] {
            let session = try c.beginSession(entryID: id)
            try c.recordInterval(sessionID: session, start: 3, end: 20)
            try c.recordInterval(sessionID: session, start: 10, end: 24)
            try c.setResume(entryID: id, seconds: 24)
        }
        let original = try c.playbackStats(entryID: first)
        let shortSession = try c.beginSession(entryID: first)
        try c.recordInterval(sessionID: shortSession, start: 0, end: 4)
        XCTAssertThrowsError(try c.editVideos(in: f.library.id, entryIDs: [first, foreign], edit: .removeHistory))
        XCTAssertEqual(try c.playbackStats(entryID: first), original)

        let receipt = try c.editVideos(in: f.library.id, entryIDs: ids, edit: .removeHistory)
        XCTAssertEqual(receipt.changedCount, 2)
        let reopened = try Catalog(path: f.databasePath)
        for id in ids {
            XCTAssertEqual(try reopened.playbackStats(entryID: id), PlaybackStats(playCount: 0, watchTime: 0, segments: []))
            XCTAssertEqual(try reopened.entry(id)?.weightedPlays, 0)
            XCTAssertEqual(try reopened.entry(id)?.resume, 24)
        }
        XCTAssertEqual(try reopened.playbackStats(entryID: foreign), original)
        XCTAssertEqual(try reopened.editVideos(in: f.library.id, entryIDs: ids, edit: .removeHistory).changedCount, 0)

        let newer = try reopened.beginSession(entryID: second)
        try reopened.recordInterval(sessionID: newer, start: 40, end: 55)
        try reopened.setResume(entryID: second, seconds: 55)
        try reopened.undoVideoEdit(receipt)
        try reopened.undoVideoEdit(receipt)
        XCTAssertEqual(try reopened.playbackStats(entryID: first), original)
        XCTAssertEqual(try reopened.playbackStats(entryID: second).playCount, original.playCount + 1)
        XCTAssertEqual(try reopened.playbackStats(entryID: second).watchTime, original.watchTime + 15)
        XCTAssertEqual(try reopened.entry(second)?.resume, 55)
        // Even a session that was too short to count gets its original identity and intervals back.
        try reopened.recordInterval(sessionID: shortSession, start: 4, end: 10)
        XCTAssertEqual(try reopened.playbackStats(entryID: first).watchTime, original.watchTime + 10)
    }

    func testRemovedTitleStaysUnmatchedUntilAnotherManualChoice() throws {
        let f = try LibraryFixture()
        defer { f.clean() }
        try f.add("Workshop.mp4")
        try f.scan()
        let catalog = f.catalog
        let entry = try XCTUnwrap(catalog.entries(libraryID: f.library.id).first)
        let automatic = PRDBTitle(id: "auto", title: "First title")
        let manual = PRDBTitle(id: "chosen", title: "Selected title")
        let result = PRDBMatch(autoTitle: automatic, candidates: [manual])
        try catalog.applyMatch(entryID: entry.id, result: result, fileSize: entry.fileSize, modified: entry.modified)
        try catalog.setFavorite(entryID: entry.id, value: true)
        try catalog.setTags(entryID: entry.id, tags: ["Keep"])
        try catalog.setResume(entryID: entry.id, seconds: 12)
        let playlist = try catalog.createPlaylist(libraryID: f.library.id, name: "Weekend")
        try catalog.addToPlaylist(playlist.id, entryID: entry.id)

        for title in [automatic, manual] {
            XCTAssertEqual(try catalog.entry(entry.id)?.match, title)
            try catalog.confirmMatch(entryID: entry.id, title: nil)
            try catalog.applyMatch(entryID: entry.id, result: result, fileSize: entry.fileSize, modified: entry.modified)
            let cleared = try XCTUnwrap(catalog.entry(entry.id))
            XCTAssertTrue(cleared.confirmed)
            XCTAssertFalse(cleared.needsLookup)
            XCTAssertNil(cleared.match)
            XCTAssertEqual(cleared.title, "Workshop")
            XCTAssertEqual(cleared.candidates, [manual])
            XCTAssertEqual(cleared.tags, ["Keep"])
            XCTAssertTrue(cleared.favorite)
            XCTAssertEqual(cleared.resume, 12)
            XCTAssertEqual(try catalog.playlistEntryIDs(playlist.id), [entry.id])
            if title == automatic { try catalog.confirmMatch(entryID: entry.id, title: manual) }
        }

        try f.add("Workshop.mp4", data: Data(repeating: 0, count: 12))
        try f.scan()
        let reopened = try Catalog(path: f.databasePath)
        let rescanned = try XCTUnwrap(reopened.entry(entry.id))
        XCTAssertTrue(rescanned.confirmed)
        XCTAssertFalse(rescanned.needsLookup)
        XCTAssertNil(rescanned.match)
        try reopened.confirmMatch(entryID: entry.id, title: manual)
        XCTAssertEqual(try reopened.entry(entry.id)?.match, manual)
    }

    func testSuggestionsRankPlayableNeighborsFromTheSameLibrary() throws {
        let f = try LibraryFixture()
        defer { f.clean() }
        for name in ["Current","Studio","Cast","Tag","Unavailable","Removed","A","B","C","D","E","F"] {
            try f.add(name + ".mp4")
        }
        try f.scan()
        let catalog = f.catalog
        let second = try catalog.createLibrary(name: "Other")
        let source = try catalog.addSource(libraryID: second.id, url: f.media)
        try CatalogScanner(catalog: catalog).scan(source: source)
        let all = try catalog.entries(libraryID: f.library.id)
        func named(_ name: String) throws -> CatalogEntry { try XCTUnwrap(all.first { $0.title == name }) }

        let current = try named("Current"), sharedCast = try named("Cast")
        let person = PRDBPerformer(id: "one", name: "Alex")
        for entry in [current, sharedCast] {
            try catalog.confirmMatch(entryID: entry.id, title: .init(id: entry.title, title: entry.title, performers: [person]))
        }
        for name in ["Current","Studio","Removed"] {
            try catalog.setManualStudio(entryID: named(name).id, name: "Harbor")
        }
        let unavailable = try named("Unavailable")
        try catalog.setPlaybackFailure(entryID: unavailable.id, message: "Decoder unavailable",
                                       fileSize: unavailable.fileSize, modified: unavailable.modified)
        try FileManager.default.removeItem(at: named("Removed").url)
        try f.scan()
        try catalog.setTags(entryID: current.id, tags: ["Blue"])
        try catalog.setTags(entryID: named("Tag").id, tags: ["blue"])
        let refreshed = try XCTUnwrap(catalog.entry(current.id))
        let library = try catalog.entries(libraryID: f.library.id)
        let mixed = try catalog.entries(libraryID: second.id) + library
        let choices = RelatedVideo.suggestions(for: refreshed, in: mixed)
        XCTAssertEqual(choices.count, 8)
        XCTAssertEqual(choices.prefix(3).map(\.entry.title), ["Studio", "Cast", "Tag"])
        XCTAssertEqual(choices.prefix(3).map(\.subtitle), ["Harbor", "With Alex", "Tagged Blue"])
        XCTAssertEqual(choices[3].entry.title, "D")
        XCTAssertTrue(choices.allSatisfy { $0.entry.libraryID == current.libraryID })
        XCTAssertTrue(Set(choices.map(\.entry.title)).isDisjoint(with: ["Current","Removed","Unavailable"]))
        XCTAssertTrue(RelatedVideo.suggestions(for: refreshed, in: [refreshed]).isEmpty)
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
        try f.catalog.setDuration(60, for: old)
        try f.add("Workshop.mp4", data: Data(repeating: 2, count: 8))
        try f.scan()
        try f.catalog.applyMatch(entryID: old.id, result: .init(autoTitle: .init(id: "stale", title: "Stale")),
                                 fileSize: old.fileSize, modified: old.modified)
        try f.catalog.setPlaybackFailure(entryID: old.id, message: "Stale failure", fileSize: old.fileSize, modified: old.modified)
        try f.catalog.setDuration(120, for: old)
        let new = try XCTUnwrap(f.catalog.entry(old.id))
        XCTAssertNil(new.duration)
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

    func testWeightedPlaysAccumulateCoverageAndWatchTimeWithinEachQualifyingSession() throws {
        let f = try LibraryFixture()
        defer { f.clean() }
        try f.add("Example.mp4")
        try f.scan()
        let entry = try XCTUnwrap(f.catalog.entries(libraryID: f.library.id).first)
        func watch(_ intervals: [(Double, Double)]) throws {
            let session = try f.catalog.beginSession(entryID: entry.id)
            for (start, end) in intervals {
                try f.catalog.recordInterval(sessionID: session, start: start, end: end)
            }
        }
        func score() throws -> Double { try XCTUnwrap(f.catalog.entry(entry.id)).weightedPlays }
        for _ in 0..<10 { try watch([(100, 110)]) }
        try watch([(0, 9.99)])
        XCTAssertEqual(try score(), 0.2 * 100 / 1800, accuracy: 1e-10)
        try f.catalog.setDuration(1800, for: entry)
        XCTAssertEqual(try score(), 100.0 / 1800, accuracy: 1e-10)

        try f.catalog.setDuration(3600, for: entry)
        let glances = try score()
        for _ in 0..<10 { try watch([(0, 1800)]) }
        XCTAssertEqual(try score() - glances, 6, accuracy: 1e-10)

        // Reordered, nested and duplicate intervals cover 600 seconds and play for 1200.
        let previous = try score()
        try watch([(1000, 1200), (0, 400), (50, 250), (0, 400)])
        XCTAssertEqual(try score() - previous, 0.8 * 600 / 3600 + 0.2 * 1200 / 1800, accuracy: 1e-10)

        try f.catalog.setDuration(600, for: entry)
        let beforeFullPlay = try score()
        try watch([(0, 600), (0, 600)])
        XCTAssertEqual(try score() - beforeFullPlay, 1, accuracy: 1e-10)
    }

    func testShortSessionsStayOutOfHistoryAndPreserveResume() throws {
        let fixture = try LibraryFixture()
        defer { fixture.clean() }
        try fixture.add("Session.mp4")
        try fixture.scan()
        let catalog = fixture.catalog
        let id = try XCTUnwrap(catalog.entries(libraryID: fixture.library.id).first).id
        func open() -> PlaybackHistory {
            PlaybackHistory(begin: { try catalog.beginSession(entryID: id) },
                            append: { try catalog.recordInterval(sessionID: $0, start: $1, end: $2) },
                            resume: { try catalog.setResume(entryID: id, seconds: $0) })
        }

        for _ in 0..<2 {
            let glance = open()
            try glance.sample(position: 100, playing: true, clock: 0)
            try glance.sample(position: 109.99, playing: false, clock: 10)
        }
        XCTAssertEqual(try catalog.entry(id)?.playCount, 0)
        XCTAssertEqual(try catalog.entry(id)?.resume, 0)
        XCTAssertEqual(try catalog.playbackStats(entryID: id).segments, [])

        let session = open()
        try session.sample(position: 0, playing: true, clock: 0)
        try session.sample(position: 6, playing: false, clock: 6)
        try session.jumped(to: 80, playing: true, clock: 60)
        XCTAssertEqual(try catalog.entry(id)?.resume, 0)
        try session.sample(position: 84, playing: false, clock: 64)

        let glance = open()
        try glance.sample(position: 0, playing: true, clock: 0)
        try glance.sample(position: 3, playing: false, clock: 3)
        let entry = try XCTUnwrap(catalog.entry(id))
        let stats = try catalog.playbackStats(entryID: id)
        XCTAssertEqual(entry.resume, 84)
        XCTAssertEqual(entry.playCount, 1)
        XCTAssertEqual(entry.watchTime, 10)
        XCTAssertEqual(stats.playCount, entry.playCount)
        XCTAssertEqual(stats.watchTime, entry.watchTime)
        XCTAssertEqual(stats.segments, [.init(start: 0, end: 6, passes: 1), .init(start: 80, end: 84, passes: 1)])
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
                    INSERT INTO entry(id,libraryID,path,fileSize,modified,resume) VALUES
                        (2,1,'/Short.mp4',100,0,400), (3,1,'/Revisited.mp4',100,0,3);
                    UPDATE entry SET resume = 25 WHERE id = 1;
                    INSERT INTO session(id,entryID) VALUES (1,1),(2,2),(3,3),(4,3);
                    INSERT INTO interval(sessionID,start,end) VALUES (2,397,400),(3,100,110),(3,1,2),(4,0,3);
                    INSERT INTO interval(sessionID,start,end) VALUES (1,10,20);
                    """)
            }
        }
        let upgraded = try Catalog(path: path)
        XCTAssertEqual(try upgraded.libraries().map(\.name), ["Legacy library"])
        XCTAssertEqual(try upgraded.entry(1)?.rating, 1)
        XCTAssertEqual(try upgraded.entry(1)?.resume, 25)
        XCTAssertEqual(try upgraded.entry(2)?.resume, 0)
        XCTAssertEqual(try upgraded.entry(3)?.resume, 2)
        XCTAssertEqual(try upgraded.playbackStats(entryID: 3).watchTime, 11)
        XCTAssertEqual(try upgraded.playbackStats(entryID: 1).watchTime, 10)
    }
}
