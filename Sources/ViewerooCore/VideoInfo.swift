import AVFoundation
import Foundation

/// Local properties of the first video track. The catalog keeps them when the source is offline.
public struct VideoInfo: Codable, Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let codec: String
    public let container: String?
    public let frameRate: Float?

    public var quality: String {
        let long = max(width, height), short = min(width, height)
        // Include portrait and cinema crops in the same tier as their landscape equivalents.
        if long >= 7680 || short >= 4320 { return "8K" }
        if long >= 3840 || short >= 2160 { return "4K" }
        if long >= 2560 || short >= 1440 { return "1440p" }
        if long >= 1920 || short >= 1080 { return "1080p" }
        if long >= 1280 || short >= 720 { return "720p" }
        return "SD"
    }

    /// The video track's properties together with the movie duration from the same open asset.
    public struct Probe: Sendable {
        public let info: VideoInfo
        public let duration: Double?
    }

    public static func read(from url: URL) async throws -> VideoInfo? {
        try await probe(url)?.info
    }

    public static func probe(_ url: URL) async throws -> Probe? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let format = try await track.load(.formatDescriptions).first else { return nil }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        guard size.width > 0, size.height > 0 else { return nil }
        let fps = try? await track.load(.nominalFrameRate)
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        let bytes = withUnsafeBytes(of: subtype.bigEndian) { Array($0) }
        let code = String(bytes: bytes, encoding: .ascii)
        let codec: String
        switch code {
        case "avc1", "avc3": codec = "H.264"
        case "hvc1", "hev1": codec = "HEVC (H.265)"
        case "av01": codec = "AV1"
        case "vp09": codec = "VP9"
        case "mp4v": codec = "MPEG-4 Visual"
        default: codec = bytes.allSatisfy { (32...126).contains($0) } ? (code ?? "Unknown") : String(format: "0x%08X", subtype)
        }
        let info = VideoInfo(width: Int(size.width), height: Int(size.height), codec: codec,
                             container: containerName(at: url), frameRate: fps.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
        let duration = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return Probe(info: info, duration: duration)
    }

    private static func containerName(at url: URL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let header = try? file.read(upToCount: 12), header.count == 12,
              String(decoding: header[4..<8], as: UTF8.self) == "ftyp" else { return nil }
        switch String(decoding: header[8..<12], as: UTF8.self) {
        case "qt  ": return "QuickTime (MOV)"
        case "M4V ", "M4VH", "M4VP": return "MPEG-4 (M4V)"
        case "isom", "iso2", "mp41", "mp42", "avc1": return "MPEG-4"
        default: return "ISO Base Media"
        }
    }
}
