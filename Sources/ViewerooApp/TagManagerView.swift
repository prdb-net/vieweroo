import SwiftUI
import ViewerooCore

private extension CatalogTag {
    var videoCountLabel: String { memberIDs.count == 1 ? "1 video" : "\(memberIDs.count) videos" }
}

private enum TagEdit: Identifiable {
    case new, rename(CatalogTag), cover(CatalogTag)
    var id: String {
        switch self {
        case .new: "new"
        case let .rename(tag): "rename-\(tag.id)"
        case let .cover(tag): "cover-\(tag.id)"
        }
    }
}

struct TagManagerView: View {
    let model: LibraryModel
    let libraryID: Int64
    @Environment(\.dismiss) private var dismiss
    @State private var edit: TagEdit?
    @State private var query = ""
    @State private var filters = CollectionFilters()
    @State private var deletion: CatalogTag?
    @State private var error: String?

    var body: some View {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = model.tags.filter { filters.includes($0, term: term) }
        VStack(alignment: .leading, spacing: VSpace.control) {
            HStack {
                Text("Manage Tags").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                IconActionButton(.add, "New Tag…") { edit = .new }
            }
            HStack {
                CollectionSearchField(prompt: "Search tags", text: $query)
                CollectionFilterButton(shelf: .tags, filters: $filters)
            }
            if !filters.isEmpty { FilterChips(filters: $filters) }
            List(matches) { tag in
                HStack {
                    Text(tag.name).lineLimit(2).help(tag.name)
                    Spacer()
                    Text(tag.videoCountLabel).foregroundStyle(.secondary)
                    Button("Choose Cover…", systemImage: "photo") { edit = .cover(tag) }
                        .labelStyle(.iconOnly).help("Choose Cover…").accessibilityLabel("Choose cover for \(tag.name)")
                        .disabled(tag.memberIDs.isEmpty)
                    IconActionButton(.edit, "Rename Tag…", targetLabel: "Rename Tag “\(tag.name)”") { edit = .rename(tag) }
                    IconActionButton(.delete, "Delete Tag…", targetLabel: "Delete Tag “\(tag.name)”") { deletion = tag }
                }.buttonStyle(.bordered).padding(.vertical, VSpace.unit)
            }
            .listStyle(.inset)
            .overlay {
                if matches.isEmpty { Text(model.tags.isEmpty ? "No tags yet" : "No matching tags").foregroundStyle(.secondary) }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(VSpace.section)
        .frame(minWidth: 560, idealWidth: 700, minHeight: 400, idealHeight: 525)
        .sheet(item: $edit) { item in
            switch item {
            case .new:
                NameForm(title: "New Tag", name: term) { name, failure in
                    let saved = model.change("Tag created", onFailure: failure) { try $0.createTag(libraryID: libraryID, name: name) }
                    if saved { filters = CollectionFilters(); reveal(name) }
                    return saved
                }
            case let .rename(tag):
                NameForm(title: "Rename Tag", action: "Rename", name: tag.name) { name, failure in
                    let saved = model.renameTag(tag, to: name, onFailure: failure)
                    if saved { reveal(name) }
                    return saved
                }
            case let .cover(tag):
                CollectionCoverPicker(model: model, collection: CoverCollection(tag))
            }
        }
        .alert("Delete “\(deletion?.name ?? "")”?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }),
               presenting: deletion) { tag in
            Button("Cancel", role: .cancel) {}
            Button("Delete Tag", role: .destructive) { model.change("Tag deleted", onFailure: { error = $0 }) { try $0.deleteTag(tag.id) } }
        } message: { tag in Text("Remove this tag from \(tag.videoCountLabel) and delete its cover? All videos will remain in the library.") }
    }

    private func reveal(_ name: String) {
        error = nil
        if !name.localizedCaseInsensitiveContains(query) && !query.isEmpty { query = name }
    }
}
