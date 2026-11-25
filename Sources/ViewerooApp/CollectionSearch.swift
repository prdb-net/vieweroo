import SwiftUI
import ViewerooCore

enum StudioGroup: Hashable {
    case all, custom, classic, platform(String)

    var label: String {
        switch self {
        case .all: "All Studios"
        case .custom: "My Studios"
        case .classic: "PRDB Studios"
        case let .platform(name): name
        }
    }

    func includes(_ studio: StudioOption) -> Bool {
        switch self {
        case .all: true
        case .custom: studio.isCustom
        case .classic: !studio.isCustom && studio.creator == nil && studio.name != "Unknown Studio"
        case let .platform(name): studio.creator?.platform == name
        }
    }
}

enum CollectionFilter: String, CaseIterable {
    case favoriteStudios = "Favorite studios"
    case favoriteVideos = "Favorite videos"
    case liked = "Liked videos"
    case available = "Available videos"
    case unplayed = "Unplayed videos"
    case populated = "With videos"
    case offline = "Offline folders"
}

struct CollectionFilters: Equatable {
    var selected: Set<CollectionFilter> = []
    var group = StudioGroup.all
    var qualities: Set<String> = []
    // Key studios by catalog identity and tags by their case-insensitive name.
    // Keep the display labels so chips can still be removed after a catalog edit.
    var studios: [String: String] = [:]
    var tags: [String: String] = [:]
    var isEmpty: Bool { selected.isEmpty && group == .all && qualities.isEmpty && studios.isEmpty && tags.isEmpty }

    func includes(_ tag: CatalogTag, term: String) -> Bool {
        (!selected.contains(.populated) || !tag.memberIDs.isEmpty)
            && (term.isEmpty || tag.name.localizedCaseInsensitiveContains(term))
    }

    func includes(_ playlist: CatalogPlaylist, term: String) -> Bool {
        (!selected.contains(.populated) || playlist.videoCount > 0)
            && (term.isEmpty || playlist.name.localizedCaseInsensitiveContains(term))
    }

    func includes(_ studio: StudioOption, favorites: Set<String>, term: String) -> Bool {
        guard group.includes(studio), !selected.contains(.favoriteStudios) || favorites.contains(studio.id) else { return false }
        return term.isEmpty || [studio.name, studio.creator?.platform, studio.creator?.handle.map { "@" + $0 }]
            .contains { $0?.localizedCaseInsensitiveContains(term) == true }
    }

    func includes(_ entry: CatalogEntry, directory: StudioDirectory, term: String) -> Bool {
        guard !selected.contains(.favoriteVideos) || entry.favorite,
              !selected.contains(.liked) || entry.rating > 0,
              !selected.contains(.available) || entry.availability == .available,
              !selected.contains(.unplayed) || entry.playCount == 0,
              qualities.isEmpty || qualities.contains(entry.videoInfo?.quality ?? "Unknown"),
              tags.isEmpty || entry.tags.contains(where: { tags[$0.lowercased()] != nil }) else { return false }
        if studios.isEmpty && term.isEmpty { return true }
        let studio = directory.studio(for: entry)
        guard studios.isEmpty || studios[studio.id] != nil else { return false }
        guard !term.isEmpty else { return true }
        let fields = [entry.title, entry.filename, studio.name, studio.creator?.platform, studio.creator?.handle.map { "@" + $0 }]
        return fields.contains { $0?.localizedCaseInsensitiveContains(term) == true }
            || entry.tags.contains { $0.localizedCaseInsensitiveContains(term) }
            || entry.match?.performers.contains { $0.name.localizedCaseInsensitiveContains(term) } == true
    }
}

extension Shelf {
    var supportsBulkEdit: Bool {
        switch self {
        case .all, .favorites, .liked, .frequent, .tag, .playlist, .playlists, .studio, .performer: true
        default: false
        }
    }

    var searchPrompt: String? {
        switch self {
        case .tags: "Search tags"
        case .tag: "Search this tag’s videos"
        case .studios: "Search studios"
        case .all: "Search videos"
        case .favorites: "Search favorites"
        case .liked: "Search liked videos"
        case .frequent: "Search watch history"
        case .studio: "Search this studio’s videos"
        case .performer: "Search this performer’s videos"
        case .playlist: "Search this playlist"
        case .playlists: "Search playlists"
        case .sources: "Search folders"
        case .settings: nil
        }
    }

    var isVideoCollection: Bool {
        switch self {
        case .all, .favorites, .liked, .frequent, .studio, .performer, .playlist, .tag: true
        case .studios, .playlists, .sources, .settings, .tags: false
        }
    }

    var filterOptions: [CollectionFilter] {
        switch self {
        case .studios: [.favoriteStudios]
        case .playlists, .tags: [.populated]
        case .sources: [.offline]
        case .favorites: [.liked, .available, .unplayed]
        case .liked: [.favoriteVideos, .available, .unplayed]
        case .frequent: [.favoriteVideos, .liked, .available]
        case .settings: []
        default: [.favoriteVideos, .liked, .available, .unplayed]
        }
    }
}

struct CollectionSearchField: View {
    let prompt: String
    @Binding var text: String
    var focusChanged: (Bool) -> Void = { _ in }
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: VSpace.unit) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain).focused($focused)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button {
                    text = ""
                    focused = true
                } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Clear search").help("Clear search")
            }
        }
        .padding(.horizontal, VSpace.tight).padding(.vertical, VSpace.unit)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Color.accentColor : Color.secondary.opacity(0.45)) }
        .onChange(of: focused) { focusChanged(focused) }
        .focusedSceneValue(\.librarySearch, Binding(get: { focused }, set: { focused = $0 }))
    }
}

struct FiltersButton: View {
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .help("Filters").accessibilityLabel("Filters")
    }
}

struct CollectionFilterButton: View {
    let shelf: Shelf
    var platforms: [String] = []
    @Binding var filters: CollectionFilters
    @State private var open = false

    var body: some View {
        FiltersButton(active: !filters.isEmpty) { open.toggle() }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: VSpace.control) {
                Text("Filters").font(.headline)
                ForEach(shelf.filterOptions, id: \.self) { option in
                    Toggle(option.rawValue, isOn: Binding(get: { filters.selected.contains(option) }, set: { enabled in
                        if enabled { filters.selected.insert(option) } else { filters.selected.remove(option) }
                    }))
                }
                if shelf == .studios {
                    Picker("Group", selection: $filters.group) {
                        ForEach([StudioGroup.all, .custom, .classic] + platforms.map(StudioGroup.platform), id: \.self) { group in
                            Text(group.label).tag(group)
                        }
                    }
                }
            }.padding(VSpace.group).frame(minWidth: 200, alignment: .leading)
        }
    }
}

struct FilterChips: View {
    @Binding var filters: CollectionFilters

    var body: some View {
        ChipRows {
            ForEach(CollectionFilter.allCases.filter(filters.selected.contains), id: \.self) { option in
                chip(option.rawValue) { filters.selected.remove(option) }
            }
            ForEach(VideoFilterChoices.qualities.filter(filters.qualities.contains), id: \.self) { quality in
                chip(quality) { filters.qualities.remove(quality) }
            }
            ForEach(filters.studios.keys.sorted { filters.studios[$0, default: ""] < filters.studios[$1, default: ""] }, id: \.self) { id in
                chip(filters.studios[id, default: id]) { filters.studios.removeValue(forKey: id) }
            }
            ForEach(filters.tags.keys.sorted(), id: \.self) { id in
                chip(filters.tags[id, default: id]) { filters.tags.removeValue(forKey: id) }
            }
            if filters.group != .all {
                chip(filters.group.label) { filters.group = .all }
            }
        }.font(.callout)
    }

    private func chip(_ label: String, remove: @escaping () -> Void) -> some View {
        MetadataChip(name: label, removeLabel: "Remove filter: " + label, remove: remove)
    }
}

struct CollectionHeading<Actions: View>: View {
    let title: String
    let count: String
    @Binding var filters: CollectionFilters
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: VSpace.tight) {
                heading.fixedSize(horizontal: true, vertical: false)
                if !filters.isEmpty { FilterChips(filters: $filters).fixedSize() }
                Spacer(minLength: 0)
                actions().fixedSize()
            }
            VStack(alignment: .leading, spacing: VSpace.tight) {
                HStack { heading; Spacer(minLength: 0); actions().fixedSize() }
                if !filters.isEmpty { FilterChips(filters: $filters) }
            }
        }
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: VSpace.tight) {
            Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader).textSelection(.enabled)
            Text(count).font(.callout.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
        }
    }
}

extension LibraryModel {
    var filterBinding: Binding<CollectionFilters> {
        Binding(get: { self.visit.filters }, set: { self.setFilters($0) })
    }

    var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var narrowed: Bool { !searchTerm.isEmpty || !visit.filters.isEmpty }
}
