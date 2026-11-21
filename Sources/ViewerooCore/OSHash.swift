import Foundation

public enum OSHash {
    /// A readable file shorter than two 64 KiB blocks has no OSHash.
    public static func compute(url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let block = 65_536
        guard size >= UInt64(block * 2) else { return nil }

        var sum = size
        for offset in [UInt64(0), size - UInt64(block)] {
            try handle.seek(toOffset: offset)
            var data = Data()
            while data.count < block {
                guard let chunk = try handle.read(upToCount: block - data.count), !chunk.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                data.append(chunk)
            }
            data.withUnsafeBytes { bytes in
                for index in stride(from: 0, to: block, by: 8) {
                    sum &+= UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: index, as: UInt64.self))
                }
            }
        }
        return String(format: "%016llx", sum)
    }
}
