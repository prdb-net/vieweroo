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
