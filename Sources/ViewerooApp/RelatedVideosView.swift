import SwiftUI
import ViewerooCore

struct CinemaSuggestions: View {
    let model: LibraryModel
    let entry: CatalogEntry
    let queue: [CatalogEntry]
    let limit: Int
    let onSelect: (CatalogEntry) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let suggestions = RelatedVideo.suggestions(for: entry, in: queue).prefix(limit)
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: VSpace.tight) {
                Text("More to Watch")
                    .font(.headline)
                    .modifier(CinemaCaption())
                    .padding(.horizontal, VSpace.unit)
                    .accessibilityAddTraits(.isHeader)
                ForEach(suggestions) { suggestion in
                    RelatedVideoButton(model: model, suggestion: suggestion) {
                        onSelect(suggestion.entry)
                    }
                }
            }
            .padding(VSpace.control)
            .frame(width: 244)
            .background {
                if reduceTransparency || contrast == .increased {
                    RoundedRectangle(cornerRadius: VSpace.control).fill(.black)
                }
            }
        }
    }
}

private struct CinemaCaption: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .shadow(color: .black, radius: 0.8)
            .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
    }
}

private struct RelatedVideoButton: View {
    let model: LibraryModel
    let suggestion: RelatedVideo
    let select: () -> Void
    @State private var hovered = false

    private var subtitle: String? { suggestion.entry.studio }

    var body: some View {
        Button(action: select) {
            HStack(spacing: VSpace.control) {
                Poster(model: model, entry: suggestion.entry).frame(width: 68)
                caption.modifier(CinemaCaption())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(VSpace.unit)
            .background(.white.opacity(hovered ? 0.14 : 0), in: RoundedRectangle(cornerRadius: VSpace.tight))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            EntryReaction(model: model, entry: suggestion.entry, reaction: .favorite, inMenu: true)
        }
        .onHover { hovered = $0 }
        .help("Play \(suggestion.entry.title)")
        .accessibilityLabel(Text("Play \(suggestion.entry.title)"))
        .accessibilityValue(Text(subtitle ?? ""))
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: VSpace.unit) {
            Text(suggestion.entry.title)
                .font(.body.weight(.semibold)).lineLimit(2)
                .multilineTextAlignment(.leading)
            if let subtitle {
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
    }
}
