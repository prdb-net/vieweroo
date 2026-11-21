import SwiftUI
import ViewerooCore

struct BrowserView: View {
    @Bindable var model: LibraryModel
    @State private var deletingPlaylist = false
    private let columns = [GridItem(.adaptive(minimum: 176, maximum: 320), spacing: VSpace.group, alignment: .topLeading)]
    private var searching: Bool { !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var studioIndex: Bool { !searching && (model.shelf ?? .studios) == .studios }
    private var playlistID: Int64? {
        if case let .playlist(id) = model.shelf, !searching { return id }
        return nil
    }
    private var title: String {
        if searching { return "Search Results" }
        switch model.shelf ?? .studios {
        case .studios: return "Studios"
        case .all: return "All Videos"
        case .favorites: return "Favorites"
        case .liked: return "Liked Videos"
        case .frequent: return "Frequently Watched"
        case let .studio(name): return name
        case let .performer(person): return person.name
        case let .playlist(id): return model.playlists.first { $0.id == id }?.name ?? "Playlist"
        case .sources: return "Source Folders"
        }
    }
    private var filtered: [CatalogEntry] {
        if searching {
            let term = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.entries.filter { entry in
                let fields = [entry.title, entry.filename, entry.studio ?? "Unknown Studio"] + entry.tags + (entry.match?.performers.map(\.name) ?? [])
                return fields.contains { $0.localizedCaseInsensitiveContains(term) }
            }
        }
        switch model.shelf {
        case .favorites: return model.entries.filter(\.favorite)
        case .liked: return model.entries.filter { $0.rating > 0 }
        case .frequent: return model.entries.filter { $0.playCount > 0 }.sorted { ($0.playCount, $0.watchTime) > ($1.playCount, $1.watchTime) }
        case let .studio(name): return model.entries.filter { ($0.studio ?? "Unknown Studio") == name }
        case let .performer(person): return model.entries.filter { $0.match?.performers.contains { $0.id == person.id } == true }
        case .playlist:
            let entries = Dictionary(uniqueKeysWithValues: model.entries.map { ($0.id, $0) })
            return model.orderedIDs.compactMap { entries[$0] }
        default: return model.entries
        }
    }

    var body: some View {
        let records = filtered
        ScrollView {
            VStack(alignment: .leading, spacing: VSpace.section) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.largeTitle.bold()).textSelection(.enabled).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if !records.isEmpty {
                        Text("\(records.count) \(records.count == 1 ? "video" : "videos")")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if playlistID != nil {
                        Button { deletingPlaylist = true } label: { Label("Delete Playlist", systemImage: "trash").labelStyle(.iconOnly) }
                    }
                }
                if records.isEmpty { empty }
                else if studioIndex {
                    let groups = Dictionary(grouping: records) { $0.studio ?? "Unknown Studio" }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: VSpace.section) {
                        ForEach(groups.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }), id: \.self) { studio in
                            if let group = groups[studio], let cover = group.first {
                                Button { model.shelf = .studio(studio) } label: {
                                    VStack(alignment: .leading, spacing: VSpace.tight) {
                                        Poster(model: model, entry: cover)
                                        VStack(alignment: .leading, spacing: VSpace.unit) {
                                            Text(studio).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                                            Text(group.count == 1 ? "1 video" : "\(group.count) videos")
                                                .font(.subheadline).foregroundStyle(.secondary)
                                        }
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: VSpace.section) {
                        ForEach(records) { entry in
                            Button { model.detailID = entry.id } label: {
                                VStack(alignment: .leading, spacing: VSpace.tight) {
                                    Poster(model: model, entry: entry)
                                    VStack(alignment: .leading, spacing: VSpace.unit) {
                                        Text(entry.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                                        Text(subtitle(entry)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .contextMenu {
                                Button("Play") { model.play(entry, at: entry.resume) }.disabled(entry.availability != .available)
                                if let id = playlistID {
                                    Button("Move Earlier") { move(entry, by: -1, playlist: id) }.disabled(model.orderedIDs.first == entry.id)
                                    Button("Move Later") { move(entry, by: 1, playlist: id) }.disabled(model.orderedIDs.last == entry.id)
                                    Button("Remove from Playlist") { model.change("Removed from playlist") { try $0.removeFromPlaylist(id, entryID: entry.id) } }
                                }
                            }
                        }
                    }
                }
            }.padding(VSpace.section).frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Delete this playlist?", isPresented: $deletingPlaylist) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Playlist", role: .destructive) {
                if let id = playlistID { model.change("Playlist deleted") { try $0.deletePlaylist(id); model.shelf = .studios } }
            }
        } message: { Text("All videos will remain in the library.") }
    }
    private func subtitle(_ entry: CatalogEntry) -> String {
        if entry.availability == .offline { return "Source offline" }
        if entry.availability == .missing { return "File missing" }
        if entry.playbackFailure != nil { return "Playback unavailable" }
        if model.shelf == .frequent { return entry.playCount == 1 ? "1 play" : "\(entry.playCount) plays" }
        return entry.studio ?? "Unknown Studio"
    }
    private func move(_ entry: CatalogEntry, by delta: Int, playlist id: Int64) {
        var ids = model.orderedIDs
        guard let i = ids.firstIndex(of: entry.id), ids.indices.contains(i + delta) else { return }
        ids.swapAt(i, i + delta); model.change("Playlist order saved") { try $0.reorderPlaylist(id, entryIDs: ids) }
    }
    @ViewBuilder private var empty: some View {
        if searching { ContentUnavailableView.search(text: model.query) }
        else if model.sources.isEmpty && model.entries.isEmpty {
            ContentUnavailableView {
                Label("Add a video folder", systemImage: "folder.badge.plus")
            } description: {
                Text("Choose a folder on this Mac or a mounted drive. Vieweroo will catalog its MP4, M4V, and MOV files.")
            } actions: { Button("Choose Folder…") { model.pickSource() }.buttonStyle(.borderedProminent) }
        } else {
            ContentUnavailableView("No videos here yet", systemImage: "film",
                                   description: Text(playlistID != nil ? "Open a video and choose Add to Playlist." : "Videos appear here when they belong to this collection."))
        }
    }
}

struct Poster: View {
    var model: LibraryModel
    var entry: CatalogEntry
    @State private var local: NSImage?
    @State private var loadedDirectory: URL?
    var body: some View {
        Rectangle().fill(.quaternary.opacity(0.5))
            .aspectRatio(16/9, contentMode: .fit)
            .overlay {
                AsyncImage(url: entry.match?.previewURL) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else if let local { Image(nsImage: local).resizable().scaledToFill() }
                    else { Image(systemName: "film").font(.title).foregroundStyle(.tertiary) }
                }
            }.clipped().clipShape(RoundedRectangle(cornerRadius: VSpace.tight, style: .continuous))
            .task(id: ImageRequest(directory: model.previewDirectory(entry), revision: model.previewRevision)) {
                let directory = model.previewDirectory(entry)
                if loadedDirectory != directory { local = nil; loadedDirectory = directory }
                let url = PreviewCache.posterURL(in: directory)
                if local != nil { return }
                let bytes = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
                if !Task.isCancelled, let bytes { local = NSImage(data: bytes) }
            }.accessibilityHidden(true)
    }
    private struct ImageRequest: Equatable { var directory: URL; var revision: Int }
}
