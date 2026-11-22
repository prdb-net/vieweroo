import SwiftUI
import ViewerooCore

private enum EditSheet: String, Identifiable {
    case library, playlists, settings, studios, videoFilters
    var id: Self { self }
}

extension FocusedValues {
    @Entry var librarySearch: Binding<Bool>?
    @Entry var showAppSettings: Binding<Bool>?
}

struct LibraryView: View {
    @Bindable var model: LibraryModel
    @StateObject private var playerWindow = PlayerWindow()
    @State private var bulkSelection: Set<Int64>?
    @State private var searchFocused = false
    @State private var sheet: EditSheet?
    @State private var columns = NavigationSplitViewVisibility.automatic

    var body: some View {
        ZStack {
            if model.playing && playerWindow.fullScreen {
                PlayerScreen(model: model, window: playerWindow)
                    .ignoresSafeArea()
            } else {
                navigation
            }
        }
        .background {
            if model.playing {
                PlayerWindowReader(presentation: playerWindow)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .focusedSceneValue(\.showAppSettings, sheet == nil ? Binding(get: { false }, set: { show in
            if show { sheet = .settings }
        }) : nil)
        .sheet(item: $sheet) { kind in
            switch kind {
            case .settings: GeneralSettingsView(model: model)
            case .videoFilters: VideoFilterSheet(model: model)
            case .studios:
                if let id = model.libraryID { StudioDirectoryView(model: model, libraryID: id) }
            case .playlists:
                if let id = model.libraryID { PlaylistManagerView(model: model, libraryID: id) }
            case .library:
                NameForm(title: "New Library") { name, onFailure in
                    model.createLibrary(name, onFailure: onFailure)
                }
            }
        }
    }

    private var navigation: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar.navigationSplitViewColumnWidth(min: 175, ideal: 208, max: 285)
        } detail: {
            if model.libraryID == nil {
                ContentUnavailableView {
                    Label("Create your first library", systemImage: "rectangle.stack")
                } description: {
                    Text("Group videos from one or more folders into a library.")
                } actions: { Button("New Library…") { sheet = .library }.buttonStyle(.borderedProminent) }
            } else if model.loadingLibrary {
                ProgressView("Opening library…")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: VSpace.tight) {
                        backButton
                        Spacer()
                        if model.detailID == nil, let prompt = model.shelf.searchPrompt {
                            CollectionSearchField(prompt: prompt, text: Binding(get: { model.query }, set: model.search),
                                                  focusChanged: { searchFocused = $0 })
                                .frame(maxWidth: 230)
                            if model.shelf.isVideoCollection {
                                FiltersButton(active: !model.visit.filters.isEmpty) { sheet = .videoFilters }
                            } else {
                                CollectionFilterButton(shelf: model.shelf, platforms: model.shelf == .studios ? model.studioPlatforms : [],
                                                       filters: model.filterBinding)
                                    .id(model.shelf)
                            }
                            if [.favorites, .liked, .frequent].contains(model.shelf), bulkSelection == nil {
                                IconActionButton(.edit, "Edit \(model.collectionTitle)") {
                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                    bulkSelection = []
                                }
                                .disabled(model.visibleVideos.isEmpty)
                            }
                            if model.shelf == .studios {
                                manageButton("Manage Studios", sheet: .studios)
                            } else if model.shelf == .playlists {
                                manageButton("Manage Playlists", sheet: .playlists)
                            }
                        }
                    }
                    .padding(.horizontal, VSpace.section)
                    .padding(.top, VSpace.control)

                    Group {
                        if let id = model.detailID, let entry = model.entries.first(where: { $0.id == id }) {
                            EntryView(model: model, entry: entry, window: playerWindow)
                        } else if model.shelf == .playlists {
                            PlaylistsView(model: model)
                        } else if model.shelf == .settings,
                                  let library = model.libraries.first(where: { $0.id == model.libraryID }) {
                            LibrarySettingsView(model: model, library: library)
                        } else if model.shelf == .sources {
                            SourcesView(model: model)
                        } else {
                            BrowserView(model: model, selection: $bulkSelection,
                                        selectionShortcuts: !searchFocused && sheet == nil)
                        }
                    }
                    .id(model.visit.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .overlay(alignment: .top) { Divider().allowsHitTesting(false).accessibilityHidden(true) }
        .onChange(of: model.shelf) {
            bulkSelection = nil
            if sheet == .videoFilters { sheet = nil }
        }
        .onChange(of: model.detailID) { bulkSelection = nil }
        .onChange(of: model.libraryID) { sheet = nil; bulkSelection = nil }
        .toolbar {
            ToolbarItem(placement: .navigation) { libraryMenu }
        }
    }

    private func manageButton(_ title: String, sheet destination: EditSheet) -> some View {
        IconActionButton(.manage, title) { sheet = destination }
    }

    private var backButton: some View {
        Button(action: model.goBack) {
            Label("Back", systemImage: "chevron.left")
        }
        .labelStyle(.iconOnly)
        .keyboardShortcut("[", modifiers: .command, localization: .custom)
        .background {
            if model.detailID != nil {
                // SwiftUI assigns one shortcut per button. Keep Escape available on detail pages.
                Button("Back", action: model.goBack)
                    .keyboardShortcut(.escape, modifiers: [])
                    .focusable(false)
                    .opacity(0)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .help("Go Back (⌘[)")
        .disabled(!model.canGoBack)
    }

    private var libraryMenu: some View {
        let name = model.libraries.first { $0.id == model.libraryID }?.name ?? "Libraries"
        return Menu {
            ForEach(model.libraries) { library in
                Button { model.selectLibrary(library.id) } label: {
                    if library.id == model.libraryID { Label(library.name, systemImage: "checkmark") }
                    else { Text(library.name) }
                }
            }
            Divider()
            Button("New Library…") { sheet = .library }
        } label: {
            Text(name).font(.headline).lineLimit(1)
                .frame(maxWidth: 220)
                .fixedSize(horizontal: true, vertical: false)
        }
        .menuIndicator(.visible)
        .help("Switch library (\(name))")
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding<Shelf?>(get: { model.shelf == .sources ? .settings : model.shelf }, set: { if let shelf = $0 { model.browse(shelf) } })) {
                Section("Library") {
                    Label("Studios", systemImage: "square.grid.2x2").tag(Shelf.studios)
                    Label("All Videos", systemImage: "film.stack").tag(Shelf.all)
                    Label("Favorites", systemImage: "heart").tag(Shelf.favorites)
                    Label("Liked", systemImage: "hand.thumbsup").tag(Shelf.liked)
                    Label("Watch History", systemImage: "clock.arrow.circlepath").tag(Shelf.frequent)
                    Label("Playlists", systemImage: "list.and.film").tag(Shelf.playlists)
                    Label("Settings", systemImage: "gearshape").tag(Shelf.settings)
                }
                if !model.recentPlaylists.isEmpty {
                    Section("Recent Playlists") {
                        ForEach(model.recentPlaylists) { playlist in
                            Label(playlist.name, systemImage: "list.bullet")
                                .lineLimit(1)
                                .help(playlist.name)
                                .tag(Shelf.playlist(playlist.id))
                        }
                    }
                }
            }.listStyle(.sidebar).disabled(model.libraryID == nil)
            Divider()
            HStack(spacing: VSpace.tight) {
                LibraryActivityButton(model: model) { sheet = .settings }
                    .id(model.libraryID)
                if model.pinEnabled {
                    Button { model.lock() } label: { Label("Lock Vieweroo", systemImage: "lock").labelStyle(.iconOnly) }
                        .buttonStyle(.plain).help("Lock Vieweroo (⇧⌘L)")
                }
                IconActionButton(.refresh, "Refresh Library") { model.refresh() }
                    .buttonStyle(.plain).disabled(model.libraryID == nil || model.scanBusy)
            }.padding(VSpace.group)
        }
    }
}

struct NameForm: View {
    @Environment(\.dismiss) var dismiss
    let title: String
    let action: String
    let save: (String, @escaping (String) -> Void) -> Bool
    @State private var name: String
    @State private var error: String?
    init(title: String, action: String = "Create", name: String = "",
         save: @escaping (String, @escaping (String) -> Void) -> Bool) {
        self.title = title
        self.action = action
        _name = State(initialValue: name)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VSpace.group) {
            Text(title).font(.title2.bold())
            TextField("Name", text: $name)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action) {
                    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if save(clean, { error = $0 }) { dismiss() }
                }
                .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(VSpace.section).frame(width: 340)
    }
}
