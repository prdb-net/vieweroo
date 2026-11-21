import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct PreviewFrame: Identifiable, Sendable {
    public let time: Double
    public let url: URL
    public var id: Double { time }
}

public enum PreviewError: LocalizedError {
    case unsupportedVideo
    case cannotWriteImage

    public static func isUnsupported(_ error: Error) -> Bool {
        let code = (error as? AVError)?.code
        return code == .fileFormatNotRecognized || code == .decoderNotFound || code == .decodeFailed || code == .formatUnsupported
    }

    public var errorDescription: String? {
        switch self {
        case .unsupportedVideo: "AVFoundation could not read a playable video track from this file."
        case .cannotWriteImage: "The preview image could not be saved."
        }
    }
}

/// A complete generation is published with one directory rename. Other processes
/// and the player can read the last complete generation without a file lock.
public struct PreviewCache: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public func directory(for media: URL, size: Int64, modificationDate: Date) -> URL {
        let signature = "\(media.standardizedFileURL.path)\u{0}\(size)\u{0}\(modificationDate.timeIntervalSince1970.bitPattern)"
        let digest = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest, isDirectory: true)
    }

    public static func posterURL(in directory: URL) -> URL {
        directory.appendingPathComponent("1.jpg")
    }

    public static func frames(in directory: URL) -> [PreviewFrame] {
        let manifest = directory.appendingPathComponent("times.json")
        guard let data = try? Data(contentsOf: manifest),
              let times = try? JSONDecoder().decode([Double].self, from: data),
              !times.isEmpty else { return [] }
        let frames = times.enumerated().map {
            PreviewFrame(time: $0.element, url: directory.appendingPathComponent("\($0.offset).jpg"))
        }
        return frames.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) } ? frames : []
    }

    @discardableResult
    public func prepare(media: URL, directory: URL) async throws -> Bool {
        if !Self.frames(in: directory).isEmpty { return false }
        do { try await generate(media: media, directory: directory) }
        catch where PreviewError.isUnsupported(error) { throw PreviewError.unsupportedVideo }
        return true
    }

    private func generate(media: URL, directory: URL) async throws {
        let asset = AVURLAsset(url: media)
        guard try await asset.load(.isPlayable),
              try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw PreviewError.unsupportedVideo
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw PreviewError.unsupportedVideo }
        let fm = FileManager.default
        let staging = root.appendingPathComponent(".building-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        let count = Int(min(48, max(3, ceil(duration / 15))))
        var times: [Double] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let time = duration * Double(index) / Double(count)
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60_000))
            let file = staging.appendingPathComponent("\(index).jpg")
            guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw PreviewError.cannotWriteImage
            }
            let options = [kCGImageDestinationLossyCompressionQuality: 0.74] as CFDictionary
            CGImageDestinationAddImage(destination, frame.image, options)
            guard CGImageDestinationFinalize(destination) else { throw PreviewError.cannotWriteImage }
            times.append(time)
        }
        try JSONEncoder().encode(times).write(to: staging.appendingPathComponent("times.json"))
        try Task.checkCancellation()
        // Old partial caches (for example after an interrupted manual copy) can be rebuilt.
        if fm.fileExists(atPath: directory.path) {
            if !Self.frames(in: directory).isEmpty { return }
            try fm.removeItem(at: directory)
        }
        do { try fm.moveItem(at: staging, to: directory) }
        catch { if Self.frames(in: directory).isEmpty { throw error } }
    }
}
