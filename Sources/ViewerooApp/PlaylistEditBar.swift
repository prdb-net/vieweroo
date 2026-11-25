import SwiftUI
import ViewerooCore

private enum PlaylistEdit: Identifiable {
    case create, rename(CatalogPlaylist), cover(CatalogPlaylist)
    var id: String {
        switch self {
        case .create: "create"
        case let .rename(playlist): "rename-\(playlist.id)"
        case let .cover(playlist): "cover-\(playlist.id)"
        }
    }
}

struct PlaylistEditBar: View {
    let model: LibraryModel
    let libraryID: Int64
    @Binding var selection: Set<Int64>?
    let shortcutsEnabled: Bool
    @State private var editing: PlaylistEdit?
    @State private var pendingDeletion: [CatalogPlaylist] = []

    var body: some View {
        let visible = model.visiblePlaylists
        let selected = visible.filter { selection?.contains($0.id) == true }
        let single = selected.count == 1 ? selected[0] : nil
        SelectionActionBar(title: "Playlists", selection: $selection, visibleIDs: visible.map(\.id), count: selected.count,
                           shortcutsEnabled: shortcutsEnabled && editing == nil && pendingDeletion.isEmpty) {
            IconActionButton(.add, "New Playlist…") { editing = .create }
            IconActionButton(.edit, "Rename Playlist…") {
                if let single { editing = .rename(single) }
            }
            .disabled(single == nil)
            Button("Choose Cover…", systemImage: "photo") {
                if let single { editing = .cover(single) }
            }
            .labelStyle(.iconOnly)
            .help("Choose Cover…")
            .disabled(single?.memberIDs.isEmpty != false)
            IconActionButton(.delete, "Delete Selected Playlists…") { pendingDeletion = selected }
                .disabled(selected.isEmpty)
        }
        .sheet(item: $editing) { edit in
            switch edit {
            case .create:
                NameForm(title: "New Playlist", name: model.searchTerm) { name, onFailure in
                    let saved = model.change("Playlist created", onFailure: onFailure) {
                        _ = try $0.createPlaylist(libraryID: libraryID, name: name)
                    }
                    if saved {
                        reveal(name, created: true)
                    }
                    return saved
                }
            case let .cover(playlist):
                CollectionCoverPicker(model: model, collection: CoverCollection(playlist))
            case let .rename(playlist):
                NameForm(title: "Rename Playlist", action: "Rename", name: playlist.name) { name, onFailure in
                    let saved = model.change("Playlist renamed", onFailure: onFailure) {
                        try $0.renamePlaylist(playlist.id, to: name)
                    }
                    if saved { reveal(name) }
                    return saved
                }
            }
        }
        .alert(deletionTitle, isPresented: Binding(
            get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } }
        ), presenting: pendingDeletion) { playlists in
            Button("Cancel", role: .cancel) {}
            Button(playlists.count == 1 ? "Delete Playlist" : "Delete Playlists", role: .destructive) {
                if model.change(playlists.count == 1 ? "Playlist deleted" : "\(playlists.count) playlists deleted", {
                    try $0.deletePlaylists(in: libraryID, ids: Set(playlists.map(\.id)))
                }) { selection = [] }
            }
        } message: { _ in Text("All videos will remain in the library.") }
    }

    private var deletionTitle: String {
        if pendingDeletion.count == 1 { return "Delete “\(pendingDeletion[0].name)”?" }
        return "Delete \(pendingDeletion.count) playlists?"
    }

    private func reveal(_ name: String, created: Bool = false) {
        var filters = model.visit.filters
        if created { filters.selected.remove(.populated) }
        let query = name.localizedCaseInsensitiveContains(model.searchTerm) || model.searchTerm.isEmpty ? model.query : name
        model.refine(query: query, filters: filters)
    }
}
