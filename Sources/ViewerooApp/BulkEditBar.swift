import SwiftUI
import ViewerooCore

struct BulkEditBar: View {
    let model: LibraryModel
    @Binding var selection: Set<Int64>?
    let visibleIDs: [Int64]
    let shortcutsEnabled: Bool
    @State private var editingTags = false
    @State private var historyRemoval: [Int64] = []

    // Preserve collection order and exclude anything hidden by a filter or a catalog refresh.
    private var targets: [Int64] { visibleIDs.filter { selection?.contains($0) == true } }

    var body: some View {
        let ids = targets
        VStack(spacing: VSpace.tight) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: VSpace.tight) {
                    selectionControls(count: ids.count)
                    Spacer()
                    HStack(spacing: VSpace.tight) { editActions(ids) }.fixedSize()
                }
                VStack(alignment: .leading, spacing: VSpace.tight) {
                    HStack { selectionControls(count: ids.count); Spacer() }
                    ChipRows { editActions(ids) }
                }
            }
            .padding(.horizontal, VSpace.section)
            Divider()
        }
        .padding(.top, VSpace.control)
        .onChange(of: visibleIDs, initial: true) { selection?.formIntersection(visibleIDs) }
        .alert("Remove from Watch History?", isPresented: Binding(
            get: { !historyRemoval.isEmpty }, set: { if !$0 { historyRemoval = [] } }
        ), presenting: historyRemoval) { pending in
            Button("Cancel", role: .cancel) {}
            Button("Remove History", role: .destructive) {
                if apply(.removeHistory, to: pending) { selection = [] }
            }
        } message: { pending in
            let scope = pending.count == 1 ? "this video" : "these \(pending.count) videos"
            Text("Clear play counts, watch time and watched segments for \(scope)? Saved playback positions are kept.")
        }
        .sheet(isPresented: $editingTags) {
            BulkTagSheet(videoCount: ids.count, libraryTags: model.tags.map(\.name)) { tags, onFailure in
                apply(.addTags(tags), to: ids, onFailure: onFailure)
            }
        }
    }

    private func selectionControls(count: Int) -> some View {
        HStack(spacing: VSpace.tight) {
            Text("\(count) selected").monospacedDigit()
            Button("Select All") { selection = Set(visibleIDs) }
                .keyboardShortcut(shortcutsEnabled && !editingTags ? KeyboardShortcut("a") : nil)
                .disabled(visibleIDs.isEmpty)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func editActions(_ ids: [Int64]) -> some View {
        Group {
            if model.shelf == .all {
                additionalActions(ids)
            } else {
                switch model.shelf {
                case .favorites:
                    Button("Remove from Favorites") {
                        if apply(.favorite(false), to: ids) { selection = [] }
                    }
                case .liked:
                    Button("Clear Like") {
                        if apply(.rating(0), to: ids) { selection = [] }
                    }
                case let .tag(id):
                    Button("Remove Tag from Selected Videos") {
                        if apply(.removeTag(id), to: ids) { selection = [] }
                    }
                case .frequent:
                    Button("Remove from Watch History…") { historyRemoval = ids }
                default:
                    EmptyView()
                }
                Menu("More") { additionalActions(ids) }
                    .fixedSize()
            }
        }
        .disabled(ids.isEmpty)
        Button("Done") { selection = nil }
    }

    @ViewBuilder
    private func additionalActions(_ ids: [Int64]) -> some View {
        if model.shelf != .favorites {
            Button("Add to Favorites") { apply(.favorite(true), to: ids) }
        }
        if model.shelf != .liked {
            Button("Like Videos") { apply(.rating(1), to: ids) }
        }
        if model.shelf == .all {
            Button("Dislike Videos") { apply(.rating(-1), to: ids) }
        }
        Menu("Add to Playlist") {
            ForEach(model.playlists) { playlist in
                Button(playlist.name) { apply(.addToPlaylist(playlist.id), to: ids) }
            }
        }
        .fixedSize()
        .disabled(model.playlists.isEmpty)
        Button("Add Tags…") { editingTags = true }
    }

    @discardableResult
    private func apply(_ edit: BulkVideoEdit, to ids: [Int64], onFailure: ((String) -> Void)? = nil) -> Bool {
        guard let library = model.libraryID, !ids.isEmpty else { return false }
        var receipt: BulkEditReceipt?
        guard model.change(onFailure: onFailure, { receipt = try $0.editVideos(in: library, entryIDs: ids, edit: edit) }),
              let receipt else { return false }
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
        case .removeHistory: text = "Removed \(videos) from Watch History"
        case .removeTag: text = "Removed tag from \(videos)"
        case .addTags: text = count > 0 ? "Tagged \(videos)" : "Tags already applied"
        }
        model.notice = ActionNotice(text: text, kind: .success, undo: count > 0 ? receipt : nil)
        return true
    }
}

extension LibraryModel {
    func undoBulkEdit(_ notice: ActionNotice) {
        guard self.notice?.id == notice.id, let receipt = notice.undo, libraryID == receipt.libraryID else { return }
        change("Edit undone") { try $0.undoVideoEdit(receipt) }
    }
}

private struct BulkTagSheet: View {
    let videoCount: Int
    let libraryTags: [String]
    let apply: ([String], @escaping (String) -> Void) -> Bool
    @Environment(\.dismiss) private var dismiss
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
                    if apply(selected, { error = $0 }) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(videoCount == 0 || (selected.isEmpty && pending.isEmpty))
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
