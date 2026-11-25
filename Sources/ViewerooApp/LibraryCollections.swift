import Foundation
import ViewerooCore

struct VisibleVideosKey: Equatable {
    let revision: Int
    let shelf: Shelf
    let term: String
    let filters: CollectionFilters
    let sort: VideoSort
}

/// The order of the videos in a collection.
enum VideoSort: String, CaseIterable, Identifiable {
    /// The collection's own order: a playlist's sequence, or the Watch History ranking.
    case collection
    case title, added, played, duration, path

    var id: Self { self }

    func label(in shelf: Shelf) -> String {
        switch self {
        case .collection: shelf == .frequent ? "Most Watched" : "Playlist Order"
        case .title: "Title"
        case .added: "Recently Added"
        case .played: "Recently Watched"
        case .duration: "Longest First"
        case .path: "Folder and File Name"
        }
    }
}

extension Shelf {
    /// Collections of one kind share a remembered order.
    var sortScope: String? {
        switch self {
        case .playlist: "playlist"
        case .frequent: "history"
        case .all, .favorites, .liked, .studio, .performer, .tag: "library"
        case .studios, .playlists, .sources, .settings, .tags: nil
        }
    }

    /// The first option is the default.
    var sortOptions: [VideoSort] {
        switch sortScope {
        case "playlist": [.collection, .title, .added, .played, .duration, .path]
        case "history": [.collection, .played, .title, .duration]
        case nil: []
        default: [.title, .added, .played, .duration, .path]
        }
    }
}

struct StudioTile: Identifiable {
    let studio: StudioOption
    let count: Int
    let cover: CatalogEntry?
    var id: String { studio.id }
}

extension LibraryModel {
    var collectionTitle: String { collectionTitle(for: shelf) }

    func collectionTitle(for shelf: Shelf) -> String {
        switch shelf {
        case .tags: return "Tags"
        case let .tag(id): return tags.first { $0.id == id }?.name ?? "Tag"
        case .studios: return "Studios"
        case .all: return "All Videos"
        case .favorites: return "Favorites"
        case .liked: return "Liked Videos"
        case .frequent: return "Watch History"
        case let .studio(name, _): return name
        case let .performer(person): return person.name
        case let .playlist(id): return playlists.first { $0.id == id }?.name ?? "Playlist"
        case .playlists: return "Playlists"
        case .settings: return "Library Settings"
        case .sources: return "Source Folders"
        }
    }

    var studioPlatforms: [String] { Set(studioOptions.compactMap { $0.creator?.platform }).sorted() }

    func coverCollection(for studio: StudioOption, in libraryID: Int64) -> CoverCollection {
        let members = entries.lazy.filter { self.studioDirectory.studio(for: $0).id == studio.id }.map(\.id)
        return CoverCollection(studio: studio, libraryID: libraryID, memberIDs: Array(members), cover: studioCovers[studio.id])
    }

    var visibleStudios: [StudioTile] {
        let groups = Dictionary(grouping: entries) { studioDirectory.studio(for: $0).id }
        var options = groups.compactMapValues { $0.first.map(studioDirectory.studio(for:)) }
        for studio in studioOptions where studio.isCustom { options[studio.id] = studio }
        let term = searchTerm
        return options.values.filter { visit.filters.includes($0, favorites: favoriteStudioIDs, term: term) }
            .sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }.map { StudioTile(studio: $0, count: groups[$0.id]?.count ?? 0, cover: groups[$0.id]?.first) }
    }

    /// Views read this several times per update and on every hover or scroll change.
    /// Reuse the result until the collection, search or filters change.
    var visibleVideos: [CatalogEntry] {
        // Register observation of every input, also when the cached result is returned.
        _ = (entries, tags, orderedIDs, studioDirectory)
        let key = VisibleVideosKey(revision: collectionRevision, shelf: shelf, term: searchTerm, filters: visit.filters,
                                   sort: videoSort)
        if let cache = visibleVideosCache, cache.key == key { return cache.videos }
        let scoped = videosInCollection
        let term = key.term
        let matches = narrowed ? scoped.filter { visit.filters.includes($0, directory: studioDirectory, term: term) } : scoped
        let videos = ordered(matches, by: key.sort)
        visibleVideosCache = (key, videos)
        return videos
    }

    /// The order chosen for the open kind of collection.
    var videoSort: VideoSort {
        get {
            let options = shelf.sortOptions
            let saved = shelf.sortScope.flatMap { videoSorts[$0] }.flatMap(VideoSort.init(rawValue:))
            return saved.flatMap { options.contains($0) ? $0 : nil } ?? options.first ?? .title
        }
        set {
            if let scope = shelf.sortScope { videoSorts[scope] = newValue.rawValue }
        }
    }

    /// Positions by title. Comparing titles is the expensive part of sorting, so the table is
    /// kept while the titles of the library are unchanged.
    private func titleRanks() -> [Int64: Int] {
        let titles = entries.map(\.title)
        if let cache = titleRankCache, cache.titles == titles { return cache.ranks }
        let order = entries.indices.sorted {
            let result = titles[$0].localizedStandardCompare(titles[$1])
            return result == .orderedSame ? $0 < $1 : result == .orderedAscending
        }
        var ranks = [Int64: Int](minimumCapacity: order.count)
        for (rank, index) in order.enumerated() { ranks[entries[index].id] = rank }
        titleRankCache = (titles, ranks)
        return ranks
    }

    func ordered(_ videos: [CatalogEntry], by sort: VideoSort) -> [CatalogEntry] {
        if sort == .collection { return videos }
        // Entries arrive in path order. Only a playlist changes it.
        if sort == .path, !shelf.sortOptions.contains(.collection) { return videos }
        let ranks = sort == .added || sort == .path ? [:] : titleRanks()
        func byTitle(_ first: CatalogEntry, _ second: CatalogEntry) -> Bool {
            ranks[first.id, default: .max] < ranks[second.id, default: .max]
        }
        // The largest value first. Videos without a value follow, by title.
        func descending(_ value: (CatalogEntry) -> Double?) -> [CatalogEntry] {
            videos.sorted { first, second in
                let one = value(first) ?? -.infinity, two = value(second) ?? -.infinity
                return one == two ? byTitle(first, second) : one > two
            }
        }
        switch sort {
        case .collection: return videos
        case .title: return videos.sorted(by: byTitle)
        case .added: return videos.sorted { $0.id > $1.id }
        case .played: return descending(\.lastPlayed)
        case .duration: return descending(\.duration)
        case .path: return videos.sorted { $0.path.compare($1.path, options: .caseInsensitive) == .orderedAscending }
        }
    }

    var videosInCollection: [CatalogEntry] {
        switch shelf {
        case let .tag(id):
            guard let tag = tags.first(where: { $0.id == id }) else { return [] }
            let members = Set(tag.memberIDs)
            return entries.filter { members.contains($0.id) }
        case .favorites: return entries.filter(\.favorite)
        case .liked: return entries.filter { $0.rating > 0 }
        case .frequent:
            return entries.filter { $0.playCount > 0 }.sorted {
                ($0.weightedPlays, $0.watchTime) > ($1.weightedPlays, $1.watchTime)
            }
        case let .studio(name, siteID):
            return entries.filter {
                let studio = studioDirectory.studio(for: $0)
                if let siteID { return studio.siteID == siteID }
                return studio.siteID == nil && studio.name.caseInsensitiveCompare(name) == .orderedSame
            }
        case let .performer(person): return entries.filter { $0.match?.performers.contains { $0.id == person.id } == true }
        case .playlist:
            let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            return orderedIDs.compactMap { byID[$0] }
        default: return entries
        }
    }

    var visiblePlaylists: [CatalogPlaylist] {
        let term = searchTerm
        return playlists.filter { visit.filters.includes($0, term: term) }
    }

    var visibleSources: [CatalogSource] {
        let term = searchTerm
        return sources.filter {
            (!visit.filters.selected.contains(.offline) || !$0.online)
                && (term.isEmpty || $0.path.localizedCaseInsensitiveContains(term))
        }
    }
}
