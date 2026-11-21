import SwiftUI
import ViewerooCore

struct BrowserView: View {
    @Bindable var model: LibraryModel
    @State private var deletingPlaylist = false
    // A legacy scroller consumes width when it appears. If that changes the tile
    // height, the last row can fit again and AppKit removes the scroller mid-layout.
    private func columns(for viewportWidth: CGFloat) -> [GridItem] {
        let gutter = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let width = max(1, viewportWidth - 2 * VSpace.section - gutter)
        let count = max(1, Int((width + VSpace.group) / (176 + VSpace.group)))
        let tileWidth = min(320, floor((width - CGFloat(count - 1) * VSpace.group) / CGFloat(count)))
        return Array(repeating: GridItem(.fixed(tileWidth), spacing: VSpace.group, alignment: .topLeading), count: count)
    }
    private var searching: Bool { !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var studioIndex: Bool { !searching && model.shelf == .studios }
    private var playlistID: Int64? {
        if case let .playlist(id) = model.shelf, !searching { return id }
        return nil
    }
    private var title: String {
        if searching { return "Search Results" }
        switch model.shelf {
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
        case .frequent:
            return model.entries.filter { $0.playCount > 0 }.sorted {
                ($0.weightedPlays, $0.watchTime) > ($1.weightedPlays, $1.watchTime)
            }
        case let .studio(name): return model.entries.filter { ($0.studio ?? "Unknown Studio") == name }
        case let .performer(person): return model.entries.filter { $0.match?.performers.contains { $0.id == person.id } == true }
        case .playlist:
            let entries = Dictionary(uniqueKeysWithValues: model.entries.map { ($0.id, $0) })
            return model.orderedIDs.compactMap { entries[$0] }
        default: return model.entries
        }
    }

    var body: some View {
        GeometryReader { viewport in
            collection(columns: columns(for: viewport.size.width))
        }
        .alert("Delete this playlist?", isPresented: $deletingPlaylist) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Playlist", role: .destructive) {
                if let id = playlistID { model.change("Playlist deleted") { try $0.deletePlaylist(id) } }
            }
        } message: { Text("All videos will remain in the library.") }
    }

    private func collection(columns: [GridItem]) -> some View {
        let records = filtered
        return ScrollView {
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
                                Button { model.browse(.studio(studio), from: .studio(studio)) } label: {
                                    VStack(alignment: .leading, spacing: VSpace.tight) {
                                        poster(cover, tile: .studio(studio))
                                        VStack(alignment: .leading, spacing: VSpace.unit) {
                                            Text(studio).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                                            Text(group.count == 1 ? "1 video" : "\(group.count) videos")
                                                .font(.subheadline).foregroundStyle(.secondary)
                                        }
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                .accessibilityAddTraits(model.visit.selectedTile == .studio(studio) ? .isSelected : [])
                            }
                        }
                    }
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: VSpace.section) {
                        ForEach(records) { entry in
                            Button { model.openDetail(entry.id) } label: {
                                VStack(alignment: .leading, spacing: VSpace.tight) {
                                    poster(entry, tile: .video(entry.id))
                                    VStack(alignment: .leading, spacing: VSpace.unit) {
                                        Text(entry.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                                        if model.shelf == .frequent, !searching {
                                            Text(entry.viewingSummary).font(.subheadline).foregroundStyle(.secondary)
                                        }
                                        if let subtitle = subtitle(entry) {
                                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .accessibilityAddTraits(model.visit.selectedTile == .video(entry.id) ? .isSelected : [])
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
            .background(BrowseScrollAnchor(position: model.visit.scroll))
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
    }
    private func poster(_ entry: CatalogEntry, tile: BrowseTile) -> some View {
        Poster(model: model, entry: entry)
            .overlay {
                if model.visit.selectedTile == tile {
                    RoundedRectangle(cornerRadius: VSpace.tight, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
    }

    private func subtitle(_ entry: CatalogEntry) -> String? {
        if entry.availability == .offline { return "Source offline" }
        if entry.availability == .missing { return "File missing" }
        if entry.playbackFailure != nil { return "Playback unavailable" }
        if model.shelf == .frequent, !searching { return nil }
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
    @State private var revision = 0
    @State private var loadedDirectory: URL?
    var body: some View {
        let directory = model.previewDirectory(entry)
        Rectangle().fill(.quaternary.opacity(0.5))
            .aspectRatio(16/9, contentMode: .fit)
            .overlay {
                AsyncImage(url: model.artworkURL(entry.match?.previewURL)) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else if let local { Image(nsImage: local).resizable().scaledToFill() }
                    else { Image(systemName: "film").font(.title).foregroundStyle(.tertiary) }
                }
            }.clipped().clipShape(RoundedRectangle(cornerRadius: VSpace.tight, style: .continuous))
            .onReceive(model.posterPrepared) { ready in
                if ready == directory { revision &+= 1 }
            }
            .task(id: ImageRequest(directory: directory, revision: revision)) {
                if loadedDirectory != directory { local = nil; loadedDirectory = directory }
                let url = PreviewCache.posterURL(in: directory)
                if local != nil { return }
                let bytes = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
                if !Task.isCancelled, let bytes { local = NSImage(data: bytes) }
            }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private struct ImageRequest: Equatable { var directory: URL; var revision: Int }
}
