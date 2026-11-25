import AppKit
import Testing
@testable import ViewerooApp

private func jpeg(width: Int, height: Int) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    return try #require(bitmap.representation(using: .jpeg, properties: [:]))
}

@MainActor
@Test func artworkIsDecodedAtTileSizeAndReused() async throws {
    let poster = try jpeg(width: 1600, height: 900), still = try jpeg(width: 480, height: 270)
    let large = try #require(ArtworkCache.downsample(poster, pixels: ArtworkCache.tilePixels))
    #expect(large.width == 640 && large.height == 360)
    let small = try #require(ArtworkCache.downsample(still, pixels: ArtworkCache.tilePixels))
    #expect(small.width == 480 && small.height == 270, "A still smaller than a tile keeps its size")
    #expect(ArtworkCache.downsample(Data([1, 2, 3]), pixels: 640) == nil)

    let cache = ArtworkCache()
    final class Reads: @unchecked Sendable { var count = 0 }
    let reads = Reads()
    let first = try #require(await cache.load("poster") { reads.count += 1; return poster })
    let second = try #require(await cache.load("poster") { reads.count += 1; return poster })
    #expect(first === second && reads.count == 1)
    #expect(cache.image("poster") === first)
    #expect(await cache.load("missing") { nil } == nil)
    // Locking drops decoded artwork.
    cache.removeAll()
    #expect(cache.image("poster") == nil)
}
