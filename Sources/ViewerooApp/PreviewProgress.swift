import Foundation
import ViewerooCore

struct PreviewProgress {
    enum Phase { case idle, checking, preparing }
    struct Failure: Identifiable {
        let entry: CatalogEntry
        let reason: String
        var id: Int64 { entry.id }
    }

    var phase: Phase = .idle
    var total = 0
    /// In queue order. The first entries are the ones being prepared.
    var remaining: [CatalogEntry] = []
    var failures: [Failure] = []
    var ready: Int { total - remaining.count - failures.count }

    /// Two movies at a time were 16% faster than one on local storage. A third added nothing.
    static let workers = 2

    mutating func finish(_ entry: CatalogEntry) {
        if let index = remaining.firstIndex(where: { $0.id == entry.id }) { remaining.remove(at: index) }
    }

    // Read manifests on the cooperative executor before reporting how many sets are ready.
    static func missing(in entries: [CatalogEntry], cache: PreviewCache) async throws -> [CatalogEntry] {
        try entries.filter { entry in
            try Task.checkCancellation()
            return PreviewCache.frames(in: cache.directory(for: entry)).isEmpty
        }
    }
}

extension PreviewCache {
    func directory(for entry: CatalogEntry) -> URL {
        directory(for: entry.url, size: entry.fileSize, modificationDate: Date(timeIntervalSince1970: entry.modified))
    }
}
