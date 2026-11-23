import SwiftUI
import ViewerooCore

struct CoverCollection: Identifiable, Sendable {
    let id: CoverCollectionID
    let name: String
    let memberIDs: [Int64]
    let cover: CatalogCover?

    let tile: BrowseTile
    let shelf: Shelf
    let symbol: String

    init(_ tag: CatalogTag) {
        id = .tag(tag.id)
        name = tag.name
        memberIDs = tag.memberIDs
        cover = tag.cover
        tile = .tag(tag.id)
        shelf = .tag(tag.id)
        symbol = "tag"
    }

    init(_ playlist: CatalogPlaylist) {
        id = .playlist(playlist.id)
        name = playlist.name
        memberIDs = playlist.orderedMemberIDs
        cover = playlist.cover
        tile = .playlist(playlist.id)
        shelf = .playlist(playlist.id)
        symbol = "list.and.film"
    }

    init(studio: StudioOption, libraryID: Int64, memberIDs: [Int64], cover: CatalogCover?) {
        id = .studio(libraryID: libraryID, studioID: studio.id)
        name = studio.name
        self.memberIDs = memberIDs
        self.cover = cover
        tile = .studio(studio.name, siteID: studio.siteID)
        shelf = .studio(studio.name, siteID: studio.siteID)
        symbol = "film.stack"
    }

    var videoCountLabel: String { memberIDs.count == 1 ? "1 video" : "\(memberIDs.count) videos" }
}

struct CollectionCoverTile: View {
    let model: LibraryModel
    let collection: CoverCollection
    @Binding var selection: Set<Int64>?
    let chooseCover: () -> Void

    var body: some View {
        let checked: Bool? = if case let .playlist(id) = collection.id { selection?.contains(id) } else { nil }
        let selected = checked ?? (model.visit.selectedTile == collection.tile)
        Button {
            if case let .playlist(id) = collection.id, let checked {
                NSApp.keyWindow?.makeFirstResponder(nil)
                if checked { selection?.remove(id) } else { selection?.insert(id) }
            } else {
                model.browse(collection.shelf, from: collection.tile)
            }
        } label: {
            VStack(alignment: .leading, spacing: VSpace.tight) {
                CollectionCoverImage(model: model, id: collection.id, cover: collection.cover, symbol: collection.symbol)
                    .overlay {
                        if selected { RoundedRectangle(cornerRadius: VSpace.tight).strokeBorder(Color.accentColor, lineWidth: 2) }
                    }
                    .overlay(alignment: .topTrailing) { if let checked { SelectionCheckmark(checked: checked) } }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: VSpace.unit) {
                    Text(collection.name).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                    Text(collection.videoCountLabel).font(.subheadline).foregroundStyle(.secondary)
                }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if checked == nil { Button("Choose Cover…", action: chooseCover).disabled(collection.memberIDs.isEmpty) }
        }
    }
}

struct CollectionCoverImage: View {
    let model: LibraryModel
    let id: CoverCollectionID
    let cover: CatalogCover?
    let symbol: String
    @State private var image: NSImage?

    var body: some View {
        RoundedRectangle(cornerRadius: VSpace.tight).fill(.quaternary.opacity(0.5))
            .aspectRatio(16/9, contentMode: .fit)
            .overlay {
                if let image { Image(nsImage: image).resizable().scaledToFill() }
                else { Image(systemName: symbol).font(.title).foregroundStyle(.secondary) }
            }
            .clipShape(RoundedRectangle(cornerRadius: VSpace.tight))
            .task(id: cover?.revision) {
                guard cover != nil else { image = nil; return }
                let bytes = try? await model.catalog?.coverImage(id)
                if !Task.isCancelled { image = bytes.flatMap(NSImage.init(data:)) }
            }
    }
}

struct SelectionCheckmark: View {
    let checked: Bool

    var body: some View {
        Image(systemName: checked ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.white, Color.accentColor)
            .background(.black.opacity(0.72), in: Circle())
            .padding(VSpace.tight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
