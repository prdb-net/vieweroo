import SwiftUI
import ViewerooCore

struct RelatedVideosView: View {
    enum Style { case rail, shelf }

    let model: LibraryModel
    let current: CatalogEntry
    var style: Style = .rail
    let onSelect: (CatalogEntry) -> Void

    var body: some View {
        if model.phase == .ready, current.libraryID == model.libraryID {
            let suggestions = RelatedVideo.suggestions(for: current, in: model.entries)
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: VSpace.control) {
                    Text("More to Watch")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    switch style {
                    case .rail:
                        LazyVStack(alignment: .leading, spacing: VSpace.tight) {
                            choices(suggestions)
                        }
                    case .shelf:
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: VSpace.group) {
                                choices(suggestions)
                            }
                            .padding(.bottom, VSpace.tight)
                        }
                    }
                }
            }
        }
    }

    private func choices(_ suggestions: [RelatedVideo]) -> some View {
        ForEach(suggestions) { suggestion in
            RelatedVideoButton(model: model, suggestion: suggestion, style: style) {
                onSelect(suggestion.entry)
            }
        }
    }
}

struct CinemaSuggestions: View {
    let model: LibraryModel
    let entry: CatalogEntry
    let playlist: [CatalogEntry]
    let limit: Int
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let suggestions = RelatedVideo.suggestions(for: entry, in: playlist).prefix(limit)
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: VSpace.tight) {
                Text("More to Watch")
                    .font(.headline)
                    .modifier(CinemaCaption())
                    .padding(.horizontal, VSpace.unit)
                    .accessibilityAddTraits(.isHeader)
                ForEach(suggestions) { suggestion in
                    RelatedVideoButton(model: model, suggestion: suggestion, style: .rail, cinema: true) {
                        model.playSuggested(suggestion.entry)
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
    let style: RelatedVideosView.Style
    var cinema = false
    let select: () -> Void
    @State private var hovered = false

    private var subtitle: String? { cinema ? suggestion.entry.studio : suggestion.subtitle }

    var body: some View {
        Button(action: select) {
            Group {
                switch style {
                case .rail:
                    HStack(spacing: VSpace.control) {
                        poster.frame(width: cinema ? 68 : 104)
                        if cinema { caption.modifier(CinemaCaption()) }
                        else { caption }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                case .shelf:
                    VStack(alignment: .leading, spacing: VSpace.tight) {
                        poster
                        caption
                    }.frame(width: 168, alignment: .leading)
                }
            }
            .padding(cinema ? VSpace.unit : 0)
            .background(.white.opacity(cinema && hovered ? 0.14 : 0), in: RoundedRectangle(cornerRadius: VSpace.tight))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            EntryReaction(model: model, entry: suggestion.entry, reaction: .favorite, inMenu: true)
        }
        .onHover { if cinema { hovered = $0 } }
        .help("Play \(suggestion.entry.title)")
        .accessibilityLabel(Text("Play \(suggestion.entry.title)"))
        .accessibilityValue(Text(subtitle ?? ""))
    }

    private var poster: some View {
        Poster(model: model, entry: suggestion.entry)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: VSpace.unit) {
            Text(suggestion.entry.title)
                .font(.body.weight(.semibold)).lineLimit(2)
                .multilineTextAlignment(.leading)
            if let subtitle {
                Text(subtitle)
                    .font(.caption.weight(cinema ? .medium : .regular))
                    .foregroundStyle(cinema ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
    }
}
