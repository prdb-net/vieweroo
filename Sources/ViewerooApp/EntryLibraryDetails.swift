import AppKit
import SwiftUI
import ViewerooCore

struct EntryLibraryDetails: View {
    let model: LibraryModel
    let entry: CatalogEntry
    @State private var fileExpanded = true
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
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: VSpace.unit) {
                    Text(entry.title).font(.title2.bold()).textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                    let studio = model.studioDirectory.studio(for: entry)
                    HStack {
                        Button(studio.name) {
                            model.browse(.studio(studio.name, siteID: studio.siteID), from: .studio(studio.name, siteID: studio.siteID))
                        }
                        .buttonStyle(.link)
                        if let quality = entry.videoInfo?.quality { Text(quality).foregroundStyle(.secondary) }
                        if let duration = entry.duration { Text(clockLabel(duration)).foregroundStyle(.secondary) }
                    }.font(.callout)
                    if let account = studio.creator { CreatorProfileView(account: account) }
                }
                Spacer()
                Button("Close Details", systemImage: "xmark.circle.fill", action: model.goBack)
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Close details (Esc)")
            }
            .padding(VSpace.group)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: VSpace.group) {
                    HStack(spacing: VSpace.tight) {
                        EntryReactions(model: model, entry: entry)
                        PlaylistMenu(model: model, entryID: entry.id)
                            .labelStyle(.iconOnly).help("Add to Playlist")
                        Spacer()
                        Menu {
                            Button(entry.resume > 0 ? "Resume" : "Play") { model.play(entry) }
                            if entry.resume > 0 {
                                Button("Play from Beginning") { model.play(entry, at: 0) }
                            }
                            Menu("Play on Display") { DisplayChoices { model.playOnDisplay(entry, screen: $0) } }
                        } label: { Label("Playback options", systemImage: "play.rectangle") }
                        .labelStyle(.iconOnly).help("Playback options").disabled(!LibraryModel.cinemaPlayable(entry))
                    }
                    if !LibraryModel.cinemaPlayable(entry) {
                        Label(entry.availability == .offline ? "Reconnect the source drive to play this video." :
                              entry.availability == .missing ? "This file is missing from its source folder." :
                              entry.playbackFailure ?? "Playback unavailable", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                    }
                    if let description = entry.localDescription {
                        Text(description).textSelection(.enabled)
                    }
                    EntryPerformers(model: model, entry: entry)
                    Divider()
                    EntryTagEditor(model: model, entry: entry)
                    Divider()
                    EntryHistory(model: model, entry: entry)
                    Divider()
                    DisclosureGroup("File", isExpanded: $fileExpanded) { fileSection }
                    Divider()
                    DisclosureGroup("PRDB Match and Studio") {
                        VStack(alignment: .leading, spacing: VSpace.group) {
                            matchSection
                            studioSection
                        }.padding(.vertical, VSpace.tight)
                    }
                    if entry.availability != .available {
                        Button("Remove Library Entry…", systemImage: "trash", role: .destructive) { deleting = true }
                            .labelStyle(.iconOnly).help("Remove Library Entry…")
                    }
                }
                .padding(VSpace.group)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .disabled(savingName)
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
            if !editingName {
                HStack {
                    Text(entry.filename).font(.headline).textSelection(.enabled).help(entry.path)
                    Spacer()
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
            }
            Text(entry.url.deletingLastPathComponent().path(percentEncoded: false))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled).help(entry.path)
            HStack(spacing: VSpace.tight) {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                }
                .labelStyle(.iconOnly).help("Show in Finder")
                .disabled(entry.availability != .available)
                Button("Video Encoding", systemImage: "info.circle") { showEncoding.toggle() }
                    .labelStyle(.iconOnly).help("Video Encoding")
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
                Button(entry.match == nil ? "Find Match…" : "Correct Match…", systemImage: "magnifyingglass") {
                    matchError = nil
                    matching = true
                }
                .labelStyle(.iconOnly).help(entry.match == nil ? "Find Match…" : "Correct Match…")
                if entry.match != nil {
                    Button("Remove Match", systemImage: "minus.circle") {
                        matchError = nil
                        model.change("Title match removed", onFailure: { matchError = $0 }) {
                            try $0.confirmMatch(entryID: entry.id, title: nil)
                        }
                    }
                    .labelStyle(.iconOnly)
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
                Text(entry.hasCandidates ? "Suggested titles available" : "No title linked")
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
