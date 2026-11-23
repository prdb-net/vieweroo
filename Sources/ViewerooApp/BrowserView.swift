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
                    if playlistID != nil {
                        Button(action: model.startPlaylistCinema) {
                            Label("Cinema Mode", systemImage: "play.rectangle")
                        }
                        .disabled(!model.videosInCollection.contains(where: LibraryModel.cinemaPlayable))
                        .help("Play this playlist in Cinema Mode")
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
                            Button {
                                guard selection != nil else { model.openDetail(entry.id); return }
                                NSApp.keyWindow?.makeFirstResponder(nil)
                                if selection?.contains(entry.id) == true { selection?.remove(entry.id) }
                                else { selection?.insert(entry.id) }
                            } label: {
                                VStack(alignment: .leading, spacing: VSpace.tight) {
                                    poster(entry, tile: .video(entry.id))
                                    VStack(alignment: .leading, spacing: VSpace.unit) {
                                        Text(entry.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                                        if model.shelf == .frequent {
                                            Text(entry.viewingSummary).font(.subheadline).foregroundStyle(.secondary)
                                        }
                                        if let subtitle = subtitle(entry) {
                                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .accessibilityAddTraits(isSelected(.video(entry.id)) ? .isSelected : [])
                            .overlay(alignment: .topTrailing) {
                                if let selection {
                                    SelectionCheckmark(checked: selection.contains(entry.id))
                                } else if entry.availability == .available {
                                    let action = entry.resume > 0 ? "Resume" : "Play"
                                    Button { model.play(entry) } label: {
                                        Image(systemName: "play.fill")
                                            .font(.body.weight(.bold))
                                            .frame(width: 30, height: 30)
                                            .foregroundStyle(.white)
                                            .background(.black.opacity(0.76), in: Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(action) \(entry.title)")
                                    .help("\(action) \(entry.title)")
                                    .padding(VSpace.tight)
                                }
                            }
                            .contextMenu {
                                if selection == nil {
                                    Button(entry.resume > 0 ? "Resume" : "Play") { model.play(entry) }
                                        .disabled(entry.availability != .available)
                                    if model.shelf == .frequent, entry.resume > 0 {
                                        Button("Play from Beginning") { model.play(entry, at: 0) }
                                            .disabled(entry.availability != .available)
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
                AsyncImage(url: model.artworkURL(entry.match?.previewURL)) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else if let local { Image(nsImage: local).resizable().scaledToFill() }
                    else { Image(systemName: "film").font(.title).foregroundStyle(.tertiary) }
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
