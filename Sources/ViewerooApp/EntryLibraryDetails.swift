import AppKit
import SwiftUI
import ViewerooCore

struct EntryLibraryDetails: View {
    @Environment(\.dismiss) private var dismiss
    let model: LibraryModel
    let entry: CatalogEntry
    @State private var showEncoding = false
    @State private var choosingStudio = false
    @State private var matching = false
    @State private var matchError: String?
    @State private var deleting = false
    @State private var editingName = false
    @State private var basename = ""
    @State private var renameError: String?
    @State private var savingName = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Library Details")
                .font(.title2.bold())
                .padding(.horizontal, VSpace.page)
                .padding(.vertical, VSpace.group)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: VSpace.section) {
                    fileSection
                    Divider()
                    matchSection
                    studioSection
                    EntryTagEditor(model: model, entry: entry)
                }
                .padding(.horizontal, VSpace.page)
                .padding(.vertical, VSpace.section)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if entry.availability != .available {
                    Button("Remove Library Entry…", role: .destructive) { deleting = true }
                }
                Spacer()
                Button("Done") {
                    if showEncoding { showEncoding = false } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, VSpace.page)
            .padding(.vertical, VSpace.control)
        }
        .disabled(savingName)
        .interactiveDismissDisabled(savingName || showEncoding)
        .sheet(isPresented: $choosingStudio) {
            StudioDirectoryView(model: model, libraryID: entry.libraryID, entry: entry)
        }
        .sheet(isPresented: $matching) { MatchView(model: model, entry: entry) }
        .alert("Remove this entry?", isPresented: $deleting) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Entry", role: .destructive) {
                model.change("Entry removed") { try $0.deleteEntry(entry.id) }
            }
        } message: { Text("Its ratings, history, and playlist memberships will be deleted from this library.") }
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: VSpace.tight) {
            HStack {
                Text("File").font(.headline)
                Spacer()
                if !editingName {
                    IconActionButton(.edit, "Rename File…", targetLabel: "Rename File “\(entry.filename)”") {
                        basename = entry.url.deletingPathExtension().lastPathComponent
                        editingName = true
                    }
                    .disabled(entry.availability != .available)
                }
            }
            if editingName {
                HStack {
                    TextField("File name", text: $basename)
                        .focused($nameFocused)
                        .onAppear { nameFocused = true }
                        .onSubmit(rename)
                    Text(".\(entry.url.pathExtension)").foregroundStyle(.secondary)
                }
                HStack {
                    Text(renameError ?? "Renames the file in its current folder.")
                        .font(.callout).foregroundStyle(renameError == nil ? Color.secondary : Color.red)
                    Spacer()
                    Button("Cancel") { editingName = false; renameError = nil }
                    Button("Rename", action: rename)
                        .disabled(basename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text(entry.filename)
                    .font(.system(.title3, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled).help(entry.path)
            }
            Text(entry.url.deletingLastPathComponent().path(percentEncoded: false))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled).help(entry.path)
            HStack(spacing: VSpace.tight) {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                }
                .disabled(entry.availability != .available)
                Button("Video Encoding", systemImage: "chevron.down") { showEncoding.toggle() }
                    .popover(isPresented: $showEncoding, arrowEdge: .bottom) {
                        encoding
                    }
                if entry.availability != .available {
                    Text(entry.availability == .offline ? "Source offline" : "File missing")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.top, VSpace.unit)
        }
    }

    private var encoding: some View {
        VStack(alignment: .leading, spacing: VSpace.control) {
            HStack {
                Text("Video Encoding").font(.headline)
                Spacer()
                Button("Close", systemImage: "xmark.circle.fill") { showEncoding = false }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction).help("Close")
            }
            Grid(alignment: .leading, horizontalSpacing: VSpace.section, verticalSpacing: VSpace.tight) {
                if let info = entry.videoInfo {
                    if let container = info.container { property("Container", container) }
                    else { property("File type", entry.url.pathExtension.uppercased()) }
                    property("Video codec", info.codec)
                    property("Encoded size", "\(info.width) × \(info.height) px")
                    if let fps = info.frameRate {
                        property("Frame rate", "\(fps.formatted(.number.precision(.fractionLength(0...3)))) fps")
                    }
                } else {
                    property("File type", entry.url.pathExtension.uppercased())
                    property("Video track", "No encoding information available")
                }
                property("File size", ByteCountFormatter.string(fromByteCount: entry.fileSize, countStyle: .file))
            }
        }
        .fixedSize()
        .padding(VSpace.group)
    }

    private func property(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private var studioSection: some View {
        VStack(alignment: .leading, spacing: VSpace.tight) {
            HStack {
                Text("Studio").font(.headline)
                Spacer()
                IconActionButton(.edit, "Choose Studio…") { choosingStudio = true }
            }
            if let creator = model.studioDirectory.studio(for: entry).creator { CreatorProfileView(account: creator) }
            if let manual = entry.manualStudio {
                MetadataChip(name: manual, removeLabel: "Use Automatic Studio") {
                    model.change("Using automatic studio") { try $0.setManualStudio(entryID: entry.id, name: nil) }
                }
            } else {
                HStack(spacing: VSpace.tight) {
                    MetadataChip(name: entry.studio ?? "Unknown Studio")
                    Text("Automatic").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var matchSection: some View {
        VStack(alignment: .leading, spacing: VSpace.tight) {
            HStack {
                Text("PRDB title").font(.headline)
                Spacer()
                Button(entry.match == nil ? "Find Match…" : "Correct Match…") {
                    matchError = nil
                    matching = true
                }
                if entry.match != nil {
                    Button("Remove Match") {
                        matchError = nil
                        model.change("Title match removed", onFailure: { matchError = $0 }) {
                            try $0.confirmMatch(entryID: entry.id, title: nil)
                        }
                    }
                    .help("Unlink the PRDB title and keep this video unmatched until you choose a title.")
                }
            }
            if let match = entry.match {
                Text(match.title).textSelection(.enabled)
                Text(entry.confirmed ? "Confirmed match" : "Matched by file hash")
                    .font(.callout).foregroundStyle(.secondary)
            } else if entry.confirmed {
                Text("No title linked").foregroundStyle(.secondary)
                Text("Automatic title matching is off for this video.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(entry.candidates.isEmpty ? "No title linked" :
                        entry.candidates.count == 1 ? "1 suggested title" : "\(entry.candidates.count) suggested titles")
                    .foregroundStyle(.secondary)
            }
            if let matchError { Text(matchError).font(.callout).foregroundStyle(.red) }
        }
    }

    private func rename() {
        guard !savingName else { return }
        savingName = true
        Task {
            do {
                try await model.renameFile(entry, basename: basename)
                editingName = false
                renameError = nil
            } catch { renameError = error.localizedDescription }
            savingName = false
        }
    }
}
