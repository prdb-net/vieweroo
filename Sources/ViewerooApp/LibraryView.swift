import SwiftUI
import ViewerooCore

private enum EditSheet: String, Identifiable {
    case library, playlist, settings
    var id: Self { self }
}

extension FocusedValues {
    @Entry var showAppSettings: Binding<Bool>?
    @Entry var librarySearch: Binding<Bool>?
}

struct LibraryView: View {
    @Bindable var model: LibraryModel
    @StateObject private var playerWindow = PlayerWindow()
    @State private var sheet: EditSheet?
    @State private var columns = NavigationSplitViewVisibility.automatic
    @State private var searchPresented = false

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
            case .library, .playlist:
                NameForm(title: kind == .library ? "New Library" : "New Playlist") { name, onFailure in
                    if kind == .library { return model.createLibrary(name, onFailure: onFailure) }
                    guard let id = model.libraryID else { return false }
                    return model.change("Playlist created", onFailure: onFailure) { db in
                        model.browse(.playlist(try db.createPlaylist(libraryID: id, name: name).id))
                    }
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
                    Button(action: model.goBack) {
                        Label("Back", systemImage: "chevron.left")
                    }
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
                    .padding(.leading, VSpace.section)
                    .padding(.top, VSpace.section)

                    Group {
                        if let id = model.detailID, let entry = model.entries.first(where: { $0.id == id }) {
                            EntryView(model: model, entry: entry, window: playerWindow)
                        } else if model.shelf == .playlists && model.query.isEmpty {
                            PlaylistsView(model: model) { sheet = .playlist }
                        } else if model.shelf == .settings && model.query.isEmpty,
                                  let library = model.libraries.first(where: { $0.id == model.libraryID }) {
                            LibrarySettingsView(model: model, library: library)
                        } else if model.shelf == .sources && model.query.isEmpty {
                            SourcesView(model: model)
                        } else {
                            BrowserView(model: model)
                        }
                    }
                    .id(model.visit.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .overlay(alignment: .top) { Divider().allowsHitTesting(false).accessibilityHidden(true) }
        .searchable(text: Binding(get: { model.query }, set: { model.search($0) }),
                    isPresented: $searchPresented, placement: .sidebar, prompt: "Search library")
        .focusedSceneValue(\.librarySearch, Binding(get: { searchPresented }, set: { present in
            if present { columns = .all }
            searchPresented = present
        }))
        .onChange(of: model.libraryID) { sheet = nil }
        .toolbar {
            ToolbarItem(placement: .navigation) { libraryMenu }
        }
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
                    Label("Frequently Watched", systemImage: "clock.arrow.circlepath").tag(Shelf.frequent)
                    Label("Playlists", systemImage: "list.and.film").tag(Shelf.playlists)
                    Label("Library Settings", systemImage: "gearshape").tag(Shelf.settings)
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
                Button { model.refresh() } label: { Label("Refresh Library", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                    .buttonStyle(.plain).disabled(model.libraryID == nil || model.scanBusy).help("Refresh Library")
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
