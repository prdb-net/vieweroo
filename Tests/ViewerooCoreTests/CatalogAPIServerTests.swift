import Foundation
import GRDB
import Testing
@testable import ViewerooCore

@Test func stoppingTheCatalogAPIDoesNotWaitForARunningRequest() async throws {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let server = try CatalogAPIServer(key: "fixture-key", port: 0) { _, _, _ in
        entered.signal()
        release.wait()
        return CatalogResponse(error: "200 OK", message: "late")
    }
    let port = try await withCheckedThrowingContinuation { continuation in
        let once = OnceFlag()
        server.start(state: { result in if once.claim() { continuation.resume(with: result) } }, changed: { _ in })
    }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/v1/libraries")), timeoutInterval: 5)
    request.setValue("Bearer fixture-key", forHTTPHeaderField: "Authorization")
    let response = Task { try await session.data(for: request) }
    try #require(await waitOff(entered))

    let clock = ContinuousClock()
    let elapsed = clock.measure { server.stop() }
    #expect(elapsed < .milliseconds(500))
    release.signal()
    await #expect(throws: (any Error).self) { _ = try await response.value }
}

@Test func catalogHashLookupFindsExistingFilesAndPagesDuplicateMatches() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: "catalog.sqlite").path
    do {
        let old = try DatabaseQueue(path: path)
        try Catalog.migrator.migrate(old, upTo: "catalog-state-v21")
        try await old.write { db in
            try db.execute(sql: """
                INSERT INTO library(id, name) VALUES (1, 'First'), (2, 'Second');
                INSERT INTO entry(id, libraryID, path, fileSize, modified, hash) VALUES
                    (1, 1, '/sample/a.mov', 131072, 0, '000000000001ffff'),
                    (2, 1, '/sample/b.mov', 131073, 0, '000000000001ffff'),
                    (3, 1, '/sample/c.mov', 131072, 0, '0000000000020000'),
                    (4, 1, '/sample/d.mov', 131072, 0, NULL),
                    (5, 1, '/sample/e.mov', 131072, 0, '000000000001ffff'),
                    (6, 2, '/sample/a.mov', 131072, 0, '000000000001ffff')
                """)
        }
    }
    let catalog = try Catalog(path: path)
    let server = try CatalogAPIServer(catalog: catalog, key: "fixture-key", port: 0)
    defer { server.stop() }
    let port = try await withCheckedThrowingContinuation { continuation in
        let once = OnceFlag()
        server.start(state: { result in if once.claim() { continuation.resume(with: result) } }, changed: { _ in })
    }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    func get(_ query: String, library: Int = 1) async throws -> (Int, Data) {
        let target = "http://127.0.0.1:\(port)/v1/libraries/\(library)/entries?\(query)"
        var request = URLRequest(url: try #require(URL(string: target)), timeoutInterval: 5)
        request.setValue("Bearer fixture-key", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        return (try #require(response as? HTTPURLResponse).statusCode, data)
    }
    struct Page: Decodable {
        struct Entry: Decodable { let id: Int64; let osHash: String; let fileSize: Int64 }
        let entries: [Entry]
        let nextAfter: Int64?
    }
    func page(_ query: String) async throws -> Page {
        let (status, data) = try await get(query)
        #expect(status == 200)
        return try JSONDecoder().decode(Page.self, from: data)
    }
    let hash = "osHash=000000000001FFFF"
    #expect(try await page(hash).entries.map(\.id) == [1, 2, 5])
    let query = hash + "&fileSize=131072&limit=1"
    let first = try await page(query)
    #expect(first.entries.map(\.id) == [1])
    let cursor = try #require(first.nextAfter)
    let last = try await page(query + "&after=\(cursor)")
    #expect(last.entries.map(\.id) == [5] && last.nextAfter == nil)
    let match = try #require(last.entries.first)
    #expect(match.osHash == "000000000001ffff" && match.fileSize == 131072)
    #expect(try await page(hash + "&fileSize=131074").entries.isEmpty)
    #expect(try await page("osHash=ffffffffffffffff").entries.isEmpty)
    #expect(try await get(hash, library: 99).0 == 404)
    for invalid in ["osHash=", "osHash=abc", "osHash=000000000001fffG", hash + "&" + hash,
                    hash + "&fileSize=-1", hash + "&fileSize=1.5", "fileSize=131072"] {
        #expect(try await get(invalid).0 == 400)
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}

/// Wait for a semaphore on a GCD thread rather than in the async context.
private func waitOff(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success) }
    }
}
