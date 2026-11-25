import SwiftUI
import ViewerooCore

private struct MatchFilterOption: Identifiable, Equatable {
    let id: String
    let name: String
    var detail: String?
}

private struct TitleSearch: Equatable {
    var term = ""
    var studio: MatchFilterOption?
    var performer: MatchFilterOption?
    var isEmpty: Bool { term.isEmpty && studio == nil && performer == nil }
}

struct MatchView: View {
    @Environment(\.dismiss) private var dismiss
    let model: LibraryModel
    let entry: CatalogEntry
    @State private var draft = TitleSearch()
    @State private var directory: MatchDirectoryFilter.Kind?
    @State private var page = 1
    @State private var results: [PRDBTitle] = []
    @State private var total = 0
    @State private var selection: String?
    @State private var loaded: Request?
    @State private var retry = 0
    @State private var notice: String?
    @State private var saving: Task<Void, Never>?
    @State private var saveError: String?
    @State private var suggested: [PRDBTitle] = []

    private struct Request: Equatable {
        let search: TitleSearch
        let page: Int
        let retry: Int
    }

    private var request: Request {
        var search = draft
        search.term = search.term.trimmingCharacters(in: .whitespacesAndNewlines)
        return Request(search: search, page: page, retry: retry)
    }

    private var titles: [PRDBTitle] {
        if request.search.isEmpty { return suggested }
        return loaded == request ? results : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: VSpace.tight) {
                Text("Match a PRDB Title").font(.title2.bold())
                Label(entry.filename, systemImage: "doc").lineLimit(2).textSelection(.enabled)
                if let match = entry.match {
                    Text("Current match: \(match.title)").font(.callout).foregroundStyle(.secondary)
                        .lineLimit(2).help(match.title)
                }
            }
            .padding(.horizontal, VSpace.section).padding(.vertical, VSpace.group)
            Divider()
            VStack(alignment: .leading, spacing: VSpace.tight) {
                CollectionSearchField(prompt: "Search PRDB titles", text: $draft.term)
                HStack(spacing: VSpace.control) {
                    MatchDirectoryFilter(kind: .studio, model: model, active: $directory, selection: $draft.studio)
                    MatchDirectoryFilter(kind: .performer, model: model, active: $directory, selection: $draft.performer)
                    Spacer(minLength: 0)
                    if !request.search.isEmpty {
                        Button("Reset") { draft = TitleSearch() }
                    }
                }
            }
            .padding(.horizontal, VSpace.section).padding(.vertical, VSpace.group)
            Divider()
            HStack {
                Text(request.search.isEmpty ? "Suggested titles" : "Search results").font(.headline)
                Spacer()
                if request.search.isEmpty || (loaded == request && notice == nil) {
                    let count = request.search.isEmpty ? suggested.count : total
                    Text(count == 1 ? "1 title" : "\(count) titles").foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, VSpace.section).padding(.vertical, VSpace.tight)
            resultList
            Divider()
            HStack {
                if !request.search.isEmpty && (page > 1 || loaded == request && total > PRDBClient.titleSearchPageSize) {
                    Button("Previous") { page -= 1 }.disabled(page == 1)
                    Text("Page \(page)").monospacedDigit()
                    Button("Next") { page += 1 }.disabled(loaded != request || page * PRDBClient.titleSearchPageSize >= total)
                }
                Spacer()
                if saving != nil { ProgressView("Saving…").controlSize(.small) }
                Button("Cancel") {
                    if directory != nil { directory = nil } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Button("Use Title") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!titles.contains { $0.id == selection })
            }
            .padding(.horizontal, VSpace.section).padding(.vertical, VSpace.control)
        }
        .frame(width: 618, height: 420)
        .disabled(saving != nil)
        .interactiveDismissDisabled(saving != nil || directory != nil)
        .onChange(of: draft) { page = 1 }
        .task(id: request) { await load(request) }
        .task(id: entry.hasCandidates) {
            suggested = entry.hasCandidates ? (try? model.catalog?.candidates(entryID: entry.id)) ?? [] : []
        }
        .onDisappear { saving?.cancel() }
    }

    @ViewBuilder private var resultList: some View {
        if let saveError {
            Text(saveError).foregroundStyle(.red).padding(.horizontal, VSpace.section)
        }
        if !request.search.isEmpty && loaded != request {
            ProgressView("Searching PRDB…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let notice, !request.search.isEmpty {
            VStack(spacing: VSpace.tight) {
                Text(notice)
                Button("Try Again") { retry += 1 }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if titles.isEmpty {
            ContentUnavailableView {
                Label(request.search.isEmpty ? "Find a title" : "No matching titles", systemImage: "magnifyingglass")
            } description: {
                Text(request.search.isEmpty ? "Search by title, studio or performer." : "Try another title or clear a filter.")
            } actions: {
                if request.search.isEmpty {
                    Button("Search File Name") { draft.term = entry.url.deletingPathExtension().lastPathComponent }
                }
            }
        } else {
            List(titles, selection: $selection) { title in
                VStack(alignment: .leading, spacing: VSpace.unit) {
                    Text(title.title).fontWeight(.medium).lineLimit(2)
                    let cast = title.performers.map(\.name).joined(separator: ", ")
                    let details = [title.studio?.name, cast.isEmpty ? nil : cast].compactMap { $0 }.joined(separator: " · ")
                    if !details.isEmpty {
                        Text(details).font(.callout).foregroundStyle(.secondary).lineLimit(2).help(details)
                    }
                }.padding(.vertical, VSpace.unit).tag(title.id)
            }.listStyle(.inset)
        }
    }

    private func load(_ pending: Request) async {
        selection = nil
        loaded = nil
        saveError = nil
        notice = nil
        guard !pending.search.isEmpty else { return }
        do {
            try await Task.sleep(for: .milliseconds(250))
            let response = try await model.matchLookup { key in
                try await model.client.searchTitles(pending.search.term, studioID: pending.search.studio?.id,
                    performerID: pending.search.performer?.id, page: pending.page, key: key)
            }
            results = response.items
            total = response.total
            loaded = pending
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            total = 0
            notice = error.localizedDescription
            loaded = pending
        }
    }

    private func confirm() {
        guard saving == nil, let selection, titles.contains(where: { $0.id == selection }) else { return }
        saveError = nil
        saving = Task { @MainActor in
            defer { saving = nil }
            do {
                let title = try await model.matchLookup { key in
                    try await model.client.title(id: selection, key: key)
                }
                guard model.detailID == entry.id else { return }
                if model.change("Title match saved", onFailure: { saveError = $0 }, {
                    try $0.confirmMatch(entryID: entry.id, title: title)
                }) { dismiss() }
            } catch { saveError = error.localizedDescription }
        }
    }
}

private struct MatchDirectoryFilter: View {
    enum Kind: String {
        case studio = "Studio", performer = "Performer"
    }
    let kind: Kind
    let model: LibraryModel
    @Binding var active: Kind?
    @Binding var selection: MatchFilterOption?
    @State private var term = ""
    @State private var options: [MatchFilterOption] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        Button {
            term = ""
            active = kind
        } label: {
            HStack(spacing: VSpace.unit) {
                Text(selection?.name ?? kind.rawValue).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .accessibilityLabel(selection.map { "\(kind.rawValue): \($0.name)" } ?? kind.rawValue)
        .popover(isPresented: presented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: VSpace.tight) {
                CollectionSearchField(prompt: kind == .studio ? "Find a studio" : "Find a performer", text: $term)
                Button(kind == .studio ? "All studios" : "All performers") {
                    selection = nil
                    active = nil
                }
                Divider()
                if loading {
                    ProgressView().controlSize(.small)
                } else if let error {
                    Text(error).font(.callout)
                    Button("Try Again") { retry += 1 }
                } else if options.isEmpty {
                    Text(kind == .studio ? "No matching studios" : "No matching performers").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(options) { option in
                                Button {
                                    selection = option
                                    active = nil
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(option.name)
                                            if let detail = option.detail {
                                                Text(detail).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        if selection?.id == option.id { Image(systemName: "checkmark") }
                                    }.padding(.vertical, VSpace.unit).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                .accessibilityLabel("Filter by \(kind.rawValue.lowercased()) \(option.name)")
                                .accessibilityValue(option.detail ?? "")
                            }
                        }
                    }
                    if total > options.count {
                        Text("Showing \(options.count) of \(total). Refine your search.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(VSpace.control).frame(width: 290, height: 235)
            .task(id: Lookup(term: term, retry: retry)) { await fetchOptions() }
        }
    }

    private var presented: Binding<Bool> {
        Binding(get: { active == kind }, set: { open in
            if !open && active == kind { active = nil }
        })
    }

    private struct Lookup: Equatable {
        let term: String
        let retry: Int
    }

    private func fetchOptions() async {
        loading = true
        error = nil
        do {
            try await Task.sleep(for: .milliseconds(200))
            switch kind {
            case .studio:
                let response = try await model.matchLookup { try await model.client.searchStudios(term, key: $0) }
                options = response.items.map {
                    MatchFilterOption(id: $0.id, name: $0.name, detail: $0.creator?.platform)
                }
                total = response.total
            case .performer:
                let response = try await model.matchLookup { try await model.client.searchPerformers(term, key: $0) }
                options = response.items.map { MatchFilterOption(id: $0.id, name: $0.name) }
                total = response.total
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
}

private extension LibraryModel {
    func matchLookup<Result>(_ operation: @MainActor (String) async throws -> Result) async throws -> Result {
        guard phase == .ready else { throw CancellationError() }
        guard let key = try access.apiKey() else { throw AccessError.unavailable }
        let result: Result
        do {
            result = try await operation(key)
        } catch {
            try Task.checkCancellation()
            handleNetwork(error, key: key)
            throw error
        }
        try Task.checkCancellation()
        guard phase == .ready else { throw CancellationError() }
        return result
    }
}
