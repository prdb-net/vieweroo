import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Read presentation samples without creating a playback session. A sample cursor
/// also steps correctly when adjacent frames have different durations.
public struct TagFrameReader: Sendable {
    public struct Frame: Sendable {
        public let image: Data
        public let time: CMTime
    }

    private let asset: AVURLAsset
    public let duration: Double

    public init(url: URL) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw PreviewError.unsupportedVideo }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw PreviewError.unsupportedVideo }
        self.asset = asset
        self.duration = duration
    }

    public func frame(at time: CMTime, step: Int64 = 0) async throws -> Frame {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw PreviewError.unsupportedVideo }
        let scale = try await track.load(.naturalTimeScale)
        let timestamp = CMTimeConvertScale(time, timescale: scale, method: .roundHalfAwayFromZero)
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: timestamp) else { throw PreviewError.unsupportedVideo }
        if step != 0 { cursor.stepInPresentationOrder(byCount: step) }
        try Task.checkCancellation()
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let result = try await generator.image(at: cursor.presentationTimeStamp)
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PreviewError.cannotWriteImage
        }
        CGImageDestinationAddImage(destination, result.image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PreviewError.cannotWriteImage }
        return Frame(image: data as Data, time: result.actualTime)
    }
}
