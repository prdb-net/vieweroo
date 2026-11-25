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
    var remaining: ArraySlice<CatalogEntry> = []
    var failures: [Failure] = []
    var ready: Int { total - remaining.count - failures.count }

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
