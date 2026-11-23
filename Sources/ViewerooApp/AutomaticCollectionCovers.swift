import Foundation
import ViewerooCore

/// Fill only missing covers, in collection order, using locally published video stills.
struct AutomaticCollectionCovers: Equatable, Sendable {
    struct Candidate: Equatable {
        let id: Int64
        let directory: URL
    }
    let candidates: [CoverCollectionID: [Candidate]]

    init(tags: [CatalogTag], playlists: [CatalogPlaylist], entries: [CatalogEntry], cache: PreviewCache) {
        let collections = tags.map(CoverCollection.init) + playlists.map(CoverCollection.init)
        let pending = collections.filter { $0.cover?.revision == nil && !$0.memberIDs.isEmpty }
        guard !pending.isEmpty else { candidates = [:]; return }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        candidates = Dictionary(uniqueKeysWithValues: pending.map { collection in
            (collection.id, collection.memberIDs.compactMap { id in
                byID[id].map { Candidate(id: id, directory: cache.directory(for: $0)) }
            })
        })
    }

    func prepare(in catalog: Catalog) async throws -> Bool {
        var changed = false
        for (id, entries) in candidates {
            for entry in entries {
                try Task.checkCancellation()
                let frames = PreviewCache.frames(in: entry.directory)
                guard let frame = frames.dropFirst().first ?? frames.first,
                      let image = try? Data(contentsOf: frame.url) else { continue }
                if try catalog.saveCover(id, entryID: entry.id, time: frame.time, image: image, custom: false) {
                    changed = true
                }
                break
            }
        }
        return changed
    }
}
