import SwiftUI
import ViewerooCore

private enum PlaylistEdit: Identifiable {
    case create, rename(CatalogPlaylist)
    var id: Int64? {
        if case let .rename(playlist) = self { return playlist.id }
        return nil
    }
}

struct PlaylistManagerView: View {
    let model: LibraryModel
    let libraryID: Int64
    @Environment(\.dismiss) private var dismiss
    @State private var editing: PlaylistEdit?
    @State private var pendingDeletion: CatalogPlaylist?
    @State private var confirmingDeletion = false
    @State private var query = ""
    @State private var filters = CollectionFilters()
    @State private var error: String?

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let matches = model.playlists.filter { filters.includes($0, term: term) }
        VStack(alignment: .leading, spacing: VSpace.control) {
            HStack {
                Text("Manage Playlists").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                IconActionButton(.add, "New Playlist…") { editing = .create }
            }
            HStack(spacing: VSpace.control) {
                CollectionSearchField(prompt: "Search playlists", text: $query)
                CollectionFilterButton(shelf: .playlists, filters: $filters)
            }
            if !filters.isEmpty { FilterChips(filters: $filters) }
            List(matches) { playlist in
                HStack {
                    Text(playlist.name).lineLimit(2).help(playlist.name)
                    Spacer()
                    Text(playlist.videoCount == 1 ? "1 video" : "\(playlist.videoCount) videos")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    IconActionButton(.edit, "Rename Playlist…", targetLabel: "Rename Playlist “\(playlist.name)”") {
                        editing = .rename(playlist)
                    }
                    .buttonStyle(.bordered)
                    IconActionButton(.delete, "Delete Playlist…", targetLabel: "Delete Playlist “\(playlist.name)”") {
                        pendingDeletion = playlist
                        confirmingDeletion = true
                    }
                    .buttonStyle(.bordered)
                }.padding(.vertical, VSpace.unit)
            }
            .listStyle(.inset)
            .overlay {
                if matches.isEmpty {
                    Text(term.isEmpty && filters.isEmpty ? "No playlists yet" : "No matching playlists")
                        .foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(VSpace.section)
        .frame(minWidth: 600, idealWidth: 700, maxWidth: 1000, minHeight: 420, idealHeight: 525, maxHeight: 900)
        .sheet(item: $editing) { edit in
            switch edit {
            case .create:
                NameForm(title: "New Playlist", name: term) { name, onFailure in
                    let saved = model.change("Playlist created", onFailure: onFailure) {
                        _ = try $0.createPlaylist(libraryID: libraryID, name: name)
                    }
                    if saved {
                        filters.selected.remove(.populated)
                        reveal(name)
                    }
                    return saved
                }
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
        .alert("Delete “\(pendingDeletion?.name ?? "")”?", isPresented: $confirmingDeletion, presenting: pendingDeletion) { playlist in
            Button("Cancel", role: .cancel) {}
            Button("Delete Playlist", role: .destructive) {
                error = nil
                model.change("Playlist deleted", onFailure: { error = $0 }) { try $0.deletePlaylist(playlist.id) }
            }
        } message: { _ in Text("All videos will remain in the library.") }
    }

    private func reveal(_ name: String) {
        error = nil
        if !term.isEmpty && !name.localizedCaseInsensitiveContains(term) { query = name }
    }
}
