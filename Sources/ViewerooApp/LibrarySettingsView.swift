import SwiftUI
import ViewerooCore

struct LibrarySettingsView: View {
    let model: LibraryModel
    let library: CatalogLibrary
    @State private var renaming = false
    @State private var deleting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VSpace.section) {
                Text("Library Settings").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                HStack(spacing: VSpace.group) {
                    VStack(alignment: .leading, spacing: VSpace.unit) {
                        Text("Library name").font(.headline)
                        Text(library.name).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // This page has room for words, and a pencil or a gear here would be the third
                    // settings symbol on the way to the folders.
                    Button("Rename…") { renaming = true }
                        .accessibilityLabel("Rename Library “\(library.name)”")
                }
                Divider()
                HStack(spacing: VSpace.group) {
                    VStack(alignment: .leading, spacing: VSpace.unit) {
                        Text("Source folders").font(.headline)
                        Text(model.sources.isEmpty ? "No folders added" : model.sources.count.formatted() + (model.sources.count == 1 ? " folder" : " folders"))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Manage Folders…") { model.browse(.sources) }
                }
                Divider()
                Button(role: .destructive) { deleting = true } label: {
                    // A bordered destructive button is not tinted on macOS.
                    Text("Delete Library…").foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(VSpace.section)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BrowseScrollAnchor(position: model.visit.scroll))
        }
        .sheet(isPresented: $renaming) {
            NameForm(title: "Rename Library", action: "Rename", name: library.name) { name, onFailure in
                model.change("Library renamed", onFailure: onFailure) { try $0.renameLibrary(library.id, to: name) }
            }
        }
        .alert("Delete “\(library.name)”?", isPresented: $deleting) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Library", role: .destructive) { model.deleteLibrary() }
        } message: {
            Text("This removes the library’s catalog, playlists, and viewing history. Your video files stay on disk.")
        }
    }
}
