import Foundation
import ViewerooCore

struct StudioTile: Identifiable {
    let studio: StudioOption
    let count: Int
    let cover: CatalogEntry?
    var id: String { studio.id }
}

extension LibraryModel {
    var collectionTitle: String {
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
        case .settings: return "Settings"
        case .sources: return "Source Folders"
        }
    }

    var studioPlatforms: [String] { Set(studioOptions.compactMap { $0.creator?.platform }).sorted() }

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

    var visibleVideos: [CatalogEntry] {
        let scoped = videosInCollection
        guard narrowed else { return scoped }
        let term = searchTerm
        return scoped.filter { visit.filters.includes($0, directory: studioDirectory, term: term) }
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
