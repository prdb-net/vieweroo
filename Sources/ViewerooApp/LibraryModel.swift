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
    @ObservationIgnored private var validated = false
    @ObservationIgnored private var directoryUpdated: Date?
    @ObservationIgnored private(set) var catalog: Catalog?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var availabilityTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanQueue: [CatalogSource] = []
    @ObservationIgnored private var scanningSourceID: Int64?
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var videoInfoTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var scanToken = UUID()
    @ObservationIgnored private var panel: NSOpenPanel?
    @ObservationIgnored private var previewToken = UUID()
    var phase = Gate.starting
    @ObservationIgnored private var catalogServer: CatalogAPIServer?
    @ObservationIgnored private let catalogPort: UInt16
    private(set) var catalogAPIEnabled = false
    private(set) var catalogAPIURL: String?
    private(set) var catalogAPIError: String?
    var pinEnabled = false
    var libraries: [CatalogLibrary] = []
    var sources: [CatalogSource] = []
    var entries: [CatalogEntry] = []
    var studioCovers: [String: CatalogCover] = [:]
    var favoriteStudioIDs: Set<String> = []
    var studioDirectory = StudioDirectory()
    var studioOptions: [StudioOption] { studioDirectory.options }
    var tags: [CatalogTag] = []
    var playlists: [CatalogPlaylist] = []
    var recentPlaylists: [CatalogPlaylist] {
        Array(playlists.filter { $0.lastOpenedOrder > 0 }.sorted { $0.lastOpenedOrder > $1.lastOpenedOrder }.prefix(5))
    }
    var orderedIDs: [Int64] = []
    private(set) var loadingLibrary = false
    var libraryID: Int64?
    private(set) var visit = BrowseVisit()
    private var backHistory: [BrowseVisit] = []
    @ObservationIgnored private var lastCollections: [CollectionKey: BrowseVisit] = [:]
    var shelf: Shelf { visit.shelf }
    var query: String { visit.query }
    var detailID: Int64? { visit.detailID }
    var canGoBack: Bool { !backHistory.isEmpty }
    var cinemaQueue: [CatalogEntry] { mainPlayer.cinemaQueue }
    var cinemaMode: Bool { !cinemaQueue.isEmpty }
    var showsCinemaSuggestions: Bool {
        didSet { preferences.set(showsCinemaSuggestions, forKey: Self.cinemaSuggestionsKey) }
    }
    var cinemaRecommendationCount: CinemaRecommendationCount {
        didSet { preferences.set(cinemaRecommendationCount.rawValue, forKey: Self.cinemaCountKey) }
    }
    private static let cinemaCountKey = "cinemaRecommendationCount"
    private static let cinemaSuggestionsKey = "showsCinemaSuggestions"
    var playing: Bool { mainPlayer.entryID != nil }
    var scanBusy = false
    private(set) var scanningFolder: String?
    private(set) var lookupActivity: String?
    private(set) var previews = PreviewProgress()
    private(set) var subscriptionRequired = false
    private var lookupStatus: String?
    var networkStatus: String? {
        subscriptionRequired ? PRDBError.subscriptionRequired.localizedDescription : lookupStatus
    }
    @ObservationIgnored let posterPrepared = PassthroughSubject<URL, Never>()
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var playbackRefresh: Task<Void, Never>?
    @ObservationIgnored private let lookupFailures = LibraryJobs.Failures()
    @ObservationIgnored private var automaticCovers: AutomaticCollectionCovers?
    @ObservationIgnored private var snapshotRequested = false
    @ObservationIgnored private var editRevision = 0
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

    func replacePRDBKey(_ input: String) async throws {
        guard phase == .ready else { throw CancellationError() }
        let stamp = session
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if try access.apiKey() == key {
            do { try await client.validate(key: key) }
            catch {
                guard session == stamp, !Task.isCancelled else { throw CancellationError() }
                handleNetwork(error, key: key)
                throw error
            }
        } else {
            try await access.validateAndStore(key: key, client: client, while: { self.session == stamp })
        }
        try Task.checkCancellation()
        guard phase == .ready, session == stamp else { throw CancellationError() }
        validated = true
        subscriptionRequired = false
        lookupStatus = nil
        startLookups()
        notify("PRDB key verified")
    }

    func retrySubscription() {
        guard phase == .ready, subscriptionRequired else { return }
        validated = false
        subscriptionRequired = false
        lookupStatus = nil
        startLookups()
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
            } changed: { [weak self] library in
                Task { @MainActor in
                    guard let self, self.phase == .ready, self.libraryID == library else { return }
                    self.editRevision &+= 1
                    self.reload()
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
        session = UUID()
        scanToken = UUID()
        previewToken = UUID()
        automaticCovers = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        playbackRefresh?.cancel()
        playbackRefresh = nil
        videoInfoTask?.cancel()
        worker?.cancel(); availabilityTask?.cancel(); scanTask?.cancel(); previewTask?.cancel()
        mainPlayer.stop()
        closeSecondPlayer(refresh: false)
        panel?.cancel(nil); panel = nil
        scanQueue.removeAll()
        scanningSourceID = nil
        refreshRequested = false
        scanBusy = false; scanningFolder = nil; lookupStatus = nil
        previews = PreviewProgress(); lookupActivity = nil
        previewTask = nil
    }

    private func conceal(_ gate: Gate) {
        stopCatalogAPI()
        stopWork()
        phase = gate
        message = nil; libraryID = nil
        resetNavigation()
        libraries = []; sources = []; entries = []; playlists = []; tags = []; studioDirectory = StudioDirectory(); orderedIDs = []
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        NSApp.windows.forEach { $0.displayIfNeeded() }
    }

    func lock() { if pinEnabled { conceal(.locked) } }

    func handleNetwork(_ error: Error, key: String) {
        guard phase == .ready, (try? access.apiKey()) == key else { return }
        if case PRDBError.invalidKey = error {
            validated = false
            subscriptionRequired = false
            setupReason = "PRDB rejected the saved key. Enter a valid replacement to reopen your libraries."
            conceal(pinEnabled ? .locked : .setup)
            do { try access.reject(key: key) }
            catch { failure = error.localizedDescription; phase = .failed }
        } else if !Task.isCancelled {
            switch error {
            case PRDBError.subscriptionRequired:
                subscriptionRequired = true
                lookupActivity = nil
                worker?.cancel()
            case PRDBError.rateLimited:
                lookupStatus = "PRDB’s request limit was reached. Pending lookups will retry."
            default:
                lookupStatus = "PRDB unavailable. Pending lookups will retry."
            }
        }
    }

    func selectLibrary(_ id: Int64?) {
        guard phase == .ready, id == nil || id != libraryID else { return }
        stopWork()
        libraryID = id
        loadingLibrary = id != nil
        entries = []; sources = []; playlists = []; tags = []; studioDirectory = StudioDirectory(); orderedIDs = []
        resetNavigation()
        if let id { preferences.set(id, forKey: lastLibrary) }
        let initialLoad = reload()
        guard let catalog else { return }
        let stamp = session
        if let id {
            availabilityTask = Task {
                do {
                    let probe = Task.detached(priority: .utility) { try catalog.checkSources(libraryID: id) }
                    let changed = try await withTaskCancellationHandler { try await probe.value } onCancel: { probe.cancel() }
                    guard session == stamp, !Task.isCancelled else { return }
                    if changed { await reload()?.value } else { await initialLoad?.value }
                    guard session == stamp, !Task.isCancelled else { return }
                    let pending = sources.filter { $0.online && $0.scanPending }
                    if !pending.isEmpty { scan(pending) } else if !scanBusy { generatePreviews() }
                } catch { if session == stamp, !Task.isCancelled { message = error.localizedDescription } }
            }
        }
        startLookups()
    }

    private func resetNavigation() {
        studioCovers.removeAll()
        favoriteStudioIDs.removeAll()
        backHistory.removeAll()
        lastCollections.removeAll()
        visit = BrowseVisit()
    }

    private func navigate(to next: BrowseVisit, from tile: BrowseTile? = nil) {
        guard phase == .ready, libraryID != nil else { return }
        if playing { endPlayback() }
        if let tile { visit.selectedTile = tile }
        saveCurrentLocation()
        backHistory.append(visit)
        visit = next
        loadPlaylist(recordOpening: true)
    }

    private func saveCurrentLocation() {
        visit.scroll.save()
        visit.castScroll.save()
        guard detailID == nil else { return }
        let key = CollectionKey(shelf)
        // Back can display an older search. Passing through it does not apply it again.
        if let latest = lastCollections[key], latest.query != query || latest.filters != visit.filters { return }
        lastCollections[key] = visit
    }

    func browse(_ destination: Shelf, from tile: BrowseTile? = nil) {
        guard destination != shelf || detailID != nil else { return }
        let next = lastCollections[CollectionKey(destination)]?.reopened(on: destination) ?? BrowseVisit(shelf: destination)
        navigate(to: next, from: tile)
    }

    func openDetail(_ id: Int64) {
        guard id != detailID else { return }
        if detailID != nil {
            visit.detailID = id
            visit.selectedTile = .video(id)
            if let index = backHistory.indices.last {
                backHistory[index].selectedTile = .video(id)
            }
        } else {
            let next = BrowseVisit(shelf: shelf, query: query, filters: visit.filters, detailID: id,
                                   selectedTile: .video(id), scroll: visit.scroll)
            navigate(to: next, from: .video(id))
        }
    }

    func search(_ term: String) {
        refine(query: term, filters: visit.filters)
    }

    func setFilters(_ filters: CollectionFilters) {
        refine(query: query, filters: filters)
    }

    func refine(query: String, filters: CollectionFilters) {
        guard phase == .ready, libraryID != nil, detailID == nil else { return }
        defer { lastCollections[CollectionKey(shelf)] = visit }
        guard query != visit.query || filters != visit.filters else { return }
        if visit.query.isEmpty && visit.filters.isEmpty {
            navigate(to: BrowseVisit(shelf: shelf, query: query, filters: filters))
        } else if query.isEmpty && filters.isEmpty, let previous = backHistory.last,
                  previous.shelf == shelf, previous.detailID == nil, previous.query.isEmpty, previous.filters.isEmpty {
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
            func update(_ visit: inout BrowseVisit) {
                if visit.filters.tags.removeValue(forKey: tag.name.lowercased()) != nil {
                    visit.filters.tags[clean.lowercased()] = clean
                }
            }
            update(&visit)
            for index in backHistory.indices { update(&backHistory[index]) }
            for key in lastCollections.keys {
                if var saved = lastCollections[key] {
                    update(&saved)
                    lastCollections[key] = saved
                }
            }
        }
    }

    func renameStudio(_ name: String, to newName: String, in libraryID: Int64, onFailure: @escaping (String) -> Void) -> Bool {
        guard self.libraryID == libraryID else { return false }
        return change("Studio renamed", onFailure: onFailure) { catalog in
            try catalog.renameCustomStudio(libraryID: libraryID, name: name, to: newName)
            visit.renameStudio(name, to: newName)
            for index in backHistory.indices { backHistory[index].renameStudio(name, to: newName) }
            let oldKey = CollectionKey(.studio(name)), newKey = CollectionKey(.studio(newName))
            if let saved = lastCollections.removeValue(forKey: oldKey) { lastCollections[newKey] = saved }
            for key in lastCollections.keys { lastCollections[key]?.renameStudio(name, to: newName) }
        }
    }

    func deleteStudio(_ name: String, in libraryID: Int64, onFailure: @escaping (String) -> Void) {
        guard self.libraryID == libraryID else { return }
        change("Studio deleted", onFailure: onFailure) { catalog in
            try catalog.deleteCustomStudio(libraryID: libraryID, name: name)
            let key = CollectionKey(.studio(name))
            lastCollections.removeValue(forKey: key)
            backHistory.removeAll { $0.detailID == nil && CollectionKey($0.shelf) == key }
        }
    }

    func goBack() {
        guard phase == .ready, let previous = backHistory.popLast() else { return }
        if playing { endPlayback() }
        saveCurrentLocation()
        visit = previous
        loadPlaylist(recordOpening: true)
    }

    /// Collapse overlapping scan and PRDB notifications into one follow-up read.
    @discardableResult
    func reload() -> Task<Void, Never>? {
        guard phase == .ready, let catalog else { return nil }
        snapshotRequested = true
        if let snapshotTask { return snapshotTask }
        let stamp = session, id = libraryID
        let task = Task {
            guard session == stamp, !Task.isCancelled else { return }
            while snapshotRequested {
                let revision = editRevision
                snapshotRequested = false
                do {
                    let snapshot = try await catalog.snapshot(libraryID: id)
                    guard session == stamp, !Task.isCancelled else { return }
                    if revision != editRevision { continue }
                    loadingLibrary = false
                    libraries = snapshot.libraries
                    sources = snapshot.sources
                    let availabilityChanged = previewTask != nil && !scanBusy &&
                        entries.lazy.filter { $0.availability == .available }.count !=
                        snapshot.entries.lazy.filter { $0.availability == .available }.count
                    entries = snapshot.entries
                    if availabilityChanged { generatePreviews() }
                    studioCovers = snapshot.studioCovers
                    favoriteStudioIDs = snapshot.favoriteStudioIDs
                    studioDirectory = StudioDirectory(snapshot.studioOptions)
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
                    backHistory.removeAll { !valid($0) }
                    lastCollections = lastCollections.filter { valid($0.value) }
                    if !valid(visit) {
                        if playing { endPlayback() }
                        visit = backHistory.popLast() ?? BrowseVisit()
                    }
                    loadPlaylist()
                    if cinemaMode, !mainPlayer.refresh(entries: entries, playlists: playlists) { goBack() }
                    if let secondPlayer, !secondPlayer.refresh(entries: entries, playlists: playlists) {
                        closeSecondPlayer()
                    }
                    let covers = AutomaticCollectionCovers(tags: tags, playlists: playlists, entries: entries, cache: cache)
                    if covers != automaticCovers {
                        automaticCovers = covers
                        if try await covers.prepare(in: catalog) {
                            guard session == stamp, !Task.isCancelled else { return }
                            snapshotRequested = true
                        }
                    }
                } catch {
                    guard session == stamp, !Task.isCancelled else { return }
                    automaticCovers = nil
                    loadingLibrary = false
                    message = error.localizedDescription
                }
            }
            snapshotTask = nil
        }
        snapshotTask = task
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
                if snapshotTask != nil {
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

    @discardableResult
    func change(_ confirmation: String? = nil, kind: ActionNotice.Kind = .success,
                onFailure: ((String) -> Void)? = nil, _ operation: (Catalog) throws -> Void) -> Bool {
        guard phase == .ready, let catalog else { return false }
        do {
            try operation(catalog)
            if notice?.undo != nil { notice = nil }
            editRevision &+= 1
            reload()
            if let confirmation { notify(confirmation, kind: kind) }
            return true
        } catch {
            let description = (error as? CatalogError)?.localizedDescription ?? "Couldn’t save the change. Try again."
            if let onFailure { onFailure(description) }
            else { notify(description, kind: .error) }
            return false
        }
    }
    @discardableResult
    func createLibrary(_ name: String, onFailure: ((String) -> Void)? = nil) -> Bool {
        change("Library created", onFailure: onFailure) { db in selectLibrary(try db.createLibrary(name: name).id) }
    }
    func deleteLibrary() {
        guard let libraryID else { return }
        change("Library deleted") { db in
            stopWork()
            try db.deleteLibrary(libraryID)
            selectLibrary(try db.libraries().first?.id)
        }
    }
    func pickSource() {
        guard phase == .ready, libraryID != nil, let window = NSApp.keyWindow, panel == nil else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.prompt = "Add Folder"; picker.allowsMultipleSelection = true
        panel = picker
        let stamp = session
        picker.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.session == stamp else { return }
            self.panel = nil
            guard response == .OK else { return }
            self.addSources(picker.urls)
        }
    }

    func addSources(_ urls: [URL]) {
        guard phase == .ready, let libraryID else { return }
        guard !urls.isEmpty else { return }
        let saved = change(urls.count == 1 ? "Source folder saved" : "Source folders saved") { db in
            for url in urls { _ = try db.addSource(libraryID: libraryID, url: url) }
        }
        // A multi-folder selection may have saved earlier folders before a later one failed.
        if !saved { reload() }
        scanCurrentSources(requested: false)
    }

    func refresh() {
        guard phase == .ready, libraryID != nil else { return }
        availabilityTask?.cancel()
        scanCurrentSources(requested: true)
    }

    private func scanCurrentSources(requested: Bool) {
        guard let catalog, let libraryID else { return }
        do {
            let sources = try catalog.sources(libraryID: libraryID)
            let pending = requested ? sources : sources.filter { $0.scanPending && $0.online }
            if requested || !pending.isEmpty { scan(pending, requested: requested) }
        } catch { message = error.localizedDescription }
    }

    private func scan(_ list: [CatalogSource], requested: Bool = false) {
        guard let catalog else { return }
        refreshRequested = refreshRequested || requested
        var queued = Set(scanQueue.map(\.id))
        for source in list where (requested || source.id != scanningSourceID) && queued.insert(source.id).inserted {
            scanQueue.append(source)
        }
        guard !scanBusy else { return }
        let token = UUID()
        scanToken = token; scanBusy = true
        scanTask = Task {
            var errors: [String] = []
            while true {
                guard scanToken == token, !Task.isCancelled else { return }
                if scanQueue.isEmpty {
                    await reload()?.value
                    guard scanToken == token, !Task.isCancelled else { return }
                    if scanQueue.isEmpty { break }
                }
                let source = scanQueue.removeFirst()
                scanningSourceID = source.id
                scanningFolder = source.url.lastPathComponent
                let task = Task.detached(priority: .utility) {
                    // Scanner reports each committed batch serially on its worker.
                    let throttle = DiscoveryUpdates()
                    try CatalogScanner(catalog: catalog).scan(source: source) {
                        if throttle.shouldRefresh() {
                            Task { @MainActor in if self.scanToken == token { self.reload() } }
                        }
                    }
                }
                do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
                catch { if !Task.isCancelled { errors.append("\(source.url.lastPathComponent) (\(error.localizedDescription))") } }
                guard scanToken == token else { return }
                scanningSourceID = nil
            }
            scanBusy = false; scanningFolder = nil
            if !errors.isEmpty {
                message = "Some folders could not be scanned: " + errors.joined(separator: ", ")
            } else if refreshRequested {
                notify("Library refreshed")
            }
            refreshRequested = false
            generatePreviews()
            startLookups()
        }
    }

    func renameFile(_ entry: CatalogEntry, basename: String) async throws {
        guard phase == .ready, detailID == entry.id, let catalog else { throw FileRenameError.unavailable }
        let stamp = session
        try await Task.detached(priority: .userInitiated) {
            try catalog.renameFile(entry, basename: basename)
        }.value
        guard phase == .ready, session == stamp else { return }
        editRevision &+= 1
        await reload()?.value
        guard phase == .ready, session == stamp else { return }
        if let updated = entries.first(where: { $0.id == entry.id }), updated.path != entry.path {
            if playing && detailID == entry.id {
                playback.sourceRenamed(from: entry.url, to: updated, previewDirectory: previewDirectory(updated))
            }
            secondPlayer?.playback.sourceRenamed(from: entry.url, to: updated, previewDirectory: previewDirectory(updated))
            generatePreviews()
            notify("File renamed")
        }
    }

    func previewDirectory(_ entry: CatalogEntry) -> URL {
        cache.directory(for: entry)
    }

    private func readVideoInfo(in entries: [CatalogEntry], catalog: Catalog) {
        videoInfoTask?.cancel()
        videoInfoTask = Task(priority: .utility) {
            let updates = DiscoveryUpdates()
            var pendingReload = false
            for entry in entries where entry.videoInfo == nil {
                guard !Task.isCancelled else { return }
                do {
                    guard let info = try await VideoInfo.read(from: entry.url) else { continue }
                    try Task.checkCancellation()
                    try await catalog.storeVideoInfo(info, for: entry)
                    guard !Task.isCancelled else { return }
                    pendingReload = true
                    if entry.id == detailID || updates.shouldRefresh() {
                        reload()
                        pendingReload = false
                    }
                } catch { /* An unreadable file is retried on refresh or next launch. */ }
            }
            if pendingReload && !Task.isCancelled { reload() }
        }
    }

    private func generatePreviews() {
        guard let catalog else { return }
        previewTask?.cancel()
        let token = UUID()
        previewToken = token
        let pending = entries.filter { $0.availability == .available }
        readVideoInfo(in: pending, catalog: catalog)
        previews = PreviewProgress(phase: .checking)
        previewTask = Task(priority: .utility) {
            // Older catalogs may already have preview images but lack movie durations.
            var backfilled = false
            for entry in pending where entry.playCount > 0 && entry.duration == nil {
                guard previewToken == token else { return }
                previews.phase = .readingDurations
                if let duration = try? await AVURLAsset(url: entry.url).load(.duration).seconds,
                   duration.isFinite, duration > 0 {
                    guard previewToken == token else { return }
                    do {
                        try catalog.setDuration(duration, for: entry)
                        backfilled = true
                    } catch { /* Retry when the library is next opened or refreshed. */ }
                }
            }
            guard previewToken == token else { return }
            previews.phase = .checking
            guard let missing = try? await PreviewProgress.missing(in: pending, cache: cache),
                  previewToken == token else { return }
            previews = PreviewProgress(phase: .preparing, total: pending.count, remaining: missing[...])
            var failuresChanged = false
            for entry in missing {
                guard !Task.isCancelled else { return }
                let directory = previewDirectory(entry)
                do {
                    _ = try await cache.prepare(media: entry.url, directory: directory)
                    guard previewToken == token else { return }
                    posterPrepared.send(directory)
                    if automaticCovers?.candidates.values.contains(where: { $0.contains(where: { $0.id == entry.id }) }) == true {
                        automaticCovers = nil
                        reload()
                    }
                } catch {
                    guard previewToken == token, !Task.isCancelled else { return }
                    previews.failures.append(.init(entry: entry, reason: error.localizedDescription))
                    if case PreviewError.unsupportedVideo = error, entry.playbackFailure != error.localizedDescription {
                        failuresChanged = true
                        try? catalog.setPlaybackFailure(entryID: entry.id, message: error.localizedDescription,
                                                        fileSize: entry.fileSize, modified: entry.modified)
                    }
                }
                previews.remaining.removeFirst()
            }
            previews.phase = .idle
            previews.remaining = []
            if backfilled || failuresChanged { reload() }
        }
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
                visit.detailID = entry.id
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
    /// Coalesce the periodic writes of both players into one snapshot.
    func playbackRecorded() {
        guard phase == .ready, playbackRefresh == nil else { return }
        let stamp = session
        playbackRefresh = Task {
            try? await Task.sleep(for: .seconds(2))
            playbackRefresh = nil
            guard session == stamp, !Task.isCancelled else { return }
            reload()
        }
    }

    func endPlayback() {
        mainPlayer.stop()
        reload()
    }

    private func startLookups() {
        guard let catalog, let key = try? access.apiKey() else { return }
        worker?.cancel()
        lookupActivity = nil
        let id = libraryID, stamp = session, client = client
        worker = Task(priority: .utility) {
            await snapshotTask?.value
            guard session == stamp, !Task.isCancelled else { return }
            if let id, entries.contains(where: \.needsLookup) {
                lookupActivity = "Recognizing studios…"
                try? await LibraryJobs.detectStudios(libraryID: id, catalog: catalog)
                guard session == stamp, !Task.isCancelled else { return }
                lookupActivity = nil
                reload()
            }
            while !Task.isCancelled && !subscriptionRequired {
                do {
                    if !validated {
                        lookupActivity = "Checking access…"
                        try await client.validate(key: key)
                        try Task.checkCancellation()
                        validated = true
                    }
                    if let id, directoryUpdated.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true {
                        lookupActivity = "Updating studio directory…"
                        let directory = try await client.studios(key: key)
                        try Task.checkCancellation()
                        try catalog.saveStudios(directory)
                        directoryUpdated = Date()
                        try await LibraryJobs.detectStudios(libraryID: id, catalog: catalog)
                        try Task.checkCancellation()
                        reload()
                    }
                    if let id, entries.contains(where: { $0.needsLookup && $0.availability == .available }) {
                        lookupActivity = "Matching videos…"
                        try await LibraryJobs.identify(libraryID: id, catalog: catalog, key: key, client: client,
                                                      failures: lookupFailures) {
                            await MainActor.run { if self.session == stamp { _ = self.reload() } }
                        }
                    }
                    guard session == stamp, !Task.isCancelled else { return }
                    lookupStatus = nil
                } catch {
                    guard session == stamp, !Task.isCancelled else { return }
                    lookupActivity = nil
                    handleNetwork(error, key: key)
                    if phase != .ready || subscriptionRequired { return }
                }
                lookupActivity = nil
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

// Coalesce incremental discoveries while preserving the first visible result.
private final class DiscoveryUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func shouldRefresh() -> Bool {
        lock.withLock {
            let now = Date()
            guard now.timeIntervalSince(last) >= 0.6 else { return false }
            last = now; return true
        }
    }
}
