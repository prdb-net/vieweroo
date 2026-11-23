import SwiftUI
import ViewerooCore

private enum StudioEdit: Identifiable, Hashable {
    case create, rename(String), cover(StudioOption)
    var id: Self { self }
}

struct StudioDirectoryView: View {
    let model: LibraryModel
    let libraryID: Int64
    var entry: CatalogEntry?
    @Environment(\.dismiss) private var dismiss
    @State private var editing: StudioEdit?
    @State private var filters = CollectionFilters()
    @State private var query = ""
    @State private var error: String?
    @State private var pendingDeletion: StudioOption?
    @State private var confirmingDeletion = false

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let platformNames = model.studioPlatforms
        let members = entry == nil ? Dictionary(grouping: model.entries) { model.studioDirectory.studio(for: $0).id } : [:]
        let counts = members.mapValues(\.count)
        let directoryIDs = Set(model.studioOptions.map(\.id))
        let localGroups = members.compactMap { key, videos -> StudioOption? in
            guard !directoryIDs.contains(key), let first = videos.first else { return nil }
            return model.studioDirectory.studio(for: first)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let matches = model.studioOptions.filter { filters.includes($0, favorites: model.favoriteStudioIDs, term: term) }
        let localMatches = localGroups.filter { filters.includes($0, favorites: model.favoriteStudioIDs, term: term) }
        let groups = Dictionary(grouping: matches, by: { $0.creator?.platform })
        let canCreate = !term.isEmpty && term.caseInsensitiveCompare("Unknown Studio") != .orderedSame &&
            !model.studioOptions.contains { $0.name.caseInsensitiveCompare(term) == .orderedSame }
        VStack(alignment: .leading, spacing: VSpace.control) {
            HStack {
                Text(entry == nil ? "Manage Studios" : "Choose Studio").font(.title2.bold())
                Spacer()
                if entry == nil {
                    IconActionButton(.add, "New Studio…") { editing = .create }
                }
            }
            HStack(spacing: VSpace.control) {
                CollectionSearchField(prompt: entry == nil ? "Search studios" : "Find or create a studio", text: $query)
                if let entry {
                    Button("Create and Select") { assign(term, to: entry) }.disabled(!canCreate)
                }
                CollectionFilterButton(shelf: .studios, platforms: platformNames, filters: $filters)
            }
            if !filters.isEmpty { FilterChips(filters: $filters) }
            List {
                section("In This Library", studios: localMatches, counts: counts)
                section("My Studios", studios: matches.filter(\.isCustom), counts: counts)
                section("PRDB Studios", studios: matches.filter { !$0.isCustom && $0.creator == nil }, counts: counts)
                ForEach(platformNames, id: \.self) { platform in
                    section(platform, studios: groups[platform] ?? [], counts: counts)
                }
            }
            .listStyle(.inset)
            .overlay {
                if matches.isEmpty && localMatches.isEmpty {
                    Text(term.isEmpty && filters.isEmpty ? "No studios yet" : "No matching studios").foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(entry == nil ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(VSpace.section)
        .frame(minWidth: entry == nil ? 600 : 470, idealWidth: entry == nil ? 700 : 470,
               maxWidth: entry == nil ? 1000 : 470, minHeight: entry == nil ? 420 : 365,
               idealHeight: entry == nil ? 525 : 365, maxHeight: entry == nil ? 900 : 365)
        .sheet(item: $editing) { edit in
            switch edit {
            case .create:
                NameForm(title: "New Studio", name: canCreate ? term : "") { name, onFailure in
                    let saved = model.change("Studio created", onFailure: onFailure) {
                        try $0.createStudio(libraryID: libraryID, name: name)
                    }
                    if saved { filters = CollectionFilters(group: .custom); reveal(name) }
                    return saved
                }
            case let .cover(studio):
                CollectionCoverPicker(model: model, collection: model.coverCollection(for: studio, in: libraryID))
            case let .rename(oldName):
                NameForm(title: "Rename Studio", action: "Rename", name: oldName) { name, onFailure in
                    let saved = model.renameStudio(oldName, to: name, in: libraryID, onFailure: onFailure)
                    if saved { reveal(name) }
                    return saved
                }
            }
        }
        .alert("Delete “\(pendingDeletion?.name ?? "")”?", isPresented: $confirmingDeletion, presenting: pendingDeletion) { studio in
            Button("Cancel", role: .cancel) {}
            Button("Delete Studio", role: .destructive) {
                model.deleteStudio(studio.name, in: libraryID) { error = $0 }
            }
        } message: { _ in Text("Videos assigned to this studio will use their automatic studio again.") }
        .onChange(of: query) { error = nil }
    }

    @ViewBuilder private func section(_ title: String, studios: [StudioOption], counts: [String: Int]) -> some View {
        if !studios.isEmpty {
            Section(title) {
                ForEach(studios) { studio in
                    if let entry {
                        HStack {
                            Button { assign(studio.name, siteID: studio.siteID, to: entry) } label: {
                                HStack {
                                    Text(studio.name)
                                    Spacer()
                                    if entry.manualStudio != nil && model.studioDirectory.studio(for: entry).id == studio.id {
                                        Image(systemName: "checkmark")
                                    }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if let account = studio.creator {
                                CreatorProfileView(account: account, showsPlatform: false)
                            }
                        }
                    } else {
                        HStack {
                            Text(studio.name)
                            if let account = studio.creator {
                                CreatorProfileView(account: account, showsPlatform: false)
                            }
                            Spacer()
                            let count = counts[studio.id, default: 0]
                            Text(count == 1 ? "1 video" : "\(count) videos")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            Button("Choose Cover…", systemImage: "photo") { editing = .cover(studio) }
                                .labelStyle(.iconOnly).buttonStyle(.bordered).help("Choose Cover…")
                                .accessibilityLabel("Choose cover for \(studio.name)")
                                .disabled(count == 0)
                            if studio.isCustom {
                                IconActionButton(.edit, "Rename Studio…", targetLabel: "Rename Studio “\(studio.name)”") {
                                    editing = .rename(studio.name)
                                }
                                .buttonStyle(.bordered)
                                IconActionButton(.delete, "Delete Studio…", targetLabel: "Delete Studio “\(studio.name)”") {
                                    pendingDeletion = studio
                                    confirmingDeletion = true
                                }
                                .buttonStyle(.bordered)
                            }
                        }.padding(.vertical, VSpace.unit)
                    }
                }
            }
        }
    }

    private func reveal(_ name: String) {
        error = nil
        if !term.isEmpty && !name.localizedCaseInsensitiveContains(term) { query = name }
    }

    private func assign(_ name: String, siteID: String? = nil, to entry: CatalogEntry) {
        if model.change("Studio updated", onFailure: { error = $0 }, {
            try $0.setManualStudio(entryID: entry.id, name: name, siteID: siteID)
        }) { dismiss() }
    }
}


struct CreatorProfileView: View {
    let account: CreatorAccount
    var showsPlatform = true

    var body: some View {
        let parts = [showsPlatform ? account.platform : nil, account.handle.map { "@" + $0 }]
        let label = parts.compactMap { $0 }.joined(separator: " · ")
        if let url = account.profileURL {
            Link(destination: url) {
                HStack(spacing: VSpace.unit) {
                    Text(label).lineLimit(1)
                    Image(systemName: "arrow.up.right").font(.caption)
                }
            }
            .buttonStyle(.link)
            .help("Open \(url.absoluteString)")
            .accessibilityLabel("Open @\(account.handle ?? "") on \(account.platform)")
        } else if !label.isEmpty {
            Text(label).lineLimit(1).foregroundStyle(.secondary)
        }
    }
}
