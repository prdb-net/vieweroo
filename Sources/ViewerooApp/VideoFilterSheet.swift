import SwiftUI
import ViewerooCore

struct VideoFilterOption: Identifiable {
    let id: String
    let name: String
    var count = 0
}

// Counts and choices describe the whole open collection. Checking a studio must
// leave other studios available for the same multiple selection.
struct VideoFilterChoices {
    static let qualities = ["8K", "4K", "1440p", "1080p", "720p", "SD", "Unknown"]
    var qualityCounts: [String: Int] = [:]
    let studios: [VideoFilterOption]
    let tags: [VideoFilterOption]

    init(entries: [CatalogEntry], directory: StudioDirectory, applied: CollectionFilters) {
        func selectedOptions(_ labels: [String: String]) -> [String: VideoFilterOption] {
            Dictionary(uniqueKeysWithValues: labels.map { ($0.key, VideoFilterOption(id: $0.key, name: $0.value)) })
        }
        var studioOptions = selectedOptions(applied.studios)
        var tagOptions = selectedOptions(applied.tags)
        for entry in entries {
            qualityCounts[entry.videoInfo?.quality ?? "Unknown", default: 0] += 1
            let studio = directory.studio(for: entry)
            let name = studio.creator.map { studio.name + " · " + $0.platform } ?? studio.name
            studioOptions[studio.id, default: VideoFilterOption(id: studio.id, name: name)].count += 1
            for tag in entry.tags {
                let key = tag.lowercased()
                tagOptions[key, default: VideoFilterOption(id: key, name: tag)].count += 1
            }
        }
        func alphabetical(_ options: [String: VideoFilterOption]) -> [VideoFilterOption] {
            options.values.sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
        }
        studios = alphabetical(studioOptions)
        tags = alphabetical(tagOptions)
    }
}

struct VideoFilterSheet: View {
    let model: LibraryModel

    var body: some View {
        let entries = model.videosInCollection
        VideoFilterForm(model: model, entries: entries,
                        choices: VideoFilterChoices(entries: entries, directory: model.studioDirectory, applied: model.visit.filters))
    }
}

private struct VideoFilterForm: View {
    let model: LibraryModel
    let entries: [CatalogEntry]
    let choices: VideoFilterChoices
    @State private var query: String
    @State private var draft: CollectionFilters
    @State private var studioSearch = ""
    @State private var tagSearch = ""
    @Environment(\.dismiss) private var dismiss

    init(model: LibraryModel, entries: [CatalogEntry], choices: VideoFilterChoices) {
        self.model = model
        self.entries = entries
        self.choices = choices
        _query = State(initialValue: model.query)
        _draft = State(initialValue: model.visit.filters)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VSpace.control) {
            HStack(alignment: .firstTextBaseline) {
                Text("Video Filters").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(model.collectionTitle).lineLimit(1).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: VSpace.group) {
                    VStack(alignment: .leading, spacing: VSpace.unit) {
                        Text("Search videos").font(.headline)
                        CollectionSearchField(prompt: "Title, filename, studio, performer or tag", text: $query)
                    }
                    HStack(alignment: .top, spacing: VSpace.section) {
                        qualitySection.frame(width: 170)
                        studioSection
                    }
                    tagSection
                    VStack(alignment: .leading, spacing: VSpace.tight) {
                        Text("Library filters").font(.headline)
                        ChipRows {
                            ForEach(model.shelf.filterOptions, id: \.self) { option in
                                Toggle(option.rawValue, isOn: membership(option, in: $draft.selected))
                                    .padding(.trailing, VSpace.tight)
                            }
                        }
                    }
                }
                .padding(VSpace.unit)
                .frame(maxWidth: .infinity, alignment: .leading)
            }.scrollBounceBehavior(.basedOnSize)
            Divider()
            HStack {
                Button("Reset filters") {
                    query = ""
                    draft = CollectionFilters()
                    studioSearch = ""
                    tagSearch = ""
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
                let filters = draft, directory = model.studioDirectory
                let matches = entries.lazy.filter { filters.includes($0, directory: directory, term: term) }.count
                Button(matches == 1 ? "Show 1 video" : "Show \(matches) videos") {
                    model.refine(query: term, filters: draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(VSpace.section)
        .frame(minWidth: 590, idealWidth: 700, maxWidth: 1000,
               minHeight: 390, idealHeight: 560, maxHeight: 900)
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: VSpace.tight) {
            Text("Video quality").font(.headline)
            GroupBox {
                VStack(spacing: VSpace.unit) {
                    ForEach(VideoFilterChoices.qualities, id: \.self) { quality in
                        let count = choices.qualityCounts[quality, default: 0]
                        optionRow(quality, count: count, selected: membership(quality, in: $draft.qualities))
                            .disabled(count == 0 && !draft.qualities.contains(quality))
                    }
                }
            }
        }
    }

    private var studioSection: some View {
        VStack(alignment: .leading, spacing: VSpace.tight) {
            HStack {
                Text("Studios").font(.headline)
                Spacer()
                if !draft.studios.isEmpty { Text("\(draft.studios.count) selected").foregroundStyle(.secondary) }
            }
            GroupBox {
                VStack(spacing: VSpace.unit) {
                    TextField("Find a studio", text: $studioSearch)
                    let options = matching(choices.studios, search: studioSearch)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: VSpace.unit) {
                            ForEach(options) { option in
                                optionRow(option.name, count: option.count, selected: selection(option, in: $draft.studios))
                            }
                            if options.isEmpty { Text("No matching studios").foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 122)
                }
            }
        }
    }

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: VSpace.tight) {
            HStack {
                Text("Tags").font(.headline)
                Spacer()
                TextField("Find a tag", text: $tagSearch).frame(width: 170)
            }
            GroupBox {
                let options = matching(choices.tags, search: tagSearch)
                if options.isEmpty {
                    Text(choices.tags.isEmpty ? "No tags in this collection" : "No matching tags")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading,
                                  spacing: VSpace.tight) {
                            ForEach(options) { option in
                                Toggle(option.name, isOn: selection(option, in: $draft.tags))
                                    .lineLimit(1).help(option.name)
                            }
                        }.padding(2)
                    }
                    .frame(maxHeight: 88)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func optionRow(_ name: String, count: Int, selected: Binding<Bool>) -> some View {
        HStack {
            Toggle(name, isOn: selected).lineLimit(1).help(name)
            Spacer()
            Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func matching(_ options: [VideoFilterOption], search: String) -> [VideoFilterOption] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? options : options.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    private func membership<T>(_ value: T, in values: Binding<Set<T>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(value) }, set: { enabled in
            if enabled { values.wrappedValue.insert(value) } else { values.wrappedValue.remove(value) }
        })
    }

    private func selection(_ option: VideoFilterOption, in values: Binding<[String: String]>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue[option.id] != nil }, set: { enabled in
            values.wrappedValue[option.id] = enabled ? option.name : nil
        })
    }
}
