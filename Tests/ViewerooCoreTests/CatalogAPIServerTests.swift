import Foundation
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
