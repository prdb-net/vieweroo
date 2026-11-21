import AppKit
import Foundation
import Testing
@testable import ViewerooApp
@testable import ViewerooCore

private actor WorkflowServer {
    enum Mode { case online, offline, rejected, subscriptionRequired }
    var mode = Mode.online
    func setMode(_ value: Mode) { mode = value }

    func respond(to request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        if mode == .offline { throw URLError(.notConnectedToInternet) }
        let restricted = mode == .subscriptionRequired && url.path == "/videos/identify"
            && request.value(forHTTPHeaderField: "X-Api-Key") == "expired-subscription"
        let status = mode == .rejected ? 401 : restricted ? 403 : 200
        let body: Any
        switch url.path {
        case "/user-identity":
            body = ["userHash": "fixture"]
        case "/sites":
            let sites = mode == .subscriptionRequired ? [["id": "studio", "title": "Sky Studio"]] : []
            body = ["items": sites, "totalCount": sites.count] as [String: Any]
        case "/videos/identify":
            let bytes = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let files = try #require(json["files"] as? [[String: Any]])
            body = ["results": try files.map {
                ["ref": try #require($0["ref"] as? String), "confidence": 0, "candidates": []] as [String: Any]
            }]
        case "/videos":
            body = ["items": []]
        default:
            Issue.record("Unexpected local fixture request for \(url.path)")
            throw URLError(.unsupportedURL)
        }
        return (try JSONSerialization.data(withJSONObject: body),
                try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }
}

@MainActor
private final class WorkflowSecrets: SecretStore {
    var items: [String: Data] = [:]
    func read(_ account: String) throws -> Data? { items[account] }
    func write(_ data: Data?, account: String) throws { items[account] = data }
}

@MainActor
@Test func firstImportRecognizesLocalStudiosAndRecoversFromASubscriptionError() async throws {
    let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let folder = temporary.appending(path: "Sky Studio")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try await writeColorMovie(to: folder.appending(path: "Morning.mp4"))
    let suite = "vieweroo.subscription." + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let server = WorkflowServer()
    await server.setMode(.subscriptionRequired)
    let model = LibraryModel(access: AccessController(store: WorkflowSecrets(), authenticate: { false }),
                             client: PRDBClient { try await server.respond(to: $0) },
                             preferences: preferences, directory: temporary.appending(path: "Support"),
                             cache: PreviewCache(root: temporary.appending(path: "Cache")))
    model.start()
    try await model.configure(key: "expired-subscription")
    model.createLibrary("Movies")
    model.addSources([folder])
    try await until { model.subscriptionRequired && model.entries.first?.studio == "Sky Studio" }
    let entry = try #require(model.entries.first)
    #expect(model.phase == .ready && entry.needsLookup && entry.availability == .available)
    #expect(model.networkStatus == PRDBError.subscriptionRequired.localizedDescription)
    model.openDetail(entry.id)
    #expect(model.change { try $0.setFavorite(entryID: entry.id, value: true) })

    model.retrySubscription()
    try await until { model.subscriptionRequired }
    await server.setMode(.online)
    model.retrySubscription()
    try await until { model.entries.first?.needsLookup == false }
    #expect(try model.access.apiKey() == "expired-subscription")

    await server.setMode(.subscriptionRequired)
    try FileManager.default.copyItem(at: entry.url, to: folder.appending(path: "Evening.mp4"))
    model.refresh()
    try await until { model.subscriptionRequired && model.entries.count == 2 }
    await server.setMode(.offline)
    await #expect(throws: URLError.self) { try await model.replacePRDBKey("new-subscription") }
    #expect(try model.access.apiKey() == "expired-subscription")
    await server.setMode(.subscriptionRequired)
    try await model.replacePRDBKey("new-subscription")
    try await until { !model.entries.contains(where: \.needsLookup) }
    model.handleNetwork(PRDBError.subscriptionRequired, key: "expired-subscription")
    model.handleNetwork(PRDBError.invalidKey, key: "expired-subscription")
    #expect(model.phase == .ready)
    #expect(try model.access.apiKey() == "new-subscription")
    #expect(!model.subscriptionRequired && model.networkStatus == nil)
    #expect(model.detailID == entry.id && model.entries.contains { $0.id == entry.id && $0.favorite })
}

@MainActor
@Test func changingLibrariesOrLockingDiscardsAKeyVerificationInFlight() async throws {
    _ = NSApplication.shared
    let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let suite = "vieweroo.key-verification." + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let server = WorkflowServer()
    let (requests, started) = AsyncStream<Void>.makeStream()
    let (responses, complete) = AsyncStream<Void>.makeStream()
    let client = PRDBClient { request in
        if request.value(forHTTPHeaderField: "X-Api-Key") == "delayed-key" {
            started.yield()
            for await _ in responses { break }
        }
        return try await server.respond(to: request)
    }
    let model = LibraryModel(access: AccessController(store: WorkflowSecrets(), authenticate: { false }),
                             client: client, preferences: preferences, directory: temporary,
                             cache: PreviewCache(root: temporary.appending(path: "Cache")))
    model.start()
    try await model.configure(key: "saved-key")
    model.createLibrary("Original")
    let catalog = try #require(model.catalog)
    let other = try catalog.createLibrary(name: "Other")
    try model.access.setPIN(current: nil, new: "1234")
    model.pinEnabled = true
    var signals = requests.makeAsyncIterator()
    for lock in [false, true] {
        let verification = Task { try await model.replacePRDBKey("delayed-key") }
        _ = await signals.next()
        if lock { model.lock() } else { model.selectLibrary(other.id) }
        complete.yield()
        await #expect(throws: CancellationError.self) { try await verification.value }
        #expect(try model.access.apiKey() == "saved-key")
        #expect(model.phase == (lock ? .locked : .ready))
    }
    complete.finish()
    started.finish()
}

@MainActor
@Test func firstImportOfflineRelaunchAndAccessGates() async throws {
    // AppKit supplies the window list used to dismiss panels and sheets at lock time.
    _ = NSApplication.shared
    let fm = FileManager.default
    let suite = "vieweroo.workflow.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = temporary.appendingPathComponent("Synthetic Source")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temporary) }
    let movie = source.appendingPathComponent("Colors.MP4")
    try await writeColorMovie(to: movie)
    let secrets = WorkflowSecrets()
    let server = WorkflowServer()
    func launch() -> LibraryModel {
        LibraryModel(access: AccessController(store: secrets, authenticate: { false }),
                     client: PRDBClient { try await server.respond(to: $0) },
                     preferences: preferences, directory: temporary.appendingPathComponent("Support"),
                     cache: PreviewCache(root: temporary.appendingPathComponent("Cache")))
    }
    let first = launch()
    first.start()
    #expect(first.phase == .setup)
    #expect(first.catalog == nil)
    try await first.configure(key: "fixture-access")
    #expect(first.phase == .ready)
    first.createLibrary("Synthetic Collection")
    #expect(first.notice?.text == "Library created")
    let libraryID = try #require(first.libraryID)
    first.addSources([source])
    try await until {
        guard let entry = first.entries.first else { return false }
        return !first.scanBusy && !entry.needsLookup && !PreviewCache.frames(in: first.previewDirectory(entry)).isEmpty
    }
    let entry = try #require(first.entries.first)
    #expect(entry.filename == "Colors.MP4")
    #expect(first.playback.player.currentItem == nil)
    first.change("Added to Favorites", kind: .favorite) { catalog in
        try catalog.setFavorite(entryID: entry.id, value: true)
        try catalog.setRating(entryID: entry.id, value: 1)
    }
    #expect(first.notice?.kind == .favorite)
    let confirmationID = first.notice?.id
    let reordered = first.change("Playlist order saved") { _ in throw CatalogError.invalidPlaylistOrder }
    #expect(!reordered && first.notice?.kind == .error && first.notice?.id != confirmationID)
    var formError: String?
    let previousNoticeID = first.notice?.id
    let formSaved = first.change("Title match saved", onFailure: { formError = $0 }) { _ in
        throw CatalogError.invalidValue
    }
    #expect(!formSaved && formError == CatalogError.invalidValue.localizedDescription)
    #expect(first.notice?.id == previousNoticeID)
    first.browse(.favorites)
    first.openDetail(entry.id)
    first.play(entry, at: 0)
    try await until { first.playback.position > 0.3 }
    first.endPlayback()
    #expect(first.shelf == .favorites)
    #expect(first.detailID == entry.id)
    try first.access.setPIN(current: nil, new: "0000")
    first.pinEnabled = true
    first.play(entry, at: 0)
    try await until { first.playback.position > 0.3 }
    first.lock()
    #expect(first.phase == .locked && first.entries.isEmpty && first.playlists.isEmpty)
    #expect(first.notice == nil)
    #expect(first.libraryID == nil && first.detailID == nil && !first.canGoBack)
    #expect(first.playback.player.currentItem == nil && !first.playback.player.allowsExternalPlayback)

    await server.setMode(.offline)
    let reopened = launch()
    reopened.start()
    #expect(reopened.phase == .locked && reopened.catalog == nil)
    #expect(throws: AccessError.self) { try reopened.unlock(pin: "1111") }
    #expect(reopened.phase == .locked)
    try reopened.unlock(pin: "0000")
    try await until { reopened.networkStatus != nil }
    #expect(reopened.phase == .ready && reopened.libraryID == libraryID)
    #expect(reopened.shelf == .studios)
    let saved = try #require(reopened.entries.first)
    #expect(saved.id == entry.id && saved.favorite && saved.rating == 1)
    #expect(saved.playCount == 0 && saved.resume == 0 && saved.watchTime == 0)
    reopened.play(saved)
    try await until { reopened.playback.position > saved.resume + 0.2 }
    await server.setMode(.rejected)
    reopened.refresh()
    try await until { reopened.phase == .locked }
    #expect(try reopened.access.apiKey() == nil)
    #expect(!reopened.playing && reopened.playback.player.currentItem == nil)
    #expect(reopened.entries.isEmpty && reopened.sources.isEmpty && reopened.libraries.isEmpty)
    try reopened.unlock(pin: "0000")
    #expect(reopened.phase == .setup && reopened.entries.isEmpty)
}

@MainActor
@Test func switchingSuggestionsResumesTheLatestPositionAndKeepsTheBrowsingContext() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = root.appendingPathComponent("Clips")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let firstURL = folder.appendingPathComponent("First.mp4")
    try await writeColorMovie(to: firstURL, seconds: 20)
    try fm.copyItem(at: firstURL, to: folder.appendingPathComponent("Second.mp4"))
    let suite = "vieweroo.suggestions.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let server = WorkflowServer()
    let model = LibraryModel(access: AccessController(store: WorkflowSecrets(), authenticate: { false }),
                             client: PRDBClient { try await server.respond(to: $0) },
                             preferences: preferences, directory: root.appendingPathComponent("Support"),
                             cache: PreviewCache(root: root.appendingPathComponent("Cache")))
    model.start()
    try await model.configure(key: "fixture-access")
    model.createLibrary("Clips")
    model.addSources([folder])
    try await until { model.entries.count == 2 && !model.scanBusy }
    let first = model.entries[0], second = model.entries[1]
    model.browse(.all)
    model.openDetail(first.id)
    model.play(first, at: 0)
    try await until(timeout: .seconds(20)) { model.playback.position > 10.5 }
    model.playSuggested(second)
    try await until { model.playback.title == second.title && model.playback.position > 0.15 }
    let saved = try #require(try model.catalog?.entry(first.id)?.resume)
    #expect(saved > 10.5)
    #expect(first.resume == 0)

    // The same old tile may still be visible when selected again.
    model.playSuggested(first)
    try await until { model.playback.playing && model.playback.title == first.title }
    #expect(model.playback.position >= saved - 0.05)
    model.endPlayback()
    #expect(model.shelf == .all && model.detailID == first.id)
    let watched = try #require(try model.catalog?.entry(first.id))
    #expect(watched.playCount == 1 && watched.duration == 20)
    #expect(abs(watched.weightedPlays - watched.watchTime / 20) < 0.001)
    #expect(try model.catalog?.entry(second.id)?.playCount == 0)
    // The detail and context menu can still hold the tile from before playback.
    model.play(first)
    try await until { model.playback.playing }
    #expect(model.playback.position >= saved - 0.05)
    model.endPlayback()
    model.play(first, at: 0)
    try await until { model.playback.playing }
    #expect(model.playback.position < 1)
    model.endPlayback()
    model.play(first, at: 3)
    try await until { model.playback.playing }
    #expect((2.95..<4).contains(model.playback.position))
    model.endPlayback()
    try model.access.setPIN(current: nil, new: "0000")
    model.pinEnabled = true
    model.lock()
    model.playSuggested(second)
    #expect(!model.hasAlternatives(to: first))
    #expect(model.playback.player.currentItem == nil)
}

@MainActor
private func until(timeout: Duration = .seconds(12), _ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
    try #require(condition(), "Timed out waiting for the workflow", sourceLocation: sourceLocation)
}

@MainActor
@Test func backRestoresVisitsAndSkipsDeletedDestinations() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "vieweroo.navigation." + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let server = WorkflowServer()
    let model = LibraryModel(access: AccessController(store: WorkflowSecrets(), authenticate: { false }),
                             client: PRDBClient { try await server.respond(to: $0) },
                             preferences: preferences, directory: root, cache: PreviewCache(root: root.appending(path: "Cache")))
    model.start()
    try await model.configure(key: "fixture-access")
    model.createLibrary("Clips")
    let catalog = try #require(model.catalog)
    let library = try #require(model.libraryID)
    let playlist = try catalog.createPlaylist(libraryID: library, name: "Saved")
    let folder = root.appending(path: "Media")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try await writeColorMovie(to: folder.appending(path: "First.mp4"))
    try FileManager.default.copyItem(at: folder.appending(path: "First.mp4"), to: folder.appending(path: "Second.mp4"))
    model.addSources([folder])
    try await until { model.entries.count == 2 && !model.scanBusy }
    let first = model.entries[0], second = model.entries[1]
    _ = try catalog.addToPlaylist(playlist.id, entryID: first.id)
    model.browse(.playlist(playlist.id))
    model.search("Fi")
    model.search("First")
    model.openDetail(first.id)
    let person = PRDBPerformer(id: "fixture", name: "Morgan Reed")
    model.browse(.performer(person), from: .performer(person.id))
    model.openDetail(second.id)

    model.goBack()
    #expect(model.shelf == .performer(person) && model.visit.selectedTile == .video(second.id))
    model.goBack()
    #expect(model.detailID == first.id && model.visit.selectedTile == .performer(person.id))
    model.goBack()
    #expect(model.query == "First" && model.detailID == nil && model.visit.selectedTile == .video(first.id))
    model.goBack()
    #expect(model.query.isEmpty && model.shelf == .playlist(playlist.id) && model.orderedIDs == [first.id])

    model.openDetail(first.id)
    model.browse(.favorites)
    try catalog.deleteEntry(first.id)
    await model.reload()?.value
    model.goBack()
    #expect(model.shelf == .playlist(playlist.id) && model.detailID == nil && model.orderedIDs.isEmpty)
    try catalog.deletePlaylist(playlist.id)
    await model.reload()?.value
    #expect(model.shelf == .studios && !model.canGoBack)
    model.browse(.liked)
    model.createLibrary("Another Library")
    #expect(model.libraryID != library && model.shelf == .studios && !model.canGoBack)
    let emptyLibrary = try #require(model.libraryID)
    model.selectLibrary(library)
    let previousLoad = model.reload()
    model.selectLibrary(emptyLibrary)
    let currentLoad = model.reload()
    await previousLoad?.value
    await currentLoad?.value
    #expect(!model.loadingLibrary && model.entries.isEmpty && model.sources.isEmpty)
    model.selectLibrary(library)
    let unlockedLoad = model.reload()
    try model.access.setPIN(current: nil, new: "1234")
    model.pinEnabled = true
    model.lock()
    await unlockedLoad?.value
    #expect(model.phase == .locked && model.entries.isEmpty && model.sources.isEmpty && model.libraries.isEmpty)
}

@MainActor
@Test func recentPlaylistsFollowNavigationAcrossLibrariesAndLaunches() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "vieweroo.recent-playlists." + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let access = AccessController(store: WorkflowSecrets(), authenticate: { false })
    let server = WorkflowServer()
    func launch() -> LibraryModel {
        let model = LibraryModel(access: access, client: PRDBClient { try await server.respond(to: $0) },
                                 preferences: preferences, directory: root, cache: PreviewCache(root: root.appending(path: "Cache")))
        model.start()
        return model
    }
    let model = launch()
    try await model.configure(key: "fixture-access")
    model.createLibrary("Archive")
    let catalog = try #require(model.catalog)
    let library = try #require(model.libraryID)
    let lists = try (1...20).map { try catalog.createPlaylist(libraryID: library, name: String(format: "List %02d", $0)) }
    await model.reload()?.value
    #expect(model.playlists == lists && model.recentPlaylists.isEmpty)
    for list in lists.prefix(7) {
        model.browse(.playlists)
        model.browse(.playlist(list.id), from: .playlist(list.id))
    }
    model.goBack()
    #expect(model.shelf == .playlists && model.visit.selectedTile == .playlist(lists[6].id))
    #expect(model.recentPlaylists.map(\.id) == lists[2...6].reversed().map(\.id))
    model.browse(.playlist(lists[3].id))
    #expect(model.recentPlaylists.map(\.id) == [3, 6, 5, 4, 2].map { lists[$0].id })
    try catalog.deletePlaylist(lists[3].id)
    await model.reload()?.value
    let remaining = [6, 5, 4, 2, 1].map { lists[$0].id }
    #expect(model.recentPlaylists.map(\.id) == remaining)
    model.createLibrary("Second")
    await model.reload()?.value
    #expect(model.playlists.isEmpty && model.recentPlaylists.isEmpty)
    let reopened = launch()
    reopened.selectLibrary(library)
    await reopened.reload()?.value
    #expect(reopened.playlists.count == 19 && reopened.recentPlaylists.map(\.id) == remaining)
}

@MainActor
@Test func previewActivityCountsCachedSetsSeparatelyFromFailuresAndRetries() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let media = root.appending(path: "Media")
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    let good = media.appending(path: "Colors.mp4"), bad = media.appending(path: "Incomplete.mov")
    try await writeColorMovie(to: good)
    try Data("Incomplete".utf8).write(to: bad)
    let suite = "vieweroo.activity." + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let server = WorkflowServer()
    let model = LibraryModel(access: AccessController(store: WorkflowSecrets(), authenticate: { false }),
                             client: PRDBClient { try await server.respond(to: $0) },
                             preferences: preferences, directory: root, cache: PreviewCache(root: root.appending(path: "Cache")))
    model.start()
    try await model.configure(key: "fixture")
    model.createLibrary("Archive")
    model.addSources([media])
    try await until { model.previews.total == 2 && model.previews.phase == .idle }
    #expect(model.previews.ready == 1 && model.previews.failures.first?.entry.url == bad)
    #expect(model.previews.remaining.isEmpty)
    let library = try #require(model.libraryID)
    model.createLibrary("Empty")
    #expect(model.previews.total == 0 && model.previews.failures.isEmpty)
    try FileManager.default.removeItem(at: bad)
    try FileManager.default.copyItem(at: good, to: bad)
    model.selectLibrary(library)
    model.refresh()
    try await until { !model.scanBusy && model.previews.ready == 2 && model.previews.phase == .idle }
    #expect(model.previews.failures.isEmpty)
    try model.access.setPIN(current: nil, new: "1234")
    model.pinEnabled = true
    model.lock()
    #expect(model.previews.total == 0 && model.previews.remaining.isEmpty && model.lookupActivity == nil)
}
