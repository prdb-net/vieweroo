import SwiftUI
import ViewerooCore

struct BulkEditBar: View {
    let model: LibraryModel
    @Binding var selection: Set<Int64>?
    let visibleIDs: [Int64]
    let shortcutsEnabled: Bool
    @State private var editingTags = false
    @State private var choosingStudio = false
    @State private var historyRemoval: [Int64] = []
    @State private var saving = false

    // Preserve collection order and exclude anything hidden by a filter or a catalog refresh.
    private var targets: [Int64] { visibleIDs.filter { selection?.contains($0) == true } }

    var body: some View {
        let ids = targets
        SelectionActionBar(title: model.collectionTitle, selection: $selection, visibleIDs: visibleIDs, count: ids.count,
                           shortcutsEnabled: shortcutsEnabled && !editingTags && !choosingStudio && historyRemoval.isEmpty) {
            editActions(ids)
        }
        .alert("Remove from Watch History?", isPresented: Binding(
            get: { !historyRemoval.isEmpty }, set: { if !$0 { historyRemoval = [] } }
        ), presenting: historyRemoval) { pending in
            Button("Cancel", role: .cancel) {}
            Button("Remove History", role: .destructive) { run(.removeHistory, on: pending, clearing: true) }
        } message: { pending in
            let scope = pending.count == 1 ? "this video" : "these \(pending.count) videos"
            Text("Clear play counts, watch time and watched segments for \(scope)? Saved playback positions are kept.")
        }
        .sheet(isPresented: $editingTags) {
            BulkTagSheet(videoCount: ids.count, libraryTags: model.tags.map(\.name)) { tags in
                await apply(.addTags(tags), to: ids)
            }
        }
        .sheet(isPresented: $choosingStudio) {
            if let library = model.libraryID {
                StudioDirectoryView(model: model, libraryID: library, videoCount: ids.count) { name, siteID in
                    await apply(.studio(name: name, siteID: siteID), to: ids)
                }
            }
        }
    }

    @ViewBuilder
    private func editActions(_ ids: [Int64]) -> some View {
        Group {
            if model.shelf.offersAllBulkActions {
                additionalActions(ids)
            } else {
                switch model.shelf {
                case .favorites:
                    Button("Remove from Favorites") { run(.favorite(false), on: ids, clearing: true) }
                case .liked:
                    Button("Clear Like") { run(.rating(0), on: ids, clearing: true) }
                case let .playlist(id):
                    Button("Remove from Playlist") { run(.removeFromPlaylist(id), on: ids, clearing: true) }
                case let .tag(id):
                    Button("Remove Tag from Selected Videos") { run(.removeTag(id), on: ids, clearing: true) }
                case .frequent:
                    Button("Remove from Watch History…") { historyRemoval = ids }
                default:
                    EmptyView()
                }
                Menu("More") { additionalActions(ids) }
                    .fixedSize()
            }
        }
        .disabled(ids.isEmpty || saving)
    }

    @ViewBuilder
    private func additionalActions(_ ids: [Int64]) -> some View {
        if model.shelf != .favorites {
            Button("Add to Favorites") { run(.favorite(true), on: ids) }
        }
        if model.shelf != .liked {
            Button("Like Videos") { run(.rating(1), on: ids) }
        }
        if model.shelf.offersAllBulkActions {
            Button("Dislike Videos") { run(.rating(-1), on: ids) }
        }
        Menu("Add to Playlist") {
            ForEach(model.playlists) { playlist in
                Button(playlist.name) { run(.addToPlaylist(playlist.id), on: ids) }
            }
        }
        .fixedSize()
        .disabled(model.playlists.isEmpty)
        Button("Add Tags…") { editingTags = true }
        Button("Set Studio…") { choosingStudio = true }
    }

    /// Returns nil when the edit was saved, otherwise the reason to show at the control.
    @discardableResult
    private func apply(_ edit: BulkVideoEdit, to ids: [Int64]) async -> String? {
        guard !ids.isEmpty, !saving else { return "" }
        saving = true
        defer { saving = false }
        let receipt: BulkEditReceipt
        switch await model.editVideos(ids, edit: edit) {
        case let .success(saved): receipt = saved
        case let .failure(failure): return failure.description
        }
        let count = receipt.changedCount
        let videos = count == 1 ? "1 video" : "\(count) videos"
        let text: String
        switch edit {
        case .favorite(true): text = count > 0 ? "Added \(videos) to Favorites" : "Already in Favorites"
        case .favorite(false): text = "Removed \(videos) from Favorites"
        case .rating(0): text = "Cleared like on \(videos)"
        case .rating(-1): text = count > 0 ? "Disliked \(videos)" : "Already disliked"
        case .rating: text = count > 0 ? "Liked \(videos)" : "Already liked"
        case .addToPlaylist: text = count > 0 ? "Added \(videos) to playlist" : "Already in playlist"
        case .removeFromPlaylist: text = "Removed \(videos) from playlist"
        case .removeHistory: text = "Removed \(videos) from Watch History"
        case .removeTag: text = "Removed tag from \(videos)"
        case .addTags: text = count > 0 ? "Tagged \(videos)" : "Tags already applied"
        case .studio(nil, nil): text = count > 0 ? "\(videos) use their automatic studio" : "Already using the automatic studio"
        case .studio: text = count > 0 ? "Studio set for \(videos)" : "Studio already set"
        }
        if case .studio = edit, count > 0 { model.recognizeStudios() }
        model.notice = ActionNotice(text: text, kind: .success, undo: count > 0 ? receipt : nil)
        return nil
    }

    /// Apply from a button. A failure appears as a notice, and `clearing` empties the selection
    /// after edits that take the videos out of the open collection.
    private func run(_ edit: BulkVideoEdit, on ids: [Int64], clearing: Bool = false) {
        Task {
            if let failure = await apply(edit, to: ids) {
                if !failure.isEmpty { model.notify(failure, kind: .error) }
            } else if clearing, selection != nil {
                // Done or a change of collection may have ended edit mode while the batch ran.
                selection = []
            }
        }
    }
}

extension Shelf {
    /// Collections without a membership action of their own show every batch action directly.
    var offersAllBulkActions: Bool {
        switch self {
        case .all, .studio, .performer: true
        default: false
        }
    }
}

private struct BulkTagSheet: View {
    let videoCount: Int
    let libraryTags: [String]
    /// Returns nil when the tags were saved, otherwise the reason.
    let apply: ([String]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var selected: [String] = []
    @State private var draft = ""
    @State private var error: String?

    private var pending: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var available: [String] {
        var seen = Set(selected.map { $0.lowercased() })
        return libraryTags.filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VSpace.group) {
            Text("Add Tags").font(.title2.bold())
            Text(videoCount == 1 ? "1 video selected" : "\(videoCount) videos selected").foregroundStyle(.secondary)
            HStack {
                TextField("New tag", text: $draft).onSubmit { stageDraft() }
                IconActionButton(.add, "Add Tag") { stageDraft() }.disabled(pending.isEmpty)
                Menu("Choose Tag") {
                    ForEach(available, id: \.self) { tag in Button(tag) { selected.append(tag) } }
                }
                .fixedSize().disabled(available.isEmpty)
            }
            if !selected.isEmpty {
                ScrollView {
                    ChipRows {
                        ForEach(selected, id: \.self) { tag in
                            MetadataChip(name: tag, removeLabel: "Remove tag \(tag)") { selected.removeAll { $0 == tag } }
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Tags") {
                    stageDraft()
                    saving = true
                    Task {
                        let failure = await apply(selected)
                        saving = false
                        if let failure { error = failure.isEmpty ? nil : failure } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || videoCount == 0 || (selected.isEmpty && pending.isEmpty))
            }
        }
        .frame(width: 380).padding(VSpace.section)
    }

    private func stageDraft() {
        guard !pending.isEmpty else { return }
        if !selected.contains(where: { $0.caseInsensitiveCompare(pending) == .orderedSame }) {
            selected.append(available.first { $0.caseInsensitiveCompare(pending) == .orderedSame } ?? pending)
        }
        draft = ""
    }
}


/// The header of edit mode. It replaces the collection heading, so the tiles keep their room.
struct SelectionActionBar<Actions: View>: View {
    let title: String
    @Binding var selection: Set<Int64>?
    let visibleIDs: [Int64]
    let count: Int
    let shortcutsEnabled: Bool
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: VSpace.tight) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: VSpace.tight) {
                    selectionControls
                    Spacer(minLength: VSpace.group)
                    HStack(spacing: VSpace.tight) { actions }.fixedSize()
                    done
                }
                VStack(alignment: .leading, spacing: VSpace.tight) {
                    HStack(spacing: VSpace.tight) {
                        selectionControls
                        Spacer(minLength: VSpace.group)
                        done
                    }
                    ChipRows { actions }
                }
            }
            .padding(.horizontal, VSpace.section)
            Divider()
        }
        .padding(.top, VSpace.control)
        .onChange(of: visibleIDs, initial: true) { selection?.formIntersection(visibleIDs) }
    }

    private var selectionControls: some View {
        let all = count == visibleIDs.count && count > 0
        return HStack(spacing: VSpace.tight) {
            Text(title).font(.headline).lineLimit(1).accessibilityAddTraits(.isHeader)
            Text("\(count) of \(visibleIDs.count) selected").monospacedDigit().foregroundStyle(.secondary).fixedSize()
            // Command–A selects everything. The button offers the opposite once that is the case.
            Button(all ? "Deselect All" : "Select All") { selection = all ? [] : Set(visibleIDs) }
                .disabled(visibleIDs.isEmpty)
                .fixedSize()
                .background {
                    Button("Select All") { selection = Set(visibleIDs) }
                        .keyboardShortcut(shortcutsEnabled ? KeyboardShortcut("a") : nil)
                        .disabled(visibleIDs.isEmpty)
                        .focusable(false).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
                }
        }
    }

    private var done: some View {
        Button("Done") { selection = nil }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(shortcutsEnabled ? .cancelAction : nil)
            .help("Finish editing (Esc)")
            .fixedSize()
    }
}
