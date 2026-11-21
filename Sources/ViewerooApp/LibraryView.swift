import SwiftUI
import ViewerooCore

private enum EditSheet: String, Identifiable {
    case library, playlist, privacy
    var id: Self { self }
}

struct LibraryView: View {
    @Bindable var model: LibraryModel
    let windowTitle: String
    @State private var sheet: EditSheet?
    @State private var deleteLibrary = false

    var body: some View {
        ZStack {
            navigation
                .opacity(model.playing ? 0 : 1)
                .disabled(model.playing)
                .allowsHitTesting(!model.playing)
                .accessibilityHidden(model.playing)

            if model.playing {
                PlayerScreen(model: model)
                    .background(.background)
            }
        }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .privacy: PrivacyView(model: model)
            case .library, .playlist:
                NameForm(isLibrary: kind == .library) { name, onFailure in
                    if kind == .library { return model.createLibrary(name, onFailure: onFailure) }
                    guard let id = model.libraryID else { return false }
                    return model.change("Playlist created", onFailure: onFailure) { db in
                        model.shelf = .playlist(try db.createPlaylist(libraryID: id, name: name).id)
                    }
                }
            }
        }
        .alert("Delete this library?", isPresented: $deleteLibrary) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Library", role: .destructive) { model.deleteLibrary() }
        } message: { Text("This removes the library’s catalog, playlists, and viewing history. Your video files stay on disk.") }
    }

    private var navigation: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 175, ideal: 208, max: 285)
        } detail: {
            if model.libraryID == nil {
                ContentUnavailableView {
                    Label("Create your first library", systemImage: "rectangle.stack")
                } description: {
                    Text("Group videos from one or more folders into a library.")
                } actions: { Button("New Library…") { sheet = .library }.buttonStyle(.borderedProminent) }
            } else {
                ZStack {
                    if model.shelf == .sources && model.query.isEmpty {
                        SourcesView(model: model)
                    } else {
                        BrowserView(model: model)
                            .disabled(model.detailID != nil)
                            .accessibilityHidden(model.detailID != nil)
                    }
                    if let id = model.detailID, let entry = model.entries.first(where: { $0.id == id }) {
                        EntryView(model: model, entry: entry).id(id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.background)
                    }
                }
            }
        }
        .overlay(alignment: .top) { Divider().allowsHitTesting(false).accessibilityHidden(true) }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search library")
        .onChange(of: model.query) { model.detailID = nil }
        .onChange(of: model.shelf) { model.detailID = nil; model.query = ""; model.loadPlaylist() }
        .onChange(of: model.libraryID) { sheet = nil }
        .toolbar {
            libraryTitle
            ToolbarItemGroup {
                if model.libraryID != nil {
                    Button { model.pickSource() } label: { Label("Add Source Folder", systemImage: "folder.badge.plus") }
                        .help("Add Source Folder")
                }
                if model.pinEnabled {
                    Button { model.lock() } label: { Label("Lock Vieweroo", systemImage: "lock") }.help("Lock Vieweroo")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var libraryTitle: some ToolbarContent {
        let title = Text(windowTitle).font(.headline).lineLimit(1).padding(.trailing, VSpace.tight)
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            // Ungrouped toolbar items already have a 4 pt leading margin.
            ToolbarItem(placement: .navigation) {
                title.padding(.leading, VSpace.section - VSpace.unit)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { title.padding(.leading, VSpace.group) }
        }
        #else
        ToolbarItem(placement: .navigation) { title.padding(.leading, VSpace.group) }
        #endif
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Menu {
                ForEach(model.libraries) { library in
                    Button { model.selectLibrary(library.id) } label: {
                        if library.id == model.libraryID { Label(library.name, systemImage: "checkmark") } else { Text(library.name) }
                    }
                }
                Divider()
                Button("New Library…") { sheet = .library }
                if model.libraryID != nil { Button("Delete Current Library…", role: .destructive) { deleteLibrary = true } }
            } label: {
                Label(model.libraries.first { $0.id == model.libraryID }?.name ?? "Libraries", systemImage: "rectangle.stack")
                    .lineLimit(1).font(.headline)
            }.menuStyle(.borderlessButton).padding(VSpace.group)
            List(selection: $model.shelf) {
                Section("Library") {
                    Label("Studios", systemImage: "square.grid.2x2").tag(Shelf.studios)
                    Label("All Videos", systemImage: "film.stack").tag(Shelf.all)
                    Label("Favorites", systemImage: "heart").tag(Shelf.favorites)
                    Label("Liked", systemImage: "hand.thumbsup").tag(Shelf.liked)
                    Label("Frequently Watched", systemImage: "clock.arrow.circlepath").tag(Shelf.frequent)
                    Label("Source Folders", systemImage: "folder").tag(Shelf.sources)
                }
                Section {
                    ForEach(model.playlists) { item in Label(item.name, systemImage: "list.and.film").tag(Shelf.playlist(item.id)) }
                    Button { sheet = .playlist } label: { Label("New Playlist…", systemImage: "plus") }.buttonStyle(.plain)
                } header: { Text("Playlists") }
            }.listStyle(.sidebar).disabled(model.libraryID == nil)
            if let activity = model.activity {
                HStack { ProgressView().controlSize(.small); Text(activity).font(.caption); Spacer() }.padding(VSpace.control)
            }
            if let notice = model.networkStatus { Text(notice).font(.caption).foregroundStyle(.secondary).padding(VSpace.control) }
            Divider()
            HStack {
                Button { sheet = .privacy } label: { Label("Privacy", systemImage: "lock.shield") }.buttonStyle(.plain)
                Spacer()
                Button { model.refresh() } label: { Label("Refresh Library", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                    .buttonStyle(.plain).disabled(model.libraryID == nil || model.scanBusy).help("Refresh Library")
            }.padding(VSpace.group)
        }
    }
}

struct NameForm: View {
    @Environment(\.dismiss) var dismiss
    let isLibrary: Bool
    let save: (String, @escaping (String) -> Void) -> Bool
    @State private var name = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: VSpace.group) {
            Text(isLibrary ? "New Library" : "New Playlist").font(.title2.bold())
            TextField("Name", text: $name)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if save(clean, { error = $0 }) { dismiss() }
                }
                .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(VSpace.section).frame(width: 340)
    }
}

struct PrivacyView: View {
    @Environment(\.dismiss) var dismiss
    @Bindable var model: LibraryModel
    @State private var current = ""
    @State private var next = ""
    @State private var removing = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: VSpace.group) {
            Text("PIN Protection").font(.title2.bold())
            Text("Require a PIN at launch and use Shift–Command–L to lock during playback.")
                .foregroundStyle(.secondary)
            if model.pinEnabled {
                SecureField("Current PIN", text: $current)
                Toggle("Turn off PIN protection", isOn: $removing)
            }
            if !removing { SecureField("New PIN (4–12 digits)", text: $next) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try model.access.setPIN(current: model.pinEnabled ? current : nil, new: removing ? nil : next)
                        model.pinEnabled = try model.access.hasPIN
                        model.notify(removing ? "PIN protection turned off" : "PIN saved")
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(VSpace.section).frame(width: 380)
    }
}
