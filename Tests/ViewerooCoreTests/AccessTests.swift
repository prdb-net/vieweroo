import Foundation
import Testing
@testable import ViewerooCore

@MainActor
private final class VolatileStore: SecretStore {
    var items: [String: Data] = [:]
    func read(_ account: String) throws -> Data? { items[account] }
    func write(_ data: Data?, account: String) throws { items[account] = data }
}

@MainActor
struct AccessTests {
    @Test func validationPersistsAcrossRelaunchAndOnlyExplicitRejectionClearsTheKey() async throws {
        let store = VolatileStore()
        func launch() -> AccessController { AccessController(store: store, authenticate: { false }) }
        func server(_ status: Int) -> PRDBClient {
            PRDBClient { request in
                #expect(request.url?.path == "/user-identity")
                return (Data(#"{"userHash":"synthetic"}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
        let offline = PRDBClient { _ in throw URLError(.timedOut) }
        let access = launch()
        await #expect(throws: URLError.self) { try await access.validateAndStore(key: "key", client: offline) }
        #expect(try access.apiKey() == nil)
        try await access.validateAndStore(key: " first ", client: server(200))
        let restarted = launch()
        #expect(try restarted.apiKey() == "first")
        await #expect(throws: URLError.self) { try await restarted.validateAndStore(key: "first", client: offline) }
        await #expect(throws: PRDBError.rateLimited(retryAfter: nil)) {
            try await restarted.validateAndStore(key: "first", client: server(429))
        }
        #expect(try restarted.apiKey() == "first")
        await #expect(throws: PRDBError.invalidKey) {
            try await restarted.validateAndStore(key: "replacement", client: server(401))
        }
        #expect(try restarted.apiKey() == "first")
        try await restarted.validateAndStore(key: "updated", client: server(200))
        try restarted.reject(key: "first")
        #expect(try restarted.apiKey() == "updated")
        await #expect(throws: PRDBError.invalidKey) {
            try await restarted.validateAndStore(key: "updated", client: server(401))
        }
        #expect(try launch().apiKey() == nil)
    }

    @Test func pinChangeRemovalAndAuthenticatedRecovery() async throws {
        let store = VolatileStore()
        let first = AccessController(store: store, authenticate: { false })
        #expect(try !first.hasPIN)
        #expect(throws: AccessError.self) { try first.setPIN(current: nil, new: "abc") }
        try first.setPIN(current: nil, new: "0000")
        let denied = AccessController(store: store, authenticate: { throw CancellationError() })
        #expect(try denied.hasPIN)
        try denied.unlock(pin: "0000")
        #expect(throws: AccessError.self) { try denied.setPIN(current: "7777", new: nil) }
        #expect(throws: AccessError.self) { try denied.unlock(pin: "7777") }
        await #expect(throws: AccessError.self) { try await denied.recoverPIN(new: "1234") }
        try denied.unlock(pin: "0000")
        let allowed = AccessController(store: store, authenticate: { true })
        try await allowed.recoverPIN(new: "1234")
        #expect(throws: AccessError.self) { try denied.unlock(pin: "0000") }
        try allowed.setPIN(current: "1234", new: "5678")
        try allowed.unlock(pin: "5678")
        try allowed.setPIN(current: "5678", new: nil)
        #expect(try !allowed.hasPIN)
    }
}

@MainActor
private final class MigrationFixture: LegacyCredentials {
    let old = VolatileStore()
    var deniedRead: String?
    var deniedRemoval: String?
    var reads = 0
    var removals = 0

    func read(_ account: String) throws -> Data? {
        reads += 1
        if account == deniedRead { throw CancellationError() }
        return try old.read(account)
    }
    func remove(_ account: String) throws {
        removals += 1
        if account == deniedRemoval { throw CancellationError() }
        try old.write(nil, account: account)
    }
}

extension AccessTests {
    @Test func legacyAccessMigrationSurvivesDeniedReadsAndInterruptedCleanup() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try Catalog(path: directory.appending(path: "Catalog.sqlite").path)
        let legacy = MigrationFixture()
        try legacy.old.write(Data("fixture-key".utf8), account: AccessController.keyAccount)
        try AccessController(store: legacy.old).setPIN(current: nil, new: "4826")
        func launch() -> AccessController {
            AccessController(store: SettingsStore(directory: directory, legacy: legacy))
        }

        legacy.deniedRead = AccessController.keyAccount
        #expect(throws: CancellationError.self) { try launch().hasPIN }
        #expect(legacy.old.items.count == 2 && legacy.removals == 0)
        legacy.deniedRead = nil
        legacy.deniedRemoval = AccessController.pinAccount
        #expect(throws: CancellationError.self) { try launch().apiKey() }
        let readsAtCommit = legacy.reads
        legacy.deniedRemoval = nil
        let access = launch()
        #expect(try access.hasPIN)
        #expect(try access.apiKey() == "fixture-key")
        #expect(throws: AccessError.self) { try access.unlock(pin: "0000") }
        try access.unlock(pin: "4826")
        #expect(legacy.old.items.isEmpty && legacy.reads == readsAtCommit)
        let removals = legacy.removals
        try access.setPIN(current: "4826", new: "2109")
        try launch().unlock(pin: "2109")
        try access.reject(key: "fixture-key")
        #expect(try launch().apiKey() == nil)
        #expect(legacy.removals == removals && legacy.reads == readsAtCommit)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "Settings.sqlite").path)
        #expect(permissions[.posixPermissions] as? Int == 0o600)
    }

    @Test func freshSQLiteSettingsDoNotUseTheKeychain() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = MigrationFixture()
        func launch() -> AccessController {
            AccessController(store: SettingsStore(directory: directory, legacy: legacy))
        }
        let access = launch()
        #expect(try !access.hasPIN && access.apiKey() == nil)
        let client = PRDBClient { request in
            (Data(#"{"userHash":"synthetic"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try await access.validateAndStore(key: "test-only", client: client)
        _ = try Catalog(path: directory.appending(path: "Catalog.sqlite").path)
        #expect(try launch().apiKey() == "test-only")
        #expect(legacy.reads == 0 && legacy.removals == 0)
    }
}
