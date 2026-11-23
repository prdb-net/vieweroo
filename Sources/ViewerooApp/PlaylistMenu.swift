import SwiftUI
import ViewerooCore

struct PlaylistMenu: View {
    let model: LibraryModel
    let entryID: Int64
    var inContextMenu = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmation: UUID?

    var body: some View {
        if inContextMenu {
            Menu("Add to Playlist", systemImage: "text.badge.plus") { destinations }
                .disabled(model.playlists.isEmpty)
        } else {
            animatedMenu
        }
    }

    private var destinations: some View {
        ForEach(model.playlists) { playlist in
            if inContextMenu {
                // The checkmark reports membership. Activating either state is an add request.
                Toggle(playlist.name, isOn: Binding(
                    get: { playlist.memberIDs.contains(entryID) },
                    set: { _ in add(to: playlist) }
                ))
            } else {
                Button(playlist.name) { add(to: playlist) }
            }
        }
    }

    private var animatedMenu: some View {
        Menu {
            destinations
        } label: {
            Label {
                Text("Add to Playlist")
            } icon: {
                ZStack {
                    if let confirmation {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                            .id(confirmation)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    } else {
                        Image(systemName: "text.badge.plus")
                            .transition(.opacity)
                    }
                }
                .frame(width: 16)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: confirmation)
                .accessibilityHidden(true)
            }
        }
        .fixedSize()
        .disabled(model.playlists.isEmpty)
        .task(id: confirmation) {
            guard let current = confirmation else { return }
            do { try await Task.sleep(for: .milliseconds(1300)) } catch { return }
            if confirmation == current { confirmation = nil }
        }
    }

    private func add(to playlist: CatalogPlaylist) {
        var inserted = false
        let saved = model.change { inserted = try $0.addToPlaylist(playlist.id, entryID: entryID) }
        if !inContextMenu { confirmation = saved && inserted ? UUID() : nil }
        if saved {
            model.notify(inserted ? "Added to “\(playlist.name)”" : "Already in “\(playlist.name)”")
        }
    }
}
