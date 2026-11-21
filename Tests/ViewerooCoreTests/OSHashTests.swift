import Foundation
import Testing
@testable import ViewerooCore

struct OSHashTests {
    // Reference vectors from prdb-net/prdb-sdk, csharp/tests/Prdb.Hashing.Tests/OsHashTests.cs.
    // The SDK's video-hashing-vectors.json contains the separate perceptual hash vectors.
    @Test func sdkOSHashReferenceFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        func check(size: Int, words: [(offset: Int, value: UInt64)], expected: String?) throws {
            var data = Data(repeating: 0, count: size)
            for word in words {
                withUnsafeBytes(of: word.value.littleEndian) { bytes in
                    data.replaceSubrange(word.offset..<(word.offset + 8), with: bytes)
                }
            }
            try data.write(to: url)
            #expect(try OSHash.compute(url: url) == expected)
        }
        for size in [0, 1, 131071] { try check(size: size, words: [], expected: nil) }
        try check(size: 131072, words: [], expected: "0000000000020000")
        try check(size: 131072, words: [(0, 0x1111111111111111), (65536, 0x2222222222222222)],
                  expected: "3333333333353333")
        try check(size: 262144, words: [(65536, 0xaaaaaaaaaaaaaaaa), (262136, 5)], expected: "0000000000040005")
        try check(size: 131072, words: [(0, UInt64.max)], expected: "000000000001ffff")
        try check(size: 131073, words: [(131065, 0x0102030405060708)], expected: "0102030405080709")
        try FileManager.default.removeItem(at: url)
        #expect(throws: (any Error).self) { try OSHash.compute(url: url) }
    }
}
