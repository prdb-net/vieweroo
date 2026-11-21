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

private struct RelatedVideoButton: View {
    let model: LibraryModel
    let suggestion: RelatedVideo
    let style: RelatedVideosView.Style
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Group {
                switch style {
                case .rail:
                    HStack(spacing: VSpace.control) {
                        poster.frame(width: 104)
                        caption
                    }.frame(maxWidth: .infinity, alignment: .leading)
                case .shelf:
                    VStack(alignment: .leading, spacing: VSpace.tight) {
                        poster
                        caption
                    }.frame(width: 168, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Play \(suggestion.entry.title)")
        .accessibilityLabel(Text("Play \(suggestion.entry.title)"))
        .accessibilityValue(Text(suggestion.subtitle ?? ""))
    }

    private var poster: some View {
        Poster(model: model, entry: suggestion.entry)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: VSpace.unit) {
            Text(suggestion.entry.title)
                .font(.body.weight(.semibold)).lineLimit(2)
                .multilineTextAlignment(.leading)
            if let subtitle = suggestion.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
