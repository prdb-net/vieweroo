import Foundation
import ViewerooCore

/// Fill only missing covers, in assignment order, using locally published video stills.
struct AutomaticTagCovers: Equatable, Sendable {
    struct Candidate: Equatable {
        let id: Int64
        let directory: URL
    }
    let candidates: [Int64: [Candidate]]

    init(tags: [CatalogTag], entries: [CatalogEntry], cache: PreviewCache) {
        let pending = tags.filter { $0.coverRevision == nil && !$0.memberIDs.isEmpty }
        guard !pending.isEmpty else { candidates = [:]; return }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        candidates = Dictionary(uniqueKeysWithValues: pending.map { tag in
            (tag.id, tag.memberIDs.compactMap { id in
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
                if try catalog.saveTagCover(id, entryID: entry.id, time: frame.time, image: image, custom: false) {
                    changed = true
                }
                break
            }
        }
        return changed
    }
}
