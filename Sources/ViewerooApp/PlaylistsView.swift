import SwiftUI

struct PlaylistsView: View {
    let model: LibraryModel
    let newPlaylist: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VSpace.group) {
            HStack {
                Text("Playlists").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("New Playlist…", action: newPlaylist)
            }
            .padding([.horizontal, .top], VSpace.section)

            if model.playlists.isEmpty {
                ContentUnavailableView("No playlists yet", systemImage: "list.and.film",
                                       description: Text("Create a playlist, then add videos from this library."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.playlists) { playlist in
                            let selected = model.visit.selectedTile == .playlist(playlist.id)
                            Button {
                                model.browse(.playlist(playlist.id), from: .playlist(playlist.id))
                            } label: {
                                HStack(spacing: VSpace.control) {
                                    Image(systemName: "list.and.film").foregroundStyle(.secondary)
                                    Text(playlist.name).font(.headline).lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                    Text(playlist.videoCount == 1 ? "1 video" : "\(playlist.videoCount) videos")
                                        .foregroundStyle(.secondary).monospacedDigit()
                                    Image(systemName: "chevron.right").font(.caption)
                                        .foregroundStyle(.tertiary).accessibilityHidden(true)
                                }
                                .padding(VSpace.control)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(selected ? Color.accentColor.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: VSpace.tight))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            Divider()
                        }
                    }
                    .padding(.horizontal, VSpace.section)
                    .background(BrowseScrollAnchor(position: model.visit.scroll))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
