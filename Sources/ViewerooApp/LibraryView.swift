import SwiftUI
import ViewerooCore

private enum EditSheet: String, Identifiable {
    case library, playlist, privacy, prdbKey
    var id: Self { self }
}

extension FocusedValues {
    @Entry var librarySearch: Binding<Bool>?
}

struct LibraryView: View {
    @Bindable var model: LibraryModel
    let windowTitle: String
    @State private var sheet: EditSheet?
    @State private var deleteLibrary = false
    @State private var columns = NavigationSplitViewVisibility.automatic
    @State private var searchPresented = false

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
            case .prdbKey: PRDBKeyForm(model: model)
            case .library, .playlist:
                NameForm(isLibrary: kind == .library) { name, onFailure in
                    if kind == .library { return model.createLibrary(name, onFailure: onFailure) }
                    guard let id = model.libraryID else { return false }
                    return model.change("Playlist created", onFailure: onFailure) { db in
                        model.browse(.playlist(try db.createPlaylist(libraryID: id, name: name).id))
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
                            EntryView(model: model, entry: entry)
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
        .toolbar { libraryTitle }
    }

    @ToolbarContentBuilder
    private var libraryTitle: some ToolbarContent {
        let title = Text(windowTitle).font(.headline).lineLimit(1).padding(.trailing, VSpace.tight)
            .allowsHitTesting(false)
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
            List(selection: Binding<Shelf?>(get: { model.shelf }, set: { if let shelf = $0 { model.browse(shelf) } })) {
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
            if let notice = model.networkStatus {
                VStack(alignment: .leading, spacing: VSpace.tight) {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                    if model.subscriptionRequired {
                        Button("Retry PRDB", action: model.retrySubscription)
                        Button("Change API Key…") { sheet = .prdbKey }
                    }
                }.padding(VSpace.control)
            }
            Divider()
            HStack {
                Button { sheet = .privacy } label: { Label("Privacy", systemImage: "lock.shield") }.buttonStyle(.plain)
                Spacer()
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

private struct PRDBKeyForm: View {
    @Environment(\.dismiss) private var dismiss
    let model: LibraryModel
    @State private var key = ""
    @State private var verifying = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: VSpace.group) {
            Text("Change PRDB API Key").font(.title2.bold())
            SecureField("New PRDB API key", text: $key).disabled(verifying)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                if verifying { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Verify and Save") { error = nil; verifying = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(verifying || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(VSpace.section).frame(width: 380)
        .task(id: verifying) {
            guard verifying else { return }
            defer { verifying = false }
            do { try await model.replacePRDBKey(key); dismiss() }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
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
