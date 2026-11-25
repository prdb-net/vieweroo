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
    @State private var coverCollection: CoverCollection?
    @State private var keyboard = GridKeyboard()
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
        .background {
            GridKeyReader(keyboard: keyboard).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    /// A tile with the identity its grid scrolls to.
    private struct KeyTile {
        let tile: BrowseTile
        let scrollID: AnyHashable
        var activate: () -> Void
    }

    /// Arrow keys move the highlight, Return opens or plays the highlighted tile and Space
    /// shows or hides the details of a video.
    private func press(_ key: GridKey, tiles: [KeyTile], columns: Int, proxy: ScrollViewProxy) -> Bool {
        // Edit mode has its own shortcuts, and the search field and sheets take the keys themselves.
        guard selectionShortcuts, selection == nil, coverCollection == nil, !tiles.isEmpty else { return false }
        let current = model.visit.selectedTile.flatMap { selected in tiles.firstIndex { $0.tile == selected } }
        switch key {
        case .left, .right, .up, .down:
            let step = key == .left ? -1 : key == .right ? 1 : key == .up ? -columns : columns
            var target = 0
            if let current {
                target = current + step
                // The last row may be shorter. Down from the row above it goes to the last tile.
                if key == .down, target >= tiles.count, current / columns < (tiles.count - 1) / columns { target = tiles.count - 1 }
                guard tiles.indices.contains(target) else { return true }
            }
            model.highlight(tiles[target].tile)
            proxy.scrollTo(tiles[target].scrollID)
            return true
        case .activate:
            guard let current else { return false }
            tiles[current].activate()
            return true
        case .details:
            guard let current, case let .video(id) = tiles[current].tile else { return false }
            if model.detailID == id { model.goBack() } else { model.openDetail(id) }
            return true
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
        let keyTiles: [KeyTile]
        if !collections.isEmpty {
            keyTiles = collections.map { collection in
                KeyTile(tile: collection.tile, scrollID: collection.id) { model.browse(collection.shelf, from: collection.tile) }
            }
        } else if studioIndex {
            keyTiles = studios.map { item in
                let tile = BrowseTile.studio(item.studio.name, siteID: item.studio.siteID)
                return KeyTile(tile: tile, scrollID: item.id) {
                    model.browse(.studio(item.studio.name, siteID: item.studio.siteID), from: tile)
                }
            }
        } else {
            keyTiles = records.map { entry in
                KeyTile(tile: .video(entry.id), scrollID: entry.id) {
                    if LibraryModel.cinemaPlayable(entry) { model.play(entry) } else { model.openDetail(entry.id) }
                }
            }
        }
        return ScrollViewReader { proxy in
            // The grid changes with every update, so the key handler is renewed with it.
            let _ = keyboard.handle = { press($0, tiles: keyTiles, columns: columns.count, proxy: proxy) }
            ScrollView {
            VStack(alignment: .leading, spacing: VSpace.section) {
                // Edit mode names the collection and its count in the selection bar.
                if selection != nil {
                    if !model.visit.filters.isEmpty { FilterChips(filters: model.filterBinding) }
                } else {
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
                                        // Moving a video changes the playlist's own sequence.
                                        let sequence = model.videoSort == .collection
                                        Button("Move Earlier") { move(entry, by: -1, among: records, playlist: id) }
                                            .disabled(!sequence || records.first?.id == entry.id)
                                        Button("Move Later") { move(entry, by: 1, among: records, playlist: id) }
                                            .disabled(!sequence || records.last?.id == entry.id)
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
        .onChange(of: model.detailID == nil) {
            // Details opening or closing beside the grid changes its columns.
            // Keep the video they belong to in view.
            guard case let .video(id) = model.visit.selectedTile else { return }
            DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
        }
        .onAppear {
            // The restored offset may have been saved at another width of the grid, with the
            // details open or closed. Bring the video the visit returns to into view, after
            // the scroll anchor has restored the offset. A visible tile does not move.
            guard case let .video(id) = model.visit.selectedTile else { return }
            DispatchQueue.main.async { DispatchQueue.main.async { proxy.scrollTo(id) } }
        }
        }
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
                    tileCaption(entry, underlined: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected.contains(entry.id) ? .isSelected : [])
        } else {
            let playable = LibraryModel.cinemaPlayable(entry)
            let action = playable ? (entry.resume > 0 ? "Resume" : "Play") : "Details"
            VStack(alignment: .leading, spacing: VSpace.tight) {
                // Hover state lives in each tile, so pointer movement does not re-evaluate the grid.
                Hovering { hovered in
                    Button {
                        if playable { model.play(entry) } else { model.openDetail(entry.id) }
                    } label: {
                        poster(entry, tile: tile)
                            .overlay(alignment: .topTrailing) {
                                if playable && hovered {
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
                    .accessibilityValue(tileFacts(entry))
                }
                Hovering { hovered in
                    Button { model.openDetail(entry.id) } label: {
                        tileCaption(entry, underlined: hovered)
                    }
                    .focused($focusedTitle, equals: entry.id)
                    .help("Show details")
                    // The tile Return plays, and the one Back returned to.
                    .accessibilityAddTraits(model.visit.selectedTile == tile ? .isSelected : [])
                    .accessibilityLabel("Details for \(entry.title)")
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// The poster badges in words.
    private func tileFacts(_ entry: CatalogEntry) -> String {
        var facts: [String] = []
        if entry.favorite { facts.append("Favorite") }
        if entry.rating != 0 { facts.append(entry.rating > 0 ? "Liked" : "Disliked") }
        if let duration = entry.duration { facts.append(clockLabel(duration) + " long") }
        if entry.resume > 0 { facts.append("resumes at " + clockLabel(entry.resume)) }
        return facts.joined(separator: ", ")
    }

    private func tileCaption(_ entry: CatalogEntry, underlined: Bool) -> some View {
        VStack(alignment: .leading, spacing: VSpace.unit) {
            Text(entry.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                .underline(underlined)
            if model.shelf == .frequent {
                Text(entry.viewingSummary).font(.subheadline).foregroundStyle(.secondary)
                if model.videoSort == .played, let played = entry.lastPlayed {
                    Text("Watched " + Date(timeIntervalSince1970: played).formatted(.relative(presentation: .named)))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
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
                // A studio tile borrows the poster of its first video, without that video's state.
                if tile == .video(entry.id) { TileBadges(entry: entry) }
            }
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
        // "Unknown Studio" under every tile of an unmatched library says nothing. Show what is known.
        let known = [entry.studio, entry.videoInfo?.quality].compactMap { $0 }
        return known.isEmpty ? nil : known.joined(separator: " · ")
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

/// What a tile says about its video at a glance: reactions, duration and the resume position.
private struct TileBadges: View {
    let entry: CatalogEntry

    private var progress: Double? {
        guard entry.resume > 0, let duration = entry.duration, duration > 0 else { return nil }
        return min(1, entry.resume / duration)
    }

    var body: some View {
        // The resume line lies under the badges, so they sit at the same height on every tile.
        ZStack(alignment: .bottom) {
            HStack(alignment: .bottom, spacing: VSpace.unit) {
                if entry.favorite || entry.rating != 0 {
                    // The dark-appearance tints, for contrast on the dark badge in both appearances.
                    HStack(spacing: 3) {
                        if entry.favorite {
                            Image(systemName: "heart.fill").foregroundStyle(VideoReaction.favorite.tint(in: .dark))
                        }
                        if entry.rating > 0 {
                            Image(systemName: "hand.thumbsup.fill").foregroundStyle(VideoReaction.like.tint(in: .dark))
                        } else if entry.rating < 0 {
                            Image(systemName: "hand.thumbsdown.fill").foregroundStyle(VideoReaction.dislike.tint(in: .dark))
                        }
                    }
                    .modifier(TileBadge())
                }
                Spacer(minLength: 0)
                if let duration = entry.duration {
                    Text(clockLabel(duration)).monospacedDigit().foregroundStyle(.white).modifier(TileBadge())
                }
            }
            .padding(6)
            if let progress {
                Rectangle().fill(.black.opacity(0.55)).frame(height: 3)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.tint).scaleEffect(x: progress, y: 1, anchor: .leading)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .clipShape(RoundedRectangle(cornerRadius: VSpace.tight, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TileBadge: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.black.opacity(0.72), in: Capsule())
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
    /// The image this tile shows. The view keeps it alive while the cache may drop it.
    @State private var held: (source: Sources, image: NSImage)?
    @State private var revision = 0

    /// Where the artwork of an entry can come from, in order of preference.
    private struct Sources: Equatable {
        var imported: String?
        var remote: URL?
        var directory: URL
        var revision = 0

        var importedKey: String? { imported.map { "poster:" + $0 } }
        var remoteKey: String? { remote.map { "url:" + $0.absoluteString } }
        var stillKey: String { "still:" + directory.path }
    }

    var body: some View {
        let directory = model.previewDirectory(entry)
        let sources = Sources(imported: entry.posterRevision.map { "\(entry.id):" + $0 },
                              remote: entry.posterRevision == nil ? model.artworkURL(entry.match?.previewURL) : nil,
                              directory: directory, revision: revision)
        // An image decoded earlier appears together with the tile.
        let cache = ArtworkCache.shared
        let image = (held?.source == sources ? held?.image : nil)
            ?? sources.importedKey.flatMap(cache.image) ?? sources.remoteKey.flatMap(cache.image)
            ?? (sources.imported == nil ? cache.image(sources.stillKey) : nil)
        Rectangle().fill(.quaternary.opacity(0.5))
            .aspectRatio(16/9, contentMode: .fit)
            .overlay {
                if let image { Image(nsImage: image).resizable().scaledToFill() }
                else if sources.imported == nil { Image(systemName: "film").font(.title).foregroundStyle(.tertiary) }
            }.clipped()
            .overlay {
                if scrubbable {
                    PosterScrubber(directory: directory, revision: revision)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: VSpace.tight, style: .continuous))
            .onReceive(model.posterPrepared) { ready in
                guard ready == directory else { return }
                cache.remove(sources.stillKey)
                revision &+= 1
            }
            .task(id: sources) { await load(sources) }
            .accessibilityHidden(true)
    }

    private func load(_ sources: Sources) async {
        let cache = ArtworkCache.shared
        if let key = sources.importedKey {
            let catalog = model.catalog, id = entry.id
            if let image = await cache.load(key, data: { try? catalog?.importedPoster(entryID: id) }), !Task.isCancelled {
                held = (sources, image)
            }
            return
        }
        // Show the local still until the PRDB preview has loaded, and keep it when there is none.
        let still = PreviewCache.posterURL(in: sources.directory)
        if sources.remoteKey.flatMap(cache.image) == nil,
           let image = await cache.load(sources.stillKey, data: { try? Data(contentsOf: still) }), !Task.isCancelled {
            held = (sources, image)
        }
        if let key = sources.remoteKey, let url = sources.remote,
           let image = await cache.load(key, data: { await ArtworkCache.fetch(url) }), !Task.isCancelled {
            held = (sources, image)
        }
    }
}

/// Tracks the pointer for one control without invalidating its parent view.
private struct Hovering<Content: View>: View {
    @State private var hovered = false
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(hovered).onHover { hovered = $0 }
    }
}
