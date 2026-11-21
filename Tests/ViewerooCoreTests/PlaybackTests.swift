import AVFoundation
import Foundation
import Testing
@testable import ViewerooApp
import ViewerooCore

@Test func seeksPausesAndLoopsCountOnlyPlayedIntervals() throws {
    var sessions = 0
    var intervals: [ClosedRange<Double>] = []
    var lastPosition: Double?
    let history = PlaybackHistory(begin: { sessions += 1; return 1 }, append: { id, start, end in
        #expect(id == 1)
        intervals.append(start...end)
    }, resume: { lastPosition = $0 })
    try history.sample(position: 0, playing: false, clock: 0)
    #expect(sessions == 0)
    try history.sample(position: 0, playing: true, clock: 1)
    try history.sample(position: 60, playing: false, clock: 61)
    try history.jumped(to: 600, playing: true, clock: 101)
    try history.sample(position: 660, playing: false, clock: 161)
    try history.jumped(to: 600, playing: true, clock: 165)
    try history.sample(position: 660, playing: false, clock: 225)
    #expect(sessions == 1)
    #expect(intervals == [0...60, 600...660, 600...660])
    #expect(lastPosition == 660)
}

@Test func anUnexpectedClockJumpDoesNotCreditSkippedTime() throws {
    var watched = 0.0
    let history = PlaybackHistory(begin: { 1 }, append: { _, start, end in watched += end - start }, resume: { _ in })
    try history.sample(position: 3, playing: true, clock: 0)
    try history.sample(position: 4, playing: true, clock: 1)
    try history.sample(position: 100, playing: true, clock: 2)
    try history.sample(position: 101, playing: false, clock: 3)
    #expect(watched == 2)
}

@MainActor
@Test func syntheticMovieGetsCachedFramesPlaysLoopsAndStops() async throws {
    let fm = FileManager.default
    let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temporary) }
    let movie = temporary.appendingPathComponent("Colors.MP4")
    try await writeColorMovie(to: movie)
    let cache = PreviewCache(root: temporary.appendingPathComponent("Thumbnails"))
    let directory = cache.directory(for: movie, size: 512, modificationDate: Date(timeIntervalSince1970: 0))
    try await cache.prepare(media: movie, directory: directory)
    let frames = PreviewCache.frames(in: directory)
    #expect(frames.count >= 3)
    #expect(frames.first?.time == 0)
    #expect(fm.fileExists(atPath: PreviewCache.posterURL(in: directory).path))
    let timestamp = try directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    try await cache.prepare(media: movie, directory: directory)
    let reusedTimestamp = try directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    #expect(timestamp == reusedTimestamp)
    let controller = PlayerController()
    var watched = 0.0
    var intervals: [ClosedRange<Double>] = []
    var sessions = 0
    let history = PlaybackHistory(begin: { sessions += 1; return 1 },
                                  append: { _, start, end in
                                      watched += end - start
                                      intervals.append(start...end)
                                  }, resume: { _ in })
    // A saved position at or beyond the end (including a shortened file) restarts playback.
    controller.open(url: movie, title: "Colors", startAt: 60, previewDirectory: directory, history: history)
    defer { controller.stop() }
    let deadline = ContinuousClock.now + .seconds(12)
    while controller.position < 0.4, controller.error == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(30))
    }
    #expect(controller.error == nil)
    #expect(controller.position >= 0.4)
    #expect(controller.player.allowsExternalPlayback)
    controller.markLoopStart()
    let loopStart = try #require(controller.loopStart)
    while controller.position < loopStart + 0.5, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(30))
    }
    controller.markLoopEnd()
    let loopEnd = try #require(controller.loopEnd)
    // Each consecutive pass should flush an interval covering the middle of the loop.
    let midpoint = (loopStart + loopEnd) / 2
    while intervals.filter({ $0.contains(midpoint) }).count < 3, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(30))
    }
    #expect(intervals.filter { $0.contains(midpoint) }.count >= 3)
    controller.stop()
    #expect(controller.player.currentItem == nil)
    #expect(controller.player.rate == 0)
    #expect(!controller.player.allowsExternalPlayback)
    #expect(controller.title.isEmpty)
    #expect(controller.previewDirectory == nil)
    #expect(sessions == 1)
    #expect(watched > 0)
}

@MainActor
@Test func unknownVideoCodecProducesNoPublishedCache() async throws {
    let fm = FileManager.default
    let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temporary) }
    let video = temporary.appendingPathComponent("Unknown-codec.mp4")
    try await writeColorMovie(to: video)
    var container = try Data(contentsOf: video)
    // Keep the MP4 container and timestamps intact but give its video sample entry an unknown codec.
    let description = try #require(container.range(of: Data("stsd".utf8)))
    let codecIndex = description.upperBound + 12
    try #require(container[codecIndex..<codecIndex + 4] == Data("avc1".utf8))
    container.replaceSubrange(codecIndex..<codecIndex + 4, with: Data("zzzz".utf8))
    try container.write(to: video)
    let cache = PreviewCache(root: temporary.appendingPathComponent("Thumbnails"))
    let directory = cache.directory(for: video, size: Int64(container.count), modificationDate: Date())
    await #expect(throws: PreviewError.unsupportedVideo) { try await cache.prepare(media: video, directory: directory) }
    #expect(PreviewCache.frames(in: directory).isEmpty)
}

@MainActor
func writeColorMovie(to url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 96, AVVideoHeightKey: 64,
    ])
    let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 96, kCVPixelBufferHeightKey as String: 64,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    let pool = try #require(adaptor.pixelBufferPool)
    for index in 0..<30 {
        let deadline = ContinuousClock.now + .seconds(4)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, ContinuousClock.now < deadline else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        var optionalBuffer: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer)
        try #require(result == kCVReturnSuccess)
        let buffer = try #require(optionalBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(index * 7), CVPixelBufferGetBytesPerRow(buffer) * 64)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    try #require(writer.status == .completed)
}
