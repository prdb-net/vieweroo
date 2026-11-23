import SwiftUI
import ViewerooCore

struct BrowserView: View {
    @Bindable var model: LibraryModel
    @Binding var selection: Set<Int64>?
    let selectionShortcuts: Bool
    // A legacy scroller consumes width when it appears. If that changes the tile
    // height, the last row can fit again and AppKit removes the scroller mid-layout.
    private func columns(for viewportWidth: CGFloat) -> [GridItem] {
        let gutter = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let width = max(1, viewportWidth - 2 * VSpace.section - gutter)
        let count = max(1, Int((width + VSpace.group) / (176 + VSpace.group)))
        let tileWidth = min(320, floor((width - CGFloat(count - 1) * VSpace.group) / CGFloat(count)))
        return Array(repeating: GridItem(.fixed(tileWidth), spacing: VSpace.group, alignment: .topLeading), count: count)
    }
    @FocusState private var focusedTitle: Int64?
    @State private var hoveredPoster: Int64?
    @State private var hoveredTitle: Int64?
    @State private var coverCollection: CoverCollection?
    @Environment(\.colorScheme) private var scheme
    private var studioIndex: Bool { model.shelf == .studios }
    private var playlistID: Int64? {
        if case let .playlist(id) = model.shelf { return id }
        return nil
    }
    var body: some View {
        let records = model.shelf.isVideoCollection ? model.visibleVideos : []
        VStack(spacing: 0) {
            if selection != nil, model.shelf == .playlists, let libraryID = model.libraryID {
                PlaylistEditBar(model: model, libraryID: libraryID, selection: $selection,
                                shortcutsEnabled: selectionShortcuts)
            } else if selection != nil, model.shelf.isVideoCollection {
                BulkEditBar(model: model, selection: $selection, visibleIDs: records.map(\.id),
                            shortcutsEnabled: selectionShortcuts)
            }
            GeometryReader { viewport in
                collection(columns: columns(for: viewport.size.width), records: records)
            }
        }
        .onChange(of: model.detailID) { previous, current in
            if previous != nil, current == nil, case let .video(id) = model.visit.selectedTile {
                focusedTitle = id
            }
        }
        .sheet(item: $coverCollection) { collection in
            CollectionCoverPicker(model: model, collection: collection)
        }
    }

    private func collection(columns: [GridItem], records: [CatalogEntry]) -> some View {
        let studios = studioIndex ? model.visibleStudios : []
        let collections: [CoverCollection]
        let count: Int
        let noun: String
        switch model.shelf {
        case .tags:
            collections = model.tags.filter { model.visit.filters.includes($0, term: model.searchTerm) }.map(CoverCollection.init)
            (count, noun) = (collections.count, "tag")
        case .playlists:
            collections = model.visiblePlaylists.map(CoverCollection.init)
            (count, noun) = (collections.count, "playlist")
        case .studios:
            collections = []
            (count, noun) = (studios.count, "studio")
        default:
            collections = []
            (count, noun) = (records.count, "video")
        }
        let unit = count == 1 ? noun : noun + "s"
        return ScrollView {
            VStack(alignment: .leading, spacing: VSpace.section) {
                CollectionHeading(title: model.collectionTitle, count: "\(count) \(unit)", filters: model.filterBinding) {
                    if model.shelf.isVideoCollection {
                        Menu {
                            DisplayChoices { model.startCinema(on: $0) }
                        } label: {
                            Label("Cinema Mode", systemImage: "play.rectangle")
                        } primaryAction: { model.startCinema() }
                        .disabled(!records.contains(where: LibraryModel.cinemaPlayable))
                        .help("Play the visible videos in order")
                    }
                    if case let .studio(_, id?) = model.shelf, let account = model.studioDirectory.site(id)?.creator {
                        CreatorProfileView(account: account)
                    }
                }
                if count == 0 { empty }
                else if !collections.isEmpty {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: VSpace.section) {
                        ForEach(collections) { collection in
                            CollectionCoverTile(model: model, collection: collection, selection: $selection) {
                                coverCollection = collection
                            }
                        }
                    }
                }
                else if studioIndex { studioGrid(studios, columns: columns) }
                else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: VSpace.section) {
                        ForEach(records) { entry in
                            videoTile(entry)
                                .contextMenu {
                                    if selection == nil {
                                        Button("Details") { model.openDetail(entry.id) }
                                        Button(entry.resume > 0 ? "Resume" : "Play") { model.play(entry) }
                                            .disabled(!LibraryModel.cinemaPlayable(entry))
                                        Menu("Play on Display") {
                                            DisplayChoices { model.playOnDisplay(entry, screen: $0) }
                                        }
                                        .disabled(!LibraryModel.cinemaPlayable(entry))
                                        if entry.resume > 0 {
                                            Button("Play from Beginning") { model.play(entry, at: 0) }
                                                .disabled(!LibraryModel.cinemaPlayable(entry))
                                        }
                                        Divider()
                                        EntryReactions(model: model, entry: entry, inMenu: true)
                                        Divider()
                                        PlaylistMenu(model: model, entryID: entry.id, inContextMenu: true)
                                    }
                                    if selection == nil, let id = playlistID {
                                        Divider()
                                        Button("Move Earlier") { move(entry, by: -1, among: records, playlist: id) }.disabled(records.first?.id == entry.id)
                                        Button("Move Later") { move(entry, by: 1, among: records, playlist: id) }.disabled(records.last?.id == entry.id)
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

    @ViewBuilder private func videoTile(_ entry: CatalogEntry) -> some View {
        let tile = BrowseTile.video(entry.id)
        if let selected = selection {
            Button {
                NSApp.keyWindow?.makeFirstResponder(nil)
                if selected.contains(entry.id) { selection?.remove(entry.id) }
                else { selection?.insert(entry.id) }
            } label: {
                VStack(alignment: .leading, spacing: VSpace.tight) {
                    poster(entry, tile: tile)
                        .overlay(alignment: .topTrailing) { SelectionCheckmark(checked: selected.contains(entry.id)) }
                    tileCaption(entry)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected.contains(entry.id) ? .isSelected : [])
        } else {
            let playable = LibraryModel.cinemaPlayable(entry)
            let action = playable ? (entry.resume > 0 ? "Resume" : "Play") : "Details"
            VStack(alignment: .leading, spacing: VSpace.tight) {
                Button {
                    if playable { model.play(entry) } else { model.openDetail(entry.id) }
                } label: {
                    poster(entry, tile: tile)
                        .overlay(alignment: .topTrailing) {
                            if playable && hoveredPoster == entry.id {
                                Image(systemName: "play.fill")
                                    .frame(width: 30, height: 30)
                                    .foregroundStyle(.white)
                                    .background(.black.opacity(0.76), in: Circle())
                                    .padding(VSpace.tight).allowsHitTesting(false)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .help("\(action) · \(entry.title)")
                .accessibilityLabel("\(action) \(entry.title)")
                .onHover { inside in hoveredPoster = inside ? entry.id : nil }
                Button { model.openDetail(entry.id) } label: {
                    tileCaption(entry)
                }
                .focused($focusedTitle, equals: entry.id)
                .help("Show details")
                .accessibilityLabel("Details for \(entry.title)")
                .onHover { inside in hoveredTitle = inside ? entry.id : nil }
            }
            .buttonStyle(.plain)
        }
    }

    private func tileCaption(_ entry: CatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: VSpace.unit) {
            Text(entry.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                .underline(selection == nil && hoveredTitle == entry.id)
            if model.shelf == .frequent {
                Text(entry.viewingSummary).font(.subheadline).foregroundStyle(.secondary)
            }
            if let subtitle = subtitle(entry) {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    private func studioGrid(_ studios: [StudioTile], columns: [GridItem]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: VSpace.section) {
            ForEach(studios) { item in
                let studio = item.studio
                let tile = BrowseTile.studio(studio.name, siteID: studio.siteID)
                ZStack(alignment: Alignment(horizontal: .trailing, vertical: .studioTitle)) {
                    Button { model.browse(.studio(studio.name, siteID: studio.siteID), from: tile) } label: {
                        VStack(alignment: .leading, spacing: VSpace.tight) {
                            if let custom = model.studioCovers[studio.id], let libraryID = model.libraryID {
                                CollectionCoverImage(model: model, id: .studio(libraryID: libraryID, studioID: studio.id),
                                                     cover: custom, symbol: "film.stack")
                                    .overlay {
                                        if isSelected(tile) {
                                            RoundedRectangle(cornerRadius: VSpace.tight).strokeBorder(Color.accentColor, lineWidth: 2)
                                        }
                                    }
                                    .accessibilityHidden(true)
                            } else if let cover = item.cover {
                                poster(cover, tile: tile)
                            } else {
                                RoundedRectangle(cornerRadius: VSpace.tight)
                                    .fill(.quaternary.opacity(0.5)).aspectRatio(16/9, contentMode: .fit)
                                    .overlay { Image(systemName: "film.stack").font(.title).foregroundStyle(.secondary) }
                            }
                            VStack(alignment: .leading, spacing: VSpace.unit) {
                                Text(studio.name).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                                    .padding(.trailing, 28)
                                    .alignmentGuide(.studioTitle) { $0[VerticalAlignment.center] }
                                if let creator = studio.creator { Text(creator.platform).font(.subheadline).foregroundStyle(.secondary) }
                                Text(item.count == 1 ? "1 video" : "\(item.count) videos")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityAddTraits(model.visit.selectedTile == tile ? .isSelected : [])
                    .contextMenu {
                        Button("Choose Cover…") {
                            if let libraryID = model.libraryID { coverCollection = model.coverCollection(for: studio, in: libraryID) }
                        }.disabled(item.count == 0)
                    }
                    let favorite = model.favoriteStudioIDs.contains(studio.id)
                    Button { model.toggleStudioFavorite(studio) } label: {
                        Image(systemName: favorite ? "heart.fill" : "heart")
                            .foregroundStyle(favorite ? VideoReaction.favorite.tint(in: scheme) : Color.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(favorite ? "Remove from favorite studios" : "Add to favorite studios")
                    .accessibilityLabel("Favorite " + studio.name)
                    .accessibilityValue(favorite ? "On" : "Off")
                }
            }
        }
    }

    private func isSelected(_ tile: BrowseTile) -> Bool {
        if let selection, case let .video(id) = tile { return selection.contains(id) }
        return model.visit.selectedTile == tile
    }

    private func poster(_ entry: CatalogEntry, tile: BrowseTile) -> some View {
        Poster(model: model, entry: entry, scrubbable: selection == nil && tile == .video(entry.id))
            .overlay {
                if isSelected(tile) {
                    RoundedRectangle(cornerRadius: VSpace.tight, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
    }

    private func subtitle(_ entry: CatalogEntry) -> String? {
        if entry.availability == .offline { return "Source offline" }
        if entry.availability == .missing { return "File missing" }
        if entry.playbackFailure != nil { return "Playback unavailable" }
        if model.shelf == .frequent { return nil }
        return entry.studio ?? "Unknown Studio"
    }
    private func move(_ entry: CatalogEntry, by delta: Int, among visible: [CatalogEntry], playlist: Int64) {
        var ids = model.orderedIDs
        guard let index = visible.firstIndex(where: { $0.id == entry.id }), visible.indices.contains(index + delta),
              let from = ids.firstIndex(of: entry.id), let to = ids.firstIndex(of: visible[index + delta].id) else { return }
        ids.swapAt(from, to)
        model.change("Playlist order saved") { try $0.reorderPlaylist(playlist, entryIDs: ids) }
    }
    @ViewBuilder private var empty: some View {
        if model.shelf == .playlists {
            ContentUnavailableView(model.narrowed ? "No matching playlists" : "No playlists yet",
                                   systemImage: model.narrowed ? "magnifyingglass" : "list.and.film",
                                   description: Text(model.narrowed ? "Try a different search or clear a filter." : selection == nil ? "Click the edit pencil to create your first playlist." : "Click New Playlist to create your first playlist."))
        } else if model.shelf == .tags {
            ContentUnavailableView(model.narrowed ? "No matching tags" : "No tags yet",
                                   systemImage: model.narrowed ? "magnifyingglass" : "tag",
                                   description: Text(model.narrowed ? "Try a different search or clear a filter." : "Create a tag in Manage Tags or add one to a video."))
        } else if model.narrowed {
            ContentUnavailableView(studioIndex ? "No matching studios" : "No matching videos", systemImage: "magnifyingglass",
                                   description: Text("Try a different search or clear a filter."))
        }
        else if model.sources.isEmpty && model.entries.isEmpty {
            ContentUnavailableView {
                Label("Add a video folder", systemImage: "folder.badge.plus")
            } description: {
                Text("Choose a folder on this Mac or a mounted drive. Vieweroo will catalog its MP4, M4V, and MOV files.")
            } actions: { Button("Choose Folder…") { model.pickSource() }.buttonStyle(.borderedProminent) }
        } else {
            ContentUnavailableView("No videos here yet", systemImage: "film",
                                   description: Text(playlistID != nil ? "Right-click a video in your library and choose Add to Playlist." : "Videos appear here when they belong to this collection."))
        }
    }
}

private extension VerticalAlignment {
    enum StudioTitle: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat { dimensions[VerticalAlignment.center] }
    }
    static let studioTitle = VerticalAlignment(StudioTitle.self)
}

struct Poster: View {
    var model: LibraryModel
    var entry: CatalogEntry
    var scrubbable = true
    @State private var local: NSImage?
    @State private var revision = 0
    @State private var loadedDirectory: URL?
    var body: some View {
        let directory = model.previewDirectory(entry)
        Rectangle().fill(.quaternary.opacity(0.5))
            .aspectRatio(16/9, contentMode: .fit)
            .overlay {
                if let imported = entry.posterRevision {
                    ImportedPoster(catalog: model.catalog, entryID: entry.id)
                        .id(imported)
                } else {
                    AsyncImage(url: model.artworkURL(entry.match?.previewURL)) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else if let local { Image(nsImage: local).resizable().scaledToFill() }
                        else { Image(systemName: "film").font(.title).foregroundStyle(.tertiary) }
                    }
                }
            }.clipped()
            .overlay {
                if scrubbable {
                    PosterScrubber(directory: directory, revision: revision)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: VSpace.tight, style: .continuous))
            .onReceive(model.posterPrepared) { ready in
                if ready == directory { revision &+= 1 }
            }
            .task(id: ImageRequest(directory: directory, revision: revision)) {
                if loadedDirectory != directory { local = nil; loadedDirectory = directory }
                let url = PreviewCache.posterURL(in: directory)
                if local != nil { return }
                let bytes = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
                if !Task.isCancelled, let bytes { local = NSImage(data: bytes) }
            }.accessibilityHidden(true)
    }
    private struct ImageRequest: Equatable { var directory: URL; var revision: Int }
}


/// Load imported artwork only for posters actually on screen.
private struct ImportedPoster: View {
    let catalog: Catalog?
    let entryID: Int64
    @State private var image: NSImage?

    var body: some View {
        Color.clear.overlay {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
        }
        .task(id: entryID) {
            image = nil
            let data = await Task.detached(priority: .utility) { [catalog, entryID] in
                try? catalog?.importedPoster(entryID: entryID)
            }.value
            if !Task.isCancelled { image = data.flatMap(NSImage.init(data:)) }
        }
    }
}
