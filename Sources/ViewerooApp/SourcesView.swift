import SwiftUI
import ViewerooCore

struct SourcesView: View {
    var model: LibraryModel
    @State private var removal: CatalogSource?
    @State private var affected = 0
    var body: some View {
        let matches = model.visibleSources
        VStack(alignment: .leading, spacing: VSpace.section) {
            CollectionHeading(title: "Source Folders", count: matches.count == 1 ? "1 folder" : "\(matches.count) folders",
                              filters: model.filterBinding) {
                if !model.sources.isEmpty || model.narrowed {
                    IconActionButton(.add, "Add Folder…") { model.pickSource() }
                }
            }.padding([.top, .horizontal], VSpace.section)

            if matches.isEmpty && model.narrowed {
                ContentUnavailableView("No matching folders", systemImage: "magnifyingglass",
                                       description: Text("Try a different search or clear a filter."))
            } else if matches.isEmpty {
                ContentUnavailableView {
                    Label("No source folders", systemImage: "folder")
                } description: {
                    Text("Add a folder to begin scanning this library.")
                } actions: {
                    Button("Add Folder…") { model.pickSource() }.buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { source in
                            HStack(spacing: VSpace.control) {
                                Image(systemName: source.online ? "folder" : "externaldrive.badge.xmark").font(.title2)
                                VStack(alignment: .leading, spacing: VSpace.unit) {
                                    Text(source.url.lastPathComponent).font(.headline)
                                    Text(source.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Spacer()
                                if !source.online { Text("Offline").foregroundStyle(.secondary) }
                                IconActionButton(.remove, "Remove Source Folder…", targetLabel: "Remove Source Folder “\(source.path)”") {
                                    do { affected = try model.catalog?.sourceRemovalCount(source.id) ?? 0; removal = source }
                                    catch { model.message = error.localizedDescription }
                                }.disabled(model.scanBusy)
                            }.padding(.vertical, VSpace.tight)
                            Divider()
                        }
                    }
                    .padding(.horizontal, VSpace.section)
                    .background(BrowseScrollAnchor(position: model.visit.scroll))
                }
            }
            Spacer(minLength: 0)
        }
        .confirmationDialog("Remove source folder?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
                            titleVisibility: .visible, presenting: removal) { source in
            Button("Keep Library Entries") { model.change("Source folder removed") { try $0.removeSource(source.id, removeOrphans: false) } }
            if affected > 0 {
                Button("Remove \(affected) Entries", role: .destructive) { model.change("Source folder removed") { try $0.removeSource(source.id, removeOrphans: true) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("\(affected) videos would lose their last source in this library. You can keep their history and playlists. Original files stay on disk.") }
    }
}
