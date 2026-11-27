import AppKit
import AVFoundation
import Combine
import Foundation
import Observation
import ViewerooCore

enum CinemaRecommendationCount: Int, CaseIterable {
    case two = 2, four = 4, six = 6
}

enum Gate { case starting, setup, locked, ready, failed }

enum Shelf: Hashable {
    case studios, all, favorites, liked, tags, frequent, playlists, settings, sources
    case studio(String, siteID: String? = nil), performer(PRDBPerformer), playlist(Int64), tag(Int64)
}

@MainActor @Observable
final class LibraryModel {
    @ObservationIgnored let access: AccessController
    @ObservationIgnored let client: PRDBClient
    private(set) var mainPlayer = PlayerSession()
    private(set) var secondPlayer: PlayerSession?
    @ObservationIgnored let playerDisplay = DisplayPlayerWindow()
    var playback: PlayerController { mainPlayer.playback }
    @ObservationIgnored let artworkURL: (URL?) -> URL?
    @ObservationIgnored private let prepareCatalog: ((Catalog) throws -> Void)?
    @ObservationIgnored let cache: PreviewCache
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let directory: URL
    @ObservationIgnored var validated = false
    @ObservationIgnored private(set) var catalog: Catalog?
    // The state below is written by the model's own files only: this one,
    // LibraryScanning.swift and LibraryLookups.swift. Views read it.
    /// Every background task of the open library. Replaced when the library session ends.
    @ObservationIgnored var work = LibraryWork()
    @ObservationIgnored var scanQueue: [CatalogSource] = []
    @ObservationIgnored var scanningSourceID: Int64?
    @ObservationIgnored var refreshRequested = false
    @ObservationIgnored var scanToken = UUID()
    @ObservationIgnored var panel: NSOpenPanel?
    @ObservationIgnored var previewToken = UUID()
    var phase = Gate.starting
    @ObservationIgnored private var catalogServer: CatalogAPIServer?
    @ObservationIgnored private let catalogPort: UInt16
    private(set) var catalogAPIEnabled = false
    private(set) var catalogAPIURL: String?
    private(set) var catalogAPIError: String?
    var pinEnabled = false
    var libraries: [CatalogLibrary] = []
    var sources: [CatalogSource] = []
    var entries: [CatalogEntry] = [] { didSet { collectionRevision &+= 1 } }
    var studioCovers: [String: CatalogCover] = [:]
    var favoriteStudioIDs: Set<String> = []
    var studioDirectory = StudioDirectory() { didSet { collectionRevision &+= 1 } }
    var studioOptions: [StudioOption] { studioDirectory.options }
    var tags: [CatalogTag] = [] { didSet { collectionRevision &+= 1 } }
    var prdbTagDirectory: PRDBTagDirectory?
    var playlists: [CatalogPlaylist] = []
    var recentPlaylists: [CatalogPlaylist] {
        Array(playlists.filter { $0.lastOpenedOrder > 0 }.sorted { $0.lastOpenedOrder > $1.lastOpenedOrder }.prefix(5))
    }
    var orderedIDs: [Int64] = [] { didSet { collectionRevision &+= 1 } }
    private(set) var loadingLibrary = false
    var libraryID: Int64?
    private var history = BrowseHistory()
    private(set) var visit: BrowseVisit {
        get { history.visit }
        set { history.visit = newValue }
    }
    var shelf: Shelf { visit.shelf }
    var query: String { visit.query }
    var detailID: Int64? { visit.detailID }
    var canGoBack: Bool { history.canGoBack }
    var cinemaQueue: [CatalogEntry] { mainPlayer.cinemaQueue }
    var cinemaMode: Bool { !cinemaQueue.isEmpty }
    var showsCinemaSuggestions: Bool {
        didSet { preferences.set(showsCinemaSuggestions, forKey: Self.cinemaSuggestionsKey) }
    }
    var cinemaRecommendationCount: CinemaRecommendationCount {
        didSet { preferences.set(cinemaRecommendationCount.rawValue, forKey: Self.cinemaCountKey) }
    }
    /// The chosen order per kind of video collection (see `Shelf.sortScope`), kept across launches.
    var videoSorts: [String: String] {
        didSet {
            collectionRevision &+= 1
            preferences.set(videoSorts, forKey: Self.videoSortKey)
        }
    }
    @ObservationIgnored var titleRankCache: (titles: [String], ranks: [Int64: Int])?
    private static let videoSortKey = "videoSort"
    /// The top-level view each library was last left in, by library ID.
    private static let landingKey = "lastShelf"
    /// Set while a library without a remembered view waits for its first snapshot.
    @ObservationIgnored private var landingPending = false
    private static let cinemaCountKey = "cinemaRecommendationCount"
    private static let cinemaSuggestionsKey = "showsCinemaSuggestions"
    var playing: Bool { mainPlayer.entryID != nil }
    var scanBusy = false
    var scanningFolder: String?
    var lookupActivity: String?
    var previews = PreviewProgress()
    var subscriptionRequired = false
    var lookupStatus: String?
    var networkStatus: String? {
        subscriptionRequired ? PRDBError.subscriptionRequired.localizedDescription : lookupStatus
    }
    @ObservationIgnored let posterPrepared = PassthroughSubject<URL, Never>()
    @ObservationIgnored let lookupFailures = LibraryJobs.Failures()
    @ObservationIgnored private var studioCache: StudioOptionsCache?
    /// Files whose video track could not be read during this session, by entry, size and date.
    @ObservationIgnored var unreadableVideoInfo = Set<String>()
    /// Changes whenever the inputs of `visibleVideos` other than the visit change.
    @ObservationIgnored private(set) var collectionRevision = 0
    @ObservationIgnored var visibleVideosCache: (key: VisibleVideosKey, videos: [CatalogEntry])?
    @ObservationIgnored var automaticCovers: AutomaticCollectionCovers?
    @ObservationIgnored private var snapshotRequested = false
    @ObservationIgnored private var editRevision = 0
    /// Entries with newly recorded playback, until the next coalesced refresh.
    @ObservationIgnored private var recordedEntryIDs = Set<Int64>()
    var setupReason: String?
    var notice: ActionNotice?
    var message: String?
    var failure: String?
    private let lastLibrary = "lastLibraryID"

    init(access: AccessController? = nil, client: PRDBClient = PRDBClient(),
         preferences: UserDefaults = .standard,
         directory: URL = URL.applicationSupportDirectory.appending(path: "net.prdb.vieweroo"),
         cache: PreviewCache = PreviewCache(root: URL.cachesDirectory.appending(path: "net.prdb.vieweroo/Previews")),
         catalogPort: UInt16 = CatalogAPIServer.defaultPort,
         artworkURL: @escaping (URL?) -> URL? = { $0 }, prepareCatalog: ((Catalog) throws -> Void)? = nil) {
        self.catalogPort = catalogPort
        self.access = access ?? AccessController(directory: directory)
        self.client = client
        self.cinemaRecommendationCount = CinemaRecommendationCount(rawValue: preferences.integer(forKey: Self.cinemaCountKey)) ?? .four
        self.showsCinemaSuggestions = preferences.object(forKey: Self.cinemaSuggestionsKey) as? Bool ?? true
        self.videoSorts = preferences.dictionary(forKey: Self.videoSortKey) as? [String: String] ?? [:]
        self.preferences = preferences
        self.directory = directory
        self.cache = cache
        self.artworkURL = artworkURL
        self.prepareCatalog = prepareCatalog
    }

    func start() {
        do {
            pinEnabled = try access.hasPIN
            if pinEnabled { phase = .locked }
            else { try enter() }
        } catch { failure = error.localizedDescription; phase = .failed }
    }

    func configure(key: String) async throws {
        try await access.validateAndStore(key: key.trimmingCharacters(in: .whitespacesAndNewlines), client: client)
        validated = true
        setupReason = nil
        subscriptionRequired = false
        try enter()
    }

    func unlock(pin: String) throws { try access.unlock(pin: pin); try enter() }
    func recover(pin: String) async throws { try await access.recoverPIN(new: pin); try enter() }

    private func enter() throws {
        guard try access.apiKey() != nil else { phase = .setup; return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try catalog ?? Catalog(path: directory.appending(path: "Catalog.sqlite").path)
        try prepareCatalog?(database)
        if catalog == nil {
            Task.detached(priority: .background) { [cache] in
                try? await cache.removeOrphans(in: database)
            }
        }
        catalog = database
        prdbTagDirectory = try? database.prdbTagDirectory()
        libraries = try database.libraries()
        phase = .ready
        startCatalogAPI()
        let last = (preferences.object(forKey: lastLibrary) as? NSNumber)?.int64Value
        selectLibrary(libraries.first { $0.id == last }?.id ?? libraries.first?.id)
    }

    func startCatalogAPI() {
        guard phase == .ready, let catalog else { return }
        stopCatalogAPI()
        catalogAPIError = nil
        do {
            guard let key = try access.catalogKey() else { catalogAPIEnabled = false; return }
            catalogAPIEnabled = true
            let server = try CatalogAPIServer(catalog: catalog, key: key, port: catalogPort)
            catalogServer = server
            server.start { [weak self, weak server] result in
                Task { @MainActor in
                    guard let self, let server, self.catalogServer === server else { return }
                    switch result {
                    case .success(let port): self.catalogAPIURL = "http://127.0.0.1:\(port)/v1"
                    case .failure:
                        self.stopCatalogAPI()
                        self.catalogAPIError = "Couldn’t start the local catalog API. Check whether its port is in use and retry."
                    }
                }
            } changed: { [weak self] change in
                Task { @MainActor in
                    guard let self, self.phase == .ready, self.catalog === catalog else { return }
                    switch change {
                    case .metadata(let library):
                        guard self.libraryID == library else { return }
                        self.editRevision &+= 1
                        self.reload()
                    case .renamed(let affected):
                        await self.refreshRenamedFiles(affected)
                    }
                }
            }
        } catch { catalogAPIError = error.localizedDescription }
    }

    func stopCatalogAPI() {
        catalogServer?.stop()
        catalogServer = nil
        catalogAPIURL = nil
    }

    func setCatalogAPIEnabled(_ enabled: Bool) {
        guard phase == .ready else { return }
        do {
            if enabled { try access.enableCatalogAPI() }
            else { try access.revokeCatalogKey() }
            startCatalogAPI()
        } catch { catalogAPIError = error.localizedDescription }
    }

    func copyCatalogKey() throws {
        guard phase == .ready, let key = try access.catalogKey() else { throw AccessError.unavailable }
        let item = NSPasteboardItem()
        item.setString(key, forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([item]) else { throw AccessError.unavailable }
    }

    private func stopWork() {
        notice = nil
        work.cancel()
        work = LibraryWork()
        scanToken = UUID()
        previewToken = UUID()
        automaticCovers = nil
        mainPlayer.stop()
        closeSecondPlayer(refresh: false)
        panel?.cancel(nil); panel = nil
        recordedEntryIDs.removeAll()
        scanQueue.removeAll()
        scanningSourceID = nil
        refreshRequested = false
        scanBusy = false; scanningFolder = nil; lookupStatus = nil
        previews = PreviewProgress(); lookupActivity = nil
    }

    func conceal(_ gate: Gate) {
        stopCatalogAPI()
        stopWork()
        ArtworkCache.shared.removeAll()
        phase = gate
        message = nil; libraryID = nil
        resetNavigation()
        libraries = []; sources = []; entries = []; playlists = []; tags = []; studioDirectory = StudioDirectory(); studioCache = nil; orderedIDs = []
        prdbTagDirectory = nil
        titleRankCache = nil
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        NSApp.windows.forEach { $0.displayIfNeeded() }
    }

    func lock() { if pinEnabled { conceal(.locked) } }

    func selectLibrary(_ id: Int64?, reopen: Bool = false) {
        guard phase == .ready, reopen || id == nil || id != libraryID else { return }
        stopWork()
        libraryID = id
        loadingLibrary = id != nil
        entries = []; sources = []; playlists = []; tags = []; studioDirectory = StudioDirectory(); studioCache = nil; orderedIDs = []
        resetNavigation()
        if let id {
            preferences.set(id, forKey: lastLibrary)
            let saved = (preferences.dictionary(forKey: Self.landingKey) as? [String: String])?[String(id)]
            if let shelf = saved.flatMap(Shelf.init(landingName:)) { visit = BrowseVisit(shelf: shelf) }
            else { landingPending = true }
        }
        let initialLoad = reload()
        guard let catalog else { return }
        let stamp = work
        if let id {
            work[.availability] = Task {
                do {
                    let probe = Task.detached(priority: .utility) { try catalog.checkSources(libraryID: id) }
                    let changed = try await withTaskCancellationHandler { try await probe.value } onCancel: { probe.cancel() }
                    guard work === stamp, !Task.isCancelled else { return }
                    if changed { await reload()?.value } else { await initialLoad?.value }
                    guard work === stamp, !Task.isCancelled else { return }
                    let pending = sources.filter { $0.online && $0.scanPending }
                    if !pending.isEmpty { scan(pending) } else if !scanBusy { generatePreviews() }
                } catch { if work === stamp, !Task.isCancelled { message = error.localizedDescription } }
            }
        }
        startLookups()
    }

    private func resetNavigation() {
        studioCovers.removeAll()
        favoriteStudioIDs.removeAll()
        history = BrowseHistory()
        landingPending = false
    }

    /// Reopen the library in this view next time. A collection inside Tags or Playlists
    /// returns to its overview, and other views keep the last remembered one.
    private func rememberLanding() {
        guard let libraryID, let name = shelf.landingName else { return }
        var saved = preferences.dictionary(forKey: Self.landingKey) as? [String: String] ?? [:]
        guard saved[String(libraryID)] != name else { return }
        saved[String(libraryID)] = name
        preferences.set(saved, forKey: Self.landingKey)
    }

    /// A library without a remembered view opens by studio. While fewer than two of its
    /// studios are identified, that overview shows little, so open All Videos instead.
    private func chooseLanding() {
        guard shelf == .studios, !history.canGoBack, detailID == nil, query.isEmpty, !entries.isEmpty else { return }
        var identified = Set<String>()
        for entry in entries where entry.studio != nil {
            identified.insert(studioDirectory.studio(for: entry).id)
            if identified.count > 1 { return }
        }
        visit = BrowseVisit(shelf: .all)
    }

    private func navigate(to next: BrowseVisit, from tile: BrowseTile? = nil) {
        guard phase == .ready, libraryID != nil else { return }
        if playing { endPlayback() }
        history.push(next, from: tile)
        landingPending = false
        rememberLanding()
        loadPlaylist(recordOpening: true)
    }

    func browse(_ destination: Shelf, from tile: BrowseTile? = nil) {
        guard destination != shelf || detailID != nil else { return }
        navigate(to: history.revisit(destination), from: tile)
    }

    func openDetail(_ id: Int64) {
        guard id != detailID else { return }
        if detailID != nil {
            history.replaceDetail(with: id)
        } else {
            let next = BrowseVisit(shelf: shelf, query: query, filters: visit.filters, detailID: id,
                                   selectedTile: .video(id), scroll: visit.scroll)
            navigate(to: next, from: .video(id))
        }
    }

    /// Move the keyboard highlight to a tile. Open details follow it to another video.
    func highlight(_ tile: BrowseTile) {
        guard phase == .ready, libraryID != nil, !playing else { return }
        if case let .video(id) = tile, detailID != nil { openDetail(id) }
        else { visit.selectedTile = tile }
    }

    func search(_ term: String) {
        refine(query: term, filters: visit.filters)
    }

    func setFilters(_ filters: CollectionFilters) {
        refine(query: query, filters: filters)
    }

    func refine(query: String, filters: CollectionFilters) {
        guard phase == .ready, libraryID != nil else { return }
        if detailID != nil {
            // A search or filter belongs to the collection. Close the details beside it first.
            guard !playing, query != visit.query || filters != visit.filters else { return }
            goBack()
            guard detailID == nil else { return }
        }
        defer { history.rememberCollection() }
        guard query != visit.query || filters != visit.filters else { return }
        if visit.query.isEmpty && visit.filters.isEmpty {
            navigate(to: BrowseVisit(shelf: shelf, query: query, filters: filters))
        } else if query.isEmpty && filters.isEmpty, history.clearingSearchReturns(to: shelf) {
            goBack()
        } else {
            visit.query = query
            visit.filters = filters
        }
    }

    func toggleStudioFavorite(_ studio: StudioOption) {
        guard let libraryID else { return }
        let save = !favoriteStudioIDs.contains(studio.id)
        change(save ? "Studio added to favorites" : "Studio removed from favorites") { db in
            try db.setStudioFavorite(libraryID: libraryID, studio: studio, favorite: save)
            if save { favoriteStudioIDs.insert(studio.id) } else { favoriteStudioIDs.remove(studio.id) }
        }
    }

    func renameTag(_ tag: CatalogTag, to name: String, onFailure: @escaping (String) -> Void) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return change("Tag renamed", onFailure: onFailure) { catalog in
            try catalog.renameTag(tag.id, to: clean)
            history.renameTag(tag.name, to: clean)
        }
    }

    func renameStudio(_ name: String, to newName: String, in libraryID: Int64, onFailure: @escaping (String) -> Void) -> Bool {
        guard self.libraryID == libraryID else { return false }
        let saved = change("Studio renamed", onFailure: onFailure) { catalog in
            try catalog.renameCustomStudio(libraryID: libraryID, name: name, to: newName)
            history.renameStudio(name, to: newName)
        }
        if saved { recognizeStudios() }
        return saved
    }

    func deleteStudio(_ name: String, in libraryID: Int64, onFailure: @escaping (String) -> Void) {
        guard self.libraryID == libraryID else { return }
        let deleted = change("Studio deleted", onFailure: onFailure) { catalog in
            try catalog.deleteCustomStudio(libraryID: libraryID, name: name)
            history.removeStudio(name)
        }
        if deleted { recognizeStudios() }
    }

    func goBack() {
        guard phase == .ready, history.canGoBack else { return }
        if playing { endPlayback() }
        _ = history.pop()
        rememberLanding()
        loadPlaylist(recordOpening: true)
    }

    /// Collapse overlapping scan and PRDB notifications into one follow-up read.
    @discardableResult
    func reload() -> Task<Void, Never>? {
        guard phase == .ready, let catalog else { return nil }
        snapshotRequested = true
        if let pending = work[.snapshot] { return pending }
        let stamp = work, id = libraryID
        let task = Task {
            guard work === stamp, !Task.isCancelled else { return }
            while snapshotRequested {
                let revision = editRevision
                snapshotRequested = false
                do {
                    let snapshot = try await catalog.snapshot(libraryID: id, studios: studioCache)
                    guard work === stamp, !Task.isCancelled else { return }
                    if revision != editRevision { continue }
                    studioCache = snapshot.studios
                    loadingLibrary = false
                    libraries = snapshot.libraries
                    sources = snapshot.sources
                    let availabilityChanged = work[.previews] != nil && !scanBusy &&
                        entries.lazy.filter { $0.availability == .available }.count !=
                        snapshot.entries.lazy.filter { $0.availability == .available }.count
                    entries = snapshot.entries
                    if availabilityChanged { generatePreviews() }
                    studioCovers = snapshot.studioCovers
                    favoriteStudioIDs = snapshot.favoriteStudioIDs
                    if snapshot.studioOptionsChanged { studioDirectory = StudioDirectory(snapshot.studioOptions) }
                    if landingPending {
                        landingPending = false
                        chooseLanding()
                    }
                    tags = snapshot.tags
                    let tagIDs = Set(tags.map(\.id))
                    playlists = snapshot.playlists
                    let entryIDs = Set(snapshot.entries.map(\.id))
                    let playlistIDs = Set(snapshot.playlists.map(\.id))
                    func valid(_ visit: BrowseVisit) -> Bool {
                        if let id = visit.detailID, !entryIDs.contains(id) { return false }
                        if case let .tag(id) = visit.shelf { return tagIDs.contains(id) }
                        if case let .playlist(id) = visit.shelf { return playlistIDs.contains(id) }
                        return true
                    }
                    if history.prune(keeping: valid), playing { endPlayback() }
                    loadPlaylist()
                    if cinemaMode, !mainPlayer.refresh(entries: entries, playlists: playlists) { goBack() }
                    if let secondPlayer, !secondPlayer.refresh(entries: entries, playlists: playlists) {
                        closeSecondPlayer()
                    }
                    let covers = AutomaticCollectionCovers(tags: tags, playlists: playlists, entries: entries, cache: cache)
                    if covers != automaticCovers {
                        automaticCovers = covers
                        if try await covers.prepare(in: catalog) {
                            guard work === stamp, !Task.isCancelled else { return }
                            snapshotRequested = true
                        }
                    }
                } catch {
                    guard work === stamp, !Task.isCancelled else { return }
                    automaticCovers = nil
                    loadingLibrary = false
                    message = error.localizedDescription
                }
            }
            stamp[.snapshot] = nil
        }
        work[.snapshot] = task
        return task
    }
    private func loadPlaylist(recordOpening: Bool = false) {
        guard case let .playlist(id) = shelf, let catalog, let libraryID else {
            orderedIDs = []
            return
        }
        do {
            orderedIDs = try catalog.playlistEntryIDs(id)
            if recordOpening, detailID == nil, recentPlaylists.first?.id != id {
                playlists = try catalog.recordPlaylistOpen(id, libraryID: libraryID)
                // An older in-flight snapshot could otherwise restore the previous order.
                if work[.snapshot] != nil {
                    editRevision &+= 1
                    reload()
                }
            }
        } catch { message = error.localizedDescription }
    }
    func notify(_ text: String, kind: ActionNotice.Kind = .success) {
        guard phase == .ready else { return }
        notice = ActionNotice(text: text, kind: kind)
    }

    /// Save one edit and show its result. Pass `entryIDs` when the edit changed only columns
    /// of those entries, such as a reaction, so the library is not read again as a whole.
    ///
    /// A single edit runs on the main thread, where its result decides what the interface
    /// does next. Background writers keep their transactions short for that reason, and
    /// batches use `editVideos`.
    @discardableResult
    func change(_ confirmation: String? = nil, kind: ActionNotice.Kind = .success, entryIDs: Set<Int64>? = nil,
                onFailure: ((String) -> Void)? = nil, _ operation: (Catalog) throws -> Void) -> Bool {
        guard phase == .ready, let catalog else { return false }
        do {
            try operation(catalog)
            if notice?.undo != nil { notice = nil }
            if let entryIDs { refreshEntries(entryIDs) }
            else {
                editRevision &+= 1
                reload()
            }
            if let confirmation { notify(confirmation, kind: kind) }
            return true
        } catch {
            let description = Self.failureDescription(error)
            if let onFailure { onFailure(description) }
            else { notify(description, kind: .error) }
            return false
        }
    }

    private static func failureDescription(_ error: Error) -> String {
        (error as? CatalogError)?.localizedDescription ?? "Couldn’t save the change. Try again."
    }

    /// Read single entries again after an edit to their own columns. A reaction or recorded
    /// playback then costs one row instead of a snapshot of the library.
    func refreshEntries(_ ids: Set<Int64>) {
        guard phase == .ready, let catalog, !ids.isEmpty else { return }
        // A snapshot in flight was read before this edit. Let it run again instead.
        guard work[.snapshot] == nil else {
            editRevision &+= 1
            reload()
            return
        }
        var updated = entries
        var changed = false
        for index in updated.indices where ids.contains(updated[index].id) {
            guard let fresh = try? catalog.entry(updated[index].id), fresh.libraryID == libraryID else {
                // Removed meanwhile. The snapshot also repairs navigation and the players.
                editRevision &+= 1
                reload()
                return
            }
            if fresh != updated[index] {
                updated[index] = fresh
                changed = true
            }
        }
        guard changed else { return }
        entries = updated
        if cinemaMode { _ = mainPlayer.refresh(entries: entries, playlists: playlists) }
        if let secondPlayer { _ = secondPlayer.refresh(entries: entries, playlists: playlists) }
    }

    /// A batch can touch thousands of rows. Run it off the main thread and return its receipt.
    func editVideos(_ ids: [Int64], edit: BulkVideoEdit) async -> Result<BulkEditReceipt, ActionFailure> {
        guard phase == .ready, let catalog, let library = libraryID, !ids.isEmpty else {
            return .failure(ActionFailure(description: "The library is not available."))
        }
        let stamp = work
        do {
            let receipt = try await Task.detached(priority: .userInitiated) {
                try catalog.editVideos(in: library, entryIDs: ids, edit: edit)
            }.value
            // The edit is saved even when the library closed meanwhile.
            guard phase == .ready, work === stamp else { return .failure(ActionFailure(description: "")) }
            if notice?.undo != nil { notice = nil }
            editRevision &+= 1
            reload()
            return .success(receipt)
        } catch { return .failure(ActionFailure(description: Self.failureDescription(error))) }
    }

    func undoBulkEdit(_ notice: ActionNotice) {
        guard phase == .ready, self.notice?.id == notice.id, let receipt = notice.undo, libraryID == receipt.libraryID,
              let catalog else { return }
        self.notice = nil
        let stamp = work
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try catalog.undoVideoEdit(receipt) }.value
                guard phase == .ready, work === stamp else { return }
                editRevision &+= 1
                reload()
                notify("Edit undone")
            } catch {
                guard phase == .ready, work === stamp else { return }
                notify(Self.failureDescription(error), kind: .error)
            }
        }
    }
    @discardableResult
    func createLibrary(_ name: String, onFailure: ((String) -> Void)? = nil) -> Bool {
        change("Library created", onFailure: onFailure) { db in selectLibrary(try db.createLibrary(name: name).id) }
    }
    func deleteLibrary() {
        guard let libraryID else { return }
        let deleted = change("Library deleted") { db in
            stopWork()
            try db.deleteLibrary(libraryID)
            var landings = preferences.dictionary(forKey: Self.landingKey) as? [String: String] ?? [:]
            landings[String(libraryID)] = nil
            preferences.set(landings, forKey: Self.landingKey)
            selectLibrary(try db.libraries().first?.id)
        }
        // Deletion stopped the library's work first. Resume it, or open the next library.
        guard !deleted, phase == .ready, self.libraryID == libraryID, let catalog else { return }
        let remaining = (try? catalog.libraries()) ?? libraries
        selectLibrary(remaining.contains { $0.id == libraryID } ? libraryID : remaining.first?.id, reopen: true)
    }
    func renameFile(_ entry: CatalogEntry, basename: String) async throws {
        guard phase == .ready, detailID == entry.id, let catalog else { throw FileRenameError.unavailable }
        let stamp = work
        let affected = try await Task.detached(priority: .userInitiated) {
            try catalog.renameFile(entry, basename: basename)
        }.value
        guard phase == .ready, self.catalog === catalog else { return }
        await refreshRenamedFiles(affected)
        if phase == .ready, work === stamp, !affected.isEmpty { notify("File renamed") }
    }

    private func refreshRenamedFiles(_ affected: [Int64: Set<Int64>]) async {
        guard let libraryID, let ids = affected[libraryID] else { return }
        let stamp = work
        editRevision &+= 1
        await reload()?.value
        guard phase == .ready, work === stamp else { return }
        let updated = entries.filter { ids.contains($0.id) }
        guard !updated.isEmpty else { return }
        for session in [mainPlayer, secondPlayer].compactMap({ $0 }) {
            if let entry = updated.first(where: { $0.id == session.entryID }) {
                session.playback.sourceRenamed(to: entry, previewDirectory: previewDirectory(entry))
            }
        }
        // Preview directories follow file paths. Check the other entries too if a run is active.
        if work[.previews] == nil || previews.phase == .idle { generatePreviews(only: updated) }
        else { generatePreviews() }
    }

    func previewDirectory(_ entry: CatalogEntry) -> URL {
        cache.directory(for: entry)
    }

    func play(_ selection: CatalogEntry, at position: Double? = nil, suggested: Bool = false) {
        play(selection, in: mainPlayer, at: position, suggested: suggested)
    }

    private func playableEntry(_ selection: CatalogEntry, suggested: Bool) -> CatalogEntry? {
        guard phase == .ready, selection.libraryID == libraryID, let catalog else { return nil }
        do {
            guard let entry = try catalog.entry(selection.id), entry.libraryID == libraryID,
                  entry.availability == .available, !suggested || entry.playbackFailure == nil else {
                reload()
                notify("This video is no longer available to play.", kind: .error)
                return nil
            }
            return entry
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    func play(_ selection: CatalogEntry, in destination: PlayerSession, at position: Double? = nil, suggested: Bool = true) {
        guard destination === mainPlayer || destination === secondPlayer, let catalog,
              let entry = playableEntry(selection, suggested: suggested) else { return }
        if !destination.cinemaMode {
            destination.setCinema(launchQueue(for: entry), collection: shelf)
        }
        if destination === mainPlayer {
            if !playing {
                visit.scroll.save()
                openDetail(entry.id)
            } else if detailID != entry.id {
                history.replaceDetail(with: entry.id)
            }
            if !playing, secondPlayer?.playback.isAudible == true, !playback.muted { playback.toggleMute() }
        }
        destination.open(entry, at: position, model: self, catalog: catalog)
        reload()
    }

    private func launchQueue(for entry: CatalogEntry) -> [CatalogEntry] {
        let visible = visibleVideos
        return visible.contains { $0.id == entry.id } ? visible : [entry]
    }

    func playOnDisplay(_ selection: CatalogEntry, screen: NSScreen) {
        guard let catalog, let entry = playableEntry(selection, suggested: true),
              NSScreen.screens.contains(where: { $0.displayID == screen.displayID }) else { return }
        let destination = PlayerSession()
        if playback.isAudible { destination.playback.toggleMute() }
        closeSecondPlayer()
        secondPlayer = destination
        destination.setCinema(launchQueue(for: entry), collection: shelf)
        destination.open(entry, at: nil, model: self, catalog: catalog)
        playerDisplay.present(destination, model: self, on: screen)
    }

    func startCinema(on screen: NSScreen) {
        guard shelf.isVideoCollection, !playing else { return }
        let queue = visibleVideos
        if let first = queue.first(where: Self.cinemaPlayable) { playOnDisplay(first, screen: screen) }
    }

    func movePlayer(_ source: PlayerSession, to screen: NSScreen) {
        guard phase == .ready, source.entryID != nil,
              NSScreen.screens.contains(where: { $0.displayID == screen.displayID }) else { return }
        if source === mainPlayer { detachMainPlayer() }
        guard source === secondPlayer else { return }
        playerDisplay.present(source, model: self, on: screen)
    }

    func detachMainPlayer() {
        guard playing else { return }
        closeSecondPlayer()
        secondPlayer = mainPlayer
        mainPlayer = PlayerSession()
        goBack()
    }

    func closeSecondPlayer(refresh: Bool = true) {
        guard let secondPlayer else { return }
        secondPlayer.stop()
        playerDisplay.dismiss()
        self.secondPlayer = nil
        if refresh { reload() }
    }

    func startCinema() {
        guard shelf.isVideoCollection, !playing else { return }
        let queue = visibleVideos
        guard let first = queue.first(where: Self.cinemaPlayable) else { return }
        play(first, suggested: true)
    }

    nonisolated static func cinemaPlayable(_ entry: CatalogEntry) -> Bool {
        entry.availability == .available && entry.playbackFailure == nil
    }

    /// Recorded intervals change Watch History, play counts and the Unplayed filter.
    /// Coalesce the periodic writes of both players and read only the played entries again.
    func playbackRecorded(_ entryID: Int64) {
        guard phase == .ready else { return }
        recordedEntryIDs.insert(entryID)
        guard work[.playbackRefresh] == nil else { return }
        let stamp = work
        work[.playbackRefresh] = Task {
            try? await Task.sleep(for: .seconds(2))
            stamp[.playbackRefresh] = nil
            guard work === stamp, !Task.isCancelled else { return }
            let played = recordedEntryIDs
            recordedEntryIDs.removeAll()
            refreshEntries(played)
        }
    }

    func endPlayback() {
        mainPlayer.stop()
        reload()
    }
}
