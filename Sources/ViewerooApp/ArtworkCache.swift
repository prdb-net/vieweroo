import AppKit
import ImageIO

/// Decoded images at tile size, by their source. Tiles leave and re-enter the lazy grid
/// while scrolling. Reading a still from disk again showed the placeholder for a moment,
/// and PRDB previews or imported posters were decoded at their full size for a small tile.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    /// The widest tile is 320 pt, drawn at two pixels per point.
    static let tilePixels = 640
    private let images = NSCache<NSString, NSImage>()

    init() {
        // Decoded bytes. About 370 stills of 480 × 270 pixels.
        images.totalCostLimit = 192 << 20
    }

    func image(_ key: String) -> NSImage? { images.object(forKey: key as NSString) }

    func remove(_ key: String) { images.removeObject(forKey: key as NSString) }

    /// Locking conceals the library. Decoded artwork must not stay behind in memory.
    func removeAll() { images.removeAllObjects() }

    /// Return the cached image, or read and decode it off the main thread.
    func load(_ key: String, pixels: Int = tilePixels, data: @escaping @Sendable () async -> Data?) async -> NSImage? {
        if let cached = image(key) { return cached }
        let decoded = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let bytes = await data(), !Task.isCancelled else { return nil }
            return Self.downsample(bytes, pixels: pixels)
        }.value
        guard let decoded else { return nil }
        let image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
        images.setObject(image, forKey: key as NSString, cost: decoded.bytesPerRow * decoded.height)
        return image
    }

    /// Decode at most `pixels` on the longer side. A smaller image keeps its size.
    nonisolated static func downsample(_ data: Data, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ] as CFDictionary)
    }

    /// PRDB artwork through the shared URL cache, which keeps it on disk between launches.
    nonisolated static func fetch(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }
        return data
    }
}
