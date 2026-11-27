import SwiftUI
import ViewerooCore

struct EntryPRDBMetadata: View {
    let title: PRDBTitle
    let tagNames: [String: String]

    @ViewBuilder var body: some View {
        let keys = title.tagKeys ?? []
        if title.alternativeTitle != nil || title.durationSeconds != nil || !keys.isEmpty {
            VStack(alignment: .leading, spacing: VSpace.tight) {
                Text("PRDB Metadata").font(.headline).accessibilityAddTraits(.isHeader)
                if let alternative = title.alternativeTitle {
                    Text("Also known as \(alternative)").textSelection(.enabled)
                }
                if let seconds = title.durationSeconds {
                    Text("Catalog duration \(clockLabel(Double(seconds)))")
                }
                if !keys.isEmpty {
                    ChipRows {
                        ForEach(keys, id: \.self) { key in MetadataChip(name: tagNames[key] ?? key) }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("PRDB tags")
                }
            }
            .font(.callout)
        }
    }
}

struct EntryPerformers: View {
    let model: LibraryModel
    let entry: CatalogEntry

    @ViewBuilder var body: some View {
        if let people = entry.match?.performers, !people.isEmpty {
            VStack(alignment: .leading, spacing: VSpace.control) {
                Text("Performers").font(.headline).accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: VSpace.group) {
                        ForEach(people) { person in
                            Button {
                                model.browse(.performer(person), from: .performer(person.id))
                            } label: {
                                VStack {
                                    AsyncImage(url: model.artworkURL(person.portraitURL)) { phase in
                                        if let image = phase.image { image.resizable().scaledToFill() }
                                        else { Image(systemName: "person.fill").font(.title).foregroundStyle(.tertiary) }
                                    }.frame(width: 40, height: 40).background(.quaternary).clipShape(Circle())
                                    .overlay {
                                        if model.visit.selectedTile == .performer(person.id) {
                                            Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                                        }
                                    }
                                    Text(person.name).lineLimit(2).frame(width: 74)
                                }
                            }.buttonStyle(.plain)
                            .accessibilityAddTraits(model.visit.selectedTile == .performer(person.id) ? .isSelected : [])
                        }
                    }
                    .background(BrowseScrollAnchor(position: model.visit.castScroll))
                }
            }
        }
    }
}

struct EntryHistory: View {
    let model: LibraryModel
    let entry: CatalogEntry
    @State private var stats: PlaybackStats?
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Viewing History", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: VSpace.tight) {
                Text(entry.viewingSummary).foregroundStyle(.secondary)
                if let stats {
                    ForEach(Array(stats.segments.prefix(5)), id: \.start) { segment in
                        Button {
                            model.play(entry, at: segment.start)
                        } label: {
                            HStack {
                                Label("\(clockLabel(segment.start)) – \(clockLabel(segment.end))", systemImage: "play.circle")
                                Spacer()
                                Text("\(segment.passes)×")
                            }
                            .monospacedDigit().contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!LibraryModel.cinemaPlayable(entry))
                    }
                }
            }
            .padding(.top, VSpace.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: expanded) {
            if expanded { stats = try? model.catalog?.playbackStats(entryID: entry.id) }
        }
        .onChange(of: entry.watchTime) {
            if expanded { stats = try? model.catalog?.playbackStats(entryID: entry.id) }
        }
    }
}

private func watchTimeLabel(_ seconds: Double) -> String {
    Duration.seconds(seconds.rounded(.down)).formatted(.units(width: .narrow, maximumUnitCount: 2))
}

private func historySummary(plays: Int, seconds: Double) -> String {
    "\(plays) \(plays == 1 ? "play" : "plays") · \(watchTimeLabel(seconds)) watched"
}

extension CatalogEntry {
    var viewingSummary: String { historySummary(plays: playCount, seconds: watchTime) }
}
