import SwiftUI

struct PlaylistsView: View {
    let model: LibraryModel

    var body: some View {
        let matches = model.visiblePlaylists
        VStack(alignment: .leading, spacing: VSpace.group) {
            CollectionHeading(title: "Playlists", count: matches.count == 1 ? "1 playlist" : "\(matches.count) playlists",
                              filters: model.filterBinding) {}
                .padding([.top, .horizontal], VSpace.section)

            if matches.isEmpty && model.narrowed {
                ContentUnavailableView("No matching playlists", systemImage: "magnifyingglass",
                                       description: Text("Try a different search or clear a filter."))
            } else if matches.isEmpty {
                ContentUnavailableView("No playlists yet", systemImage: "list.and.film",
                                       description: Text("Open Manage Playlists to create your first playlist."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(matches) { playlist in
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
