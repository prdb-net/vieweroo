import SwiftUI
import ViewerooCore

struct PlaylistMenu: View {
    let model: LibraryModel
    let entryID: Int64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmation: UUID?

    var body: some View {
        Menu {
            ForEach(model.playlists) { playlist in
                Button(playlist.name) { add(to: playlist) }
            }
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
        confirmation = saved && inserted ? UUID() : nil
        if saved {
            model.notify(inserted ? "Added to “\(playlist.name)”" : "Already in “\(playlist.name)”")
        }
    }
}
