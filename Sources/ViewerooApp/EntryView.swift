import SwiftUI
import ViewerooCore

struct EntryView: View {
    @Bindable var model: LibraryModel
    let entry: CatalogEntry
    @State private var tags = ""
    @State private var studio = ""
    @State private var stats: PlaybackStats?
    @State private var matching = false
    @State private var deleting = false
    private var available: Bool { entry.availability == .available }

    var body: some View {
        GeometryReader { layout in
            let sideBySide = layout.size.width >= 760 && model.hasAlternatives(to: entry)
            ScrollView {
                HStack(alignment: .top, spacing: VSpace.section) {
                    VStack(alignment: .leading, spacing: VSpace.section) {
                        overview
                        performers
                        if !sideBySide {
                            RelatedVideosView(model: model, current: entry, style: .shelf, onSelect: model.playSuggested)
                        }
                        historySection
                        Divider()
                        DisclosureGroup("Library Details", isExpanded: $model.detailsExpanded) {
                            libraryDetails.padding(.top, VSpace.control)
                        }
                        if !available {
                            Button("Remove Library Entry…", role: .destructive) { deleting = true }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if sideBySide {
                        RelatedVideosView(model: model, current: entry, onSelect: model.playSuggested)
                            .frame(width: min(304, layout.size.width * 0.31), alignment: .leading)
                    }
                }
                .padding(VSpace.section)
                .frame(maxWidth: sideBySide ? 1320 : 780, alignment: .leading)
                .frame(maxWidth: .infinity)
                .background(BrowseScrollAnchor(position: model.visit.scroll))
            }
        }
        .onAppear { tags = entry.tags.joined(separator: ", "); studio = entry.manualStudio ?? "" }
        .task(id: entry.watchTime) { stats = try? model.catalog?.playbackStats(entryID: entry.id) }
        .sheet(isPresented: $matching) { MatchView(model: model, entry: entry) }
        .alert("Remove this entry?", isPresented: $deleting) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Entry", role: .destructive) {
                model.change("Entry removed") { try $0.deleteEntry(entry.id) }
            }
        } message: { Text("Its ratings, history, and playlist memberships will be deleted from this library.") }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: VSpace.group) {
            playPoster
            if !available || entry.playbackFailure != nil {
                Label(entry.availability == .offline ? "Reconnect the source drive to play this video." :
                        entry.availability == .missing ? "This file is missing from its source folder." :
                        entry.playbackFailure ?? "", systemImage: "exclamationmark.triangle")
            }
            organizationActions
        }
    }

    private var playPoster: some View {
        ZStack(alignment: .bottomLeading) {
            Poster(model: model, entry: entry)
                .contentShape(Rectangle())
                .onTapGesture { if available { model.play(entry) } }
            VStack(alignment: .leading, spacing: VSpace.control) {
                VStack(alignment: .leading, spacing: VSpace.unit) {
                    Text(entry.title)
                        .font(.title.bold()).textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                    Text(entry.studio ?? "Unknown Studio").font(.headline)
                }
                if available { playbackActions }
            }
            .foregroundStyle(.white)
            .padding(VSpace.group)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 2 * VSpace.page)
                    LinearGradient(colors: [.black.opacity(0.62), .black.opacity(0.86)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .padding(.top, -2 * VSpace.page)
                .allowsHitTesting(false)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: VSpace.tight, style: .continuous))
    }

    private var playbackActions: some View {
        let resume = entry.resume > 0
        let action = resume ? "Resume at \(durationLabel(entry.resume))" : "Play"
        return HStack(spacing: VSpace.tight) {
            Button { model.play(entry) } label: {
                Label(action, systemImage: "play.fill")
                    .font(.headline).monospacedDigit()
                    .padding(.horizontal, VSpace.group)
                    .frame(height: VSpace.page)
                    .foregroundStyle(.black).background(.white, in: Capsule())
            }
            .accessibilityLabel(resume ? "Resume \(entry.title) at \(durationLabel(entry.resume))" : "Play \(entry.title)")
            if resume {
                Button { model.play(entry, at: 0) } label: {
                    Label("Play from Beginning", systemImage: "backward.end.fill")
                        .labelStyle(.iconOnly)
                        .frame(width: VSpace.page, height: VSpace.page)
                        .background(.white.opacity(0.2), in: Circle())
                }
                .help("Play from Beginning")
            }
        }
        .buttonStyle(.plain)
    }

    private var organizationActions: some View {
        HStack(spacing: VSpace.tight) {
            ReactionButton(reaction: .favorite, isSelected: entry.favorite) {
                model.change(entry.favorite ? "Removed from Favorites" : "Added to Favorites",
                             kind: entry.favorite ? .success : .favorite) {
                    try $0.setFavorite(entryID: entry.id, value: !entry.favorite)
                }
            }
            rating(1, reaction: .like)
            rating(-1, reaction: .dislike)
            PlaylistMenu(model: model, entryID: entry.id)
        }
    }

    @ViewBuilder private var performers: some View {
        if let people = entry.match?.performers, !people.isEmpty {
            VStack(alignment: .leading, spacing: VSpace.control) {
                Text("Performers").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: VSpace.group) {
                        ForEach(people) { person in
                            Button {
                                model.browse(.performer(person), from: .performer(person.id))
                            } label: {
                                VStack {
                                    AsyncImage(url: model.artworkURL(person.portraitURL)) { phase in
                                        if let image = phase.image { image.resizable().scaledToFill() }
                                        else { Image(systemName: "person.fill").font(.title).foregroundStyle(.tertiary) }
                                    }.frame(width: 60, height: 60).background(.quaternary).clipShape(Circle())
                                    .overlay {
                                        if model.visit.selectedTile == .performer(person.id) {
                                            Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                                        }
                                    }
                                    Text(person.name).lineLimit(2).frame(width: 92)
                                }
                            }.buttonStyle(.plain)
                            .accessibilityAddTraits(model.visit.selectedTile == .performer(person.id) ? .isSelected : [])
                        }
                    }
                    .background(BrowseScrollAnchor(position: model.visit.castScroll))
                }
            }
        }
    }

    private var libraryDetails: some View {
        Grid(alignment: .leading, horizontalSpacing: VSpace.control, verticalSpacing: VSpace.control) {
            GridRow {
                Text("File").font(.headline)
                Text(entry.filename).foregroundStyle(.secondary).textSelection(.enabled).gridCellColumns(2)
            }
            GridRow {
                Text("Tags").font(.headline)
                TextField("Tags separated by commas", text: $tags).onSubmit { saveTags() }
                Button("Save Tags", action: saveTags)
            }
            GridRow {
                Text("Studio").font(.headline)
                TextField(entry.studio ?? "Studio name", text: $studio)
                Button("Set Studio") { model.change("Studio updated") { try $0.setManualStudio(entryID: entry.id, name: studio) } }
                    .disabled(studio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if entry.manualStudio != nil {
                GridRow { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Button("Use Automatic Studio") {
                        let saved = model.change("Using automatic studio") {
                            try $0.setManualStudio(entryID: entry.id, name: nil)
                        }
                        if saved { studio = "" }
                    }
                }
            }
            GridRow {
                Text("PRDB title").font(.headline)
                Text(entry.match?.title ?? (entry.candidates.isEmpty ? "Unmatched" : "\(entry.candidates.count) suggested")).foregroundStyle(.secondary)
                Button(entry.match == nil ? "Find Match…" : "Correct Match…") { matching = true }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: VSpace.tight) {
            Text("Viewing History").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            Text(entry.viewingSummary).foregroundStyle(.secondary)
            if let segments = stats?.segments.prefix(5), !segments.isEmpty {
                VStack(alignment: .leading) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, item in
                        Button {
                            model.play(entry, at: item.start)
                        } label: {
                            Label("\(durationLabel(item.start)) – \(durationLabel(item.end))  ·  \(item.passes)×", systemImage: "play.circle")
                        }.disabled(!available)
                    }
                }
            }
        }
    }

    private func saveTags() {
        model.change("Tags saved") { try $0.setTags(entryID: entry.id, tags: tags.components(separatedBy: ",")) }
    }
    private func rating(_ value: Int, reaction: VideoReaction) -> some View {
        ReactionButton(reaction: reaction, isSelected: entry.rating == value) {
            let updated = entry.rating == value ? 0 : value
            return model.change(updated == 0 ? "Rating cleared" : updated == 1 ? "Marked as liked" : "Marked as disliked") {
                try $0.setRating(entryID: entry.id, value: updated)
            }
        }
    }
}

extension CatalogEntry {
    var viewingSummary: String {
        let time = Duration.seconds(watchTime.rounded(.down)).formatted(.units(
            width: .narrow, maximumUnitCount: 2
        ))
        return "\(playCount) \(playCount == 1 ? "play" : "plays") · \(time) watched"
    }
}

private func durationLabel(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "—" }
    let total = Int(seconds)
    return "\(total / 60):" + String(format: "%02d", total % 60)
}

private struct MatchView: View {
    @Environment(\.dismiss) var dismiss
    var model: LibraryModel
    var entry: CatalogEntry
    @State private var term = ""
    @State private var results: [PRDBTitle] = []
    @State private var busy = false
    @State private var notice: String?
    @State private var work: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: VSpace.group) {
            Text("Match a PRDB Title").font(.title2.bold())
            Text(entry.filename).font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Search titles", text: $term).onSubmit { search() }
                Button("Search") { search() }.disabled(busy || term.isEmpty)
            }
            if let notice { Text(notice).foregroundStyle(.secondary) }
            List(results) { title in
                HStack {
                    VStack(alignment: .leading) {
                        Text(title.title)
                        if let studio = title.studio?.name { Text(studio).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Use Title") {
                        request { key in
                            let full = try await model.client.title(id: title.id, key: key)
                            try Task.checkCancellation()
                            guard model.phase == .ready, model.detailID == entry.id else { return }
                            let saved = model.change("Title match saved", onFailure: { notice = $0 }) {
                                try $0.confirmMatch(entryID: entry.id, title: full)
                            }
                            if saved { dismiss() }
                        }
                    }.disabled(busy)
                }
            }
            HStack { if busy { ProgressView().controlSize(.small) }; Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(VSpace.section).frame(width: 500, height: 395)
        .onAppear { term = entry.url.deletingPathExtension().lastPathComponent; results = entry.candidates }
        .onDisappear { work?.cancel() }
    }
    private func search() {
        request { key in
            let titles = try await model.client.search(term, key: key)
            try Task.checkCancellation()
            results = titles
            if titles.isEmpty { notice = "No matching titles. Try another search." }
        }
    }
    private func request(_ operation: @escaping (String) async throws -> Void) {
        guard !busy, model.phase == .ready else { return }
        busy = true; notice = nil
        work = Task { @MainActor in
            defer { busy = false }
            do {
                guard let key = try model.access.apiKey() else { return }
                do { try await operation(key) }
                catch {
                    if !Task.isCancelled { model.handleNetwork(error, key: key); notice = error.localizedDescription }
                }
            } catch { notice = error.localizedDescription }
        }
    }
}
