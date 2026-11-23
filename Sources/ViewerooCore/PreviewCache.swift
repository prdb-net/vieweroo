import AVFoundation
import CryptoKit
import Darwin
import Foundation
import GRDB
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

    /// Consider only our own directories older than a day. Snapshot the cache before the
    /// catalog so newly published generations cannot become deletion candidates mid-run.
    package func removeOrphans(in catalog: Catalog) async throws {
        let files = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let children: [URL]
        do { children = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }

        let cutoff = Date.now.addingTimeInterval(-86_400)
        var generations: [URL] = []
        for child in children {
            try Task.checkCancellation()
            guard let info = try? child.resourceValues(forKeys: keys), info.isDirectory == true,
                  info.isSymbolicLink == false, let modified = info.contentModificationDate, modified < cutoff else { continue }
            let name = child.lastPathComponent
            if name.hasPrefix(".building-"), UUID(uuidString: String(name.dropFirst(".building-".count))) != nil {
                // A generation can take longer than a day on a stalled network drive.
                let descriptor = open(child.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK)
                guard descriptor >= 0 else { continue }
                defer { close(descriptor) }
                // One folder that cannot be removed must not stop the rest of the cleanup.
                try? files.removeItem(at: child)
            } else if name.utf8.count == 64, name.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                generations.append(child)
            }
        }
        guard !generations.isEmpty else { return }

        struct MediaSignature: FetchableRecord, Decodable, Sendable {
            let path: String
            let fileSize: Int64
            let modified: Double
        }
        let signatures = try await catalog.database.read { db in
            try MediaSignature.fetchAll(db, sql: "SELECT DISTINCT path, fileSize, modified FROM entry")
        }
        var unused = Set(generations.map(\.lastPathComponent))
        for signature in signatures {
            try Task.checkCancellation()
            let referenced = directory(for: URL(fileURLWithPath: signature.path, isDirectory: false),
                                       size: signature.fileSize, modificationDate: Date(timeIntervalSince1970: signature.modified))
            unused.remove(referenced.lastPathComponent)
        }
        for child in generations where unused.contains(child.lastPathComponent) {
            try Task.checkCancellation()
            try? files.removeItem(at: child)
        }
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
        let lock = open(staging.path, O_RDONLY | O_DIRECTORY | O_EXLOCK | O_NONBLOCK)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
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
