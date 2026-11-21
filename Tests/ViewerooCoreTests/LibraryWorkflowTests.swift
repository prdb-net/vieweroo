import AppKit
import Foundation
import Testing
@testable import ViewerooApp
@testable import ViewerooCore

private actor WorkflowServer {
    enum Mode { case online, offline, rejected }
    var mode = Mode.online
    func setMode(_ value: Mode) { mode = value }

    func respond(to request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        if mode == .offline { throw URLError(.notConnectedToInternet) }
        let status = mode == .rejected ? 401 : 200
        let body: Any
        switch url.path {
        case "/user-identity":
            body = ["userHash": "fixture"]
        case "/sites":
            body = ["items": [], "totalCount": 0] as [String: Any]
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
    let libraryID = try #require(first.libraryID)
    first.addSources([source])
    try await until {
        guard let entry = first.entries.first else { return false }
        return !first.scanBusy && !entry.needsLookup && !PreviewCache.frames(in: first.previewDirectory(entry)).isEmpty
    }
    let entry = try #require(first.entries.first)
    #expect(entry.filename == "Colors.MP4")
    #expect(first.playback.player.currentItem == nil)
    first.change { catalog in
        try catalog.setFavorite(entryID: entry.id, value: true)
        try catalog.setRating(entryID: entry.id, value: 1)
    }
    first.shelf = .favorites
    first.detailID = entry.id
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
    #expect(first.libraryID == nil && first.detailID == nil)
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
    #expect(saved.playCount == 2 && saved.resume > 0.3)
    reopened.play(saved, at: saved.resume)
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
private func until(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(12)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
    try #require(condition(), "Timed out waiting for the workflow", sourceLocation: sourceLocation)
}
