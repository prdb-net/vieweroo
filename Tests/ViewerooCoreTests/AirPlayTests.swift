import AVFoundation
import Foundation
import Network
import os
import Testing
@testable import ViewerooApp
import ViewerooCore

@Test func airPlayServesOnlyTheSelectedMovieAndHonorsByteRanges() async throws {
    let movie = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
    let bytes = Data((0..<700_000).map { UInt8(truncatingIfNeeded: $0) })
    try bytes.write(to: movie)
    defer { try? FileManager.default.removeItem(at: movie) }
    let server = try AirPlayMediaServer(movie: movie, host: "127.0.0.1")
    defer { server.stop() }
    let url = try await withCheckedThrowingContinuation { continuation in
        server.start { continuation.resume(with: $0) }
    }
    #expect(!url.path.contains(movie.deletingPathExtension().lastPathComponent))
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    func fetch(_ target: URL, method: String = "GET", range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: target, timeoutInterval: 4)
        request.httpMethod = method
        request.setValue(range, forHTTPHeaderField: "Range")
        let (body, response) = try await session.data(for: request)
        return (body, try #require(response as? HTTPURLResponse))
    }
    // Replacing the source path must not change the bytes behind a live URL.
    try Data("Replacement".utf8).write(to: movie, options: .atomic)
    let (all, response) = try await fetch(url)
    #expect(all == bytes && response.statusCode == 200)
    #expect(response.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
    let (empty, head) = try await fetch(url, method: "HEAD")
    #expect(empty.isEmpty && head.expectedContentLength == Int64(bytes.count))
    for (range, slice) in [("bytes=0-1", 0..<2), ("bytes=262144-300000", 262144..<300001),
                           ("bytes=-10", 699990..<700000), ("bytes=699998-", 699998..<700000),
                           ("bytes=699999-18446744073709551615", 699999..<700000)] {
        let (body, partial) = try await fetch(url, range: range)
        #expect(partial.statusCode == 206)
        #expect(body == bytes[slice])
        #expect(partial.value(forHTTPHeaderField: "Content-Range") == "bytes \(slice.lowerBound)-\(slice.upperBound - 1)/700000")
    }
    for range in ["bytes=700000-", "bytes=3-2", "bytes=-0", "bytes=0-1,3-4"] {
        let (body, invalid) = try await fetch(url, range: range)
        #expect(invalid.statusCode == 416 && body.isEmpty)
    }
    let (_, denied) = try await fetch(url.deletingLastPathComponent())
    #expect(denied.statusCode == 404)
    let (_, write) = try await fetch(url, method: "POST")
    #expect(write.statusCode == 405)
    server.stop()
    await #expect(throws: URLError.self) { _ = try await fetch(url) }
}

@MainActor
@Test func airPlayRejectionSwitchesThePlayingItemToHTTPAndStopRevokesIt() async throws {
    let movie = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
    try await writeColorMovie(to: movie, seconds: 12)
    defer { try? FileManager.default.removeItem(at: movie) }
    var sessions = 0
    let history = PlaybackHistory(begin: { sessions += 1; return 1 }, append: { _, _, _ in }, resume: { _ in })
    let controller = PlayerController { try AirPlayMediaServer(movie: $0, host: "127.0.0.1") }
    controller.open(url: movie, title: "Colors", startAt: 3, previewDirectory: movie.deletingLastPathComponent(), history: history)
    defer { controller.stop() }
    try await waitUntil { controller.position > 3.3 && sessions == 1 }
    let nativeItem = try #require(controller.player.currentItem)
    let previous = controller.position
    controller.markLoopStart()
    let rejection = NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue, userInfo: [
        NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -17226),
    ])
    NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: nativeItem,
                                    userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: rejection])
    try await waitUntil { controller.player.currentItem !== nativeItem && controller.position > previous + 0.4 }
    let streamed = try #require((controller.player.currentItem?.asset as? AVURLAsset)?.url)
    #expect(streamed.scheme == "http" && controller.error == nil)
    #expect(controller.loopStart == previous && sessions == 1)
    controller.seek(to: 9, resume: true)
    try await waitUntil { controller.position > 9.3 }
    // Exercise the underlying player's transport, as the receiver can do.
    controller.player.pause()
    try await waitUntil { !controller.wantsPlayback && !controller.playing }
    controller.seek(to: 7)
    try await waitUntil { abs(controller.player.currentTime().seconds - 7) < 0.05 }
    #expect(!controller.wantsPlayback)
    controller.togglePlayback()
    try await waitUntil { controller.playing && controller.position > 7.1 }
    controller.togglePlayback()
    controller.player.play()
    try await waitUntil { controller.wantsPlayback && controller.playing }
    controller.seek(to: 4)
    controller.player.pause()
    try await waitUntil {
        !controller.wantsPlayback && !controller.playing && abs(controller.player.currentTime().seconds - 4) < 0.05
    }
    controller.externalPlaybackDidEnd()
    try await waitUntil { controller.player.currentItem?.status == .readyToPlay && !controller.waiting }
    #expect((controller.player.currentItem?.asset as? AVURLAsset)?.url == movie)
    #expect(!controller.wantsPlayback && controller.player.rate == 0 && sessions == 1)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    await #expect(throws: URLError.self) { _ = try await session.data(from: streamed) }
    let restored = try #require(controller.player.currentItem)
    NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: restored,
                                    userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: rejection])
    try await waitUntil { controller.player.currentItem !== restored && !controller.waiting }
    let nextURL = try #require((controller.player.currentItem?.asset as? AVURLAsset)?.url)
    #expect(nextURL.scheme == "http" && nextURL.path != streamed.path)
    controller.stop()
    await #expect(throws: URLError.self) { _ = try await session.data(from: nextURL) }
}

@MainActor
@Test func airPlayFallbackReportsListenerFailure() async throws {
    let movie = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
    try await writeColorMovie(to: movie, seconds: 2)
    defer { try? FileManager.default.removeItem(at: movie) }
    let controller = PlayerController { _ in
        throw NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue,
                      userInfo: [NSLocalizedDescriptionKey: "Synthetic listener failure detail"])
    }
    let history = PlaybackHistory(begin: { 1 }, append: { _, _, _ in }, resume: { _ in })
    controller.open(url: movie, title: "Colors", startAt: 0, previewDirectory: movie.deletingLastPathComponent(), history: history)
    defer { controller.stop() }
    try await waitUntil { controller.ready }
    let item = try #require(controller.player.currentItem)
    let rejection = NSError(domain: AVFoundationErrorDomain, code: AVError.externalPlaybackNotSupportedForAsset.rawValue)
    NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: item,
                                    userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: rejection])
    try await waitUntil { controller.error?.contains("Synthetic listener failure detail") == true }
    #expect(!controller.waiting && !controller.wantsPlayback)
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(30)) }
    try #require(condition())
}

@Test func airPlayClosesATransferWhoseReceiverStopsReading() async throws {
    let movie = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
    let size = 64 << 20
    try Data(count: size).write(to: movie)
    defer { try? FileManager.default.removeItem(at: movie) }
    let server = try AirPlayMediaServer(movie: movie, host: "127.0.0.1", stallTimeout: 0.3)
    defer { server.stop() }
    let url = try await withCheckedThrowingContinuation { continuation in
        server.start { continuation.resume(with: $0) }
    }
    let port = try #require(url.port.flatMap { NWEndpoint.Port(rawValue: UInt16($0)) })
    let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    let queue = DispatchQueue(label: "airplay-stall-test")
    defer { client.cancel() }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let resumed = OSAllocatedUnfairLock(initialState: false)
        client.stateUpdateHandler = { state in
            let result: Result<Void, Error>?
            switch state {
            case .ready: result = .success(())
            case .failed(let error): result = .failure(error)
            default: result = nil
            }
            guard let result, resumed.withLock({ defer { $0 = true }; return !$0 }) else { return }
            continuation.resume(with: result)
        }
        client.start(queue: queue)
    }
    client.send(content: Data("GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8), completion: .idempotent)
    // Leave the response unread until the socket buffers fill and the server gives up.
    try await Task.sleep(for: .seconds(1.5))
    var received = 0
    var closed = false
    while !closed {
        let (count, complete) = await withCheckedContinuation { continuation in
            client.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                continuation.resume(returning: (data?.count ?? 0, complete || error != nil))
            }
        }
        received += count
        closed = complete || count == 0
    }
    #expect(received < size, "The server must close the stalled transfer instead of sending the whole movie")
}
