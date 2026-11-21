import SwiftUI
import ViewerooCore

struct SourcesView: View {
    var model: LibraryModel
    @State private var removal: CatalogSource?
    @State private var affected = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Source Folders").font(.largeTitle.bold())
                Spacer()
                Button("Add Folder…") { model.pickSource() }
            }.padding([.top, .horizontal], 24)
            if model.sources.isEmpty {
                ContentUnavailableView("No source folders", systemImage: "folder", description: Text("Add a folder to begin scanning this library."))
            } else {
                List(model.sources) { source in
                    HStack(spacing: 12) {
                        Image(systemName: source.online ? "folder" : "externaldrive.badge.xmark").font(.title2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.url.lastPathComponent).font(.headline)
                            Text(source.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        if !source.online { Text("Offline").foregroundStyle(.secondary) }
                        Button("Remove…") {
                            do { affected = try model.catalog?.sourceRemovalCount(source.id) ?? 0; removal = source }
                            catch { model.message = error.localizedDescription }
                        }.disabled(model.scanBusy)
                    }.padding(.vertical, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .confirmationDialog("Remove source folder?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
                            titleVisibility: .visible, presenting: removal) { source in
            Button("Keep Library Entries") { model.change { try $0.removeSource(source.id, removeOrphans: false) } }
            if affected > 0 {
                Button("Remove \(affected) Entries", role: .destructive) { model.change { try $0.removeSource(source.id, removeOrphans: true) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("\(affected) videos would lose their last source in this library. You can keep their history and playlists. Original files stay on disk.") }
    }
}
