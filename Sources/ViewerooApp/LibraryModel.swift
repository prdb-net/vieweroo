import AppKit
import AVFoundation
import Combine
import Foundation
import Observation
import ViewerooCore

enum Gate { case starting, setup, locked, ready, failed }

enum Shelf: Hashable {
    case studios, all, favorites, liked, frequent, sources
    case studio(String), performer(PRDBPerformer), playlist(Int64)
}

@MainActor @Observable
final class LibraryModel {
    @ObservationIgnored let access: AccessController
    @ObservationIgnored let client: PRDBClient
    @ObservationIgnored let playback = PlayerController()
    @ObservationIgnored let artworkURL: (URL?) -> URL?
    @ObservationIgnored private let prepareCatalog: ((Catalog) throws -> Void)?
    @ObservationIgnored let cache: PreviewCache
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var validated = false
    @ObservationIgnored private var directoryUpdated: Date?
    @ObservationIgnored private var retryAfter: Date?
    @ObservationIgnored private(set) var catalog: Catalog?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var availabilityTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var scanToken = UUID()
    @ObservationIgnored private var panel: NSOpenPanel?
    @ObservationIgnored private var previewToken = UUID()
    var phase = Gate.starting
    var pinEnabled = false
    var libraries: [CatalogLibrary] = []
    var sources: [CatalogSource] = []
    var entries: [CatalogEntry] = []
    var playlists: [CatalogPlaylist] = []
    var orderedIDs: [Int64] = []
    private(set) var loadingLibrary = false
    var libraryID: Int64?
    private(set) var visit = BrowseVisit()
    private var backHistory: [BrowseVisit] = []
    var shelf: Shelf { visit.shelf }
    var query: String { visit.query }
    var detailID: Int64? { visit.detailID }
    var detailsExpanded: Bool {
        get { visit.detailsExpanded }
        set { visit.detailsExpanded = newValue }
    }
    var canGoBack: Bool { !backHistory.isEmpty }
    var playing = false
    var scanBusy = false
    var activity: String?
    var networkStatus: String?
    @ObservationIgnored let posterPrepared = PassthroughSubject<URL, Never>()
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotRequested = false
    @ObservationIgnored private var editRevision = 0
    var setupReason: String?
    var notice: ActionNotice?
    var message: String?
    var failure: String?
    private let lastLibrary = "lastLibraryID"

    init(access: AccessController = AccessController(), client: PRDBClient = PRDBClient(),
         preferences: UserDefaults = .standard,
         directory: URL = URL.applicationSupportDirectory.appending(path: "net.prdb.vieweroo"),
         cache: PreviewCache = PreviewCache(root: URL.cachesDirectory.appending(path: "net.prdb.vieweroo/Previews")),
         artworkURL: @escaping (URL?) -> URL? = { $0 }, prepareCatalog: ((Catalog) throws -> Void)? = nil) {
        self.access = access
        self.client = client
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
        retryAfter = nil
        try enter()
    }
    func unlock(pin: String) throws { try access.unlock(pin: pin); try enter() }
    func recover(pin: String) async throws { try await access.recoverPIN(new: pin); try enter() }

    private func enter() throws {
        guard try access.apiKey() != nil else { phase = .setup; return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try catalog ?? Catalog(path: directory.appending(path: "Catalog.sqlite").path)
        try prepareCatalog?(database)
        catalog = database
        libraries = try database.libraries()
        phase = .ready
        let last = (preferences.object(forKey: lastLibrary) as? NSNumber)?.int64Value
        selectLibrary(libraries.first { $0.id == last }?.id ?? libraries.first?.id)
    }

    private func stopWork() {
        notice = nil
        session = UUID()
        scanToken = UUID()
        previewToken = UUID()
        snapshotTask?.cancel()
        snapshotTask = nil
        worker?.cancel(); availabilityTask?.cancel(); scanTask?.cancel(); previewTask?.cancel()
        playback.stop(); playing = false
        panel?.cancel(nil); panel = nil
        scanBusy = false; activity = nil; networkStatus = nil
    }

    private func conceal(_ gate: Gate) {
        stopWork()
        phase = gate
        message = nil; libraryID = nil
        resetNavigation()
        libraries = []; sources = []; entries = []; playlists = []; orderedIDs = []
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
            setupReason = "PRDB rejected the saved key. Enter a valid replacement to reopen your libraries."
            conceal(pinEnabled ? .locked : .setup)
            do { try access.reject(key: key) }
            catch { failure = error.localizedDescription; phase = .failed }
        } else if !Task.isCancelled {
            networkStatus = "PRDB unavailable. Pending lookups will retry."
        }
    }

    func selectLibrary(_ id: Int64?) {
        guard phase == .ready else { return }
        stopWork()
        libraryID = id
        loadingLibrary = id != nil
        entries = []; sources = []; playlists = []; orderedIDs = []
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
                    if !pending.isEmpty { scan(pending) } else { generatePreviews() }
                } catch { if session == stamp, !Task.isCancelled { message = error.localizedDescription } }
            }
        }
        startLookups()
    }

    private func resetNavigation() {
        backHistory.removeAll()
        visit = BrowseVisit()
    }

    private func navigate(to next: BrowseVisit, from tile: BrowseTile? = nil) {
        guard phase == .ready, libraryID != nil, !playing else { return }
        visit.scroll.save()
        visit.castScroll.save()
        if let tile { visit.selectedTile = tile }
        backHistory.append(visit)
        visit = next
        loadPlaylist()
    }

    func browse(_ destination: Shelf, from tile: BrowseTile? = nil) {
        guard destination != shelf || detailID != nil || !query.isEmpty else { return }
        navigate(to: BrowseVisit(shelf: destination), from: tile)
    }

    func openDetail(_ id: Int64) {
        guard id != detailID else { return }
        navigate(to: BrowseVisit(shelf: shelf, query: query, detailID: id), from: .video(id))
    }

    func search(_ term: String) {
        guard query != term, phase == .ready, libraryID != nil, !playing else { return }
        if detailID != nil || query.isEmpty {
            navigate(to: BrowseVisit(shelf: shelf, query: term))
        } else if term.isEmpty, let previous = backHistory.last, previous.shelf == shelf,
                  previous.query.isEmpty, previous.detailID == nil {
            goBack()
        } else {
            // Refining the same search is one visit, regardless of the number of keystrokes.
            visit = BrowseVisit(shelf: shelf, query: term)
        }
    }

    func goBack() {
        guard phase == .ready, !playing, let previous = backHistory.popLast() else { return }
        visit = previous
        loadPlaylist()
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
                    entries = snapshot.entries
                    playlists = snapshot.playlists
                    let entryIDs = Set(snapshot.entries.map(\.id))
                    let playlistIDs = Set(snapshot.playlists.map(\.id))
                    func valid(_ visit: BrowseVisit) -> Bool {
                        if let id = visit.detailID, !entryIDs.contains(id) { return false }
                        if case let .playlist(id) = visit.shelf { return playlistIDs.contains(id) }
                        return true
                    }
                    backHistory.removeAll { !valid($0) }
                    if !valid(visit) { visit = backHistory.popLast() ?? BrowseVisit() }
                    loadPlaylist()
                } catch {
                    guard session == stamp, !Task.isCancelled else { return }
                    loadingLibrary = false
                    message = error.localizedDescription
                }
            }
            snapshotTask = nil
        }
        snapshotTask = task
        return task
    }
    func loadPlaylist() {
        if case let .playlist(id) = shelf {
            do { orderedIDs = try catalog?.playlistEntryIDs(id) ?? [] }
            catch { message = error.localizedDescription }
        } else { orderedIDs = [] }
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
        availabilityTask?.cancel()
        scanCurrentSources()
    }

    func refresh() {
        guard phase == .ready, libraryID != nil else { return }
        availabilityTask?.cancel()
        scanCurrentSources(requested: true)
    }

    private func scanCurrentSources(requested: Bool = false) {
        guard let catalog, let libraryID else { return }
        do { scan(try catalog.sources(libraryID: libraryID), requested: requested) }
        catch { message = error.localizedDescription }
    }

    private func scan(_ list: [CatalogSource], requested: Bool = false) {
        guard let catalog else { return }
        scanTask?.cancel()
        let token = UUID()
        scanToken = token; scanBusy = true; activity = "Scanning folders…"
        scanTask = Task {
            var errors: [String] = []
            for source in list {
                guard !Task.isCancelled else { return }
                let task = Task.detached(priority: .utility) {
                    // Scanner invokes this callback serially on its worker.
                    let throttle = DiscoveryUpdates()
                    try CatalogScanner(catalog: catalog).scan(source: source) { _ in
                        if throttle.shouldRefresh() {
                            Task { @MainActor in if self.scanToken == token { self.reload() } }
                        }
                    }
                }
                do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
                catch { if !Task.isCancelled { errors.append(source.url.lastPathComponent) } }
            }
            guard scanToken == token, !Task.isCancelled else { return }
            await reload()?.value
            guard scanToken == token, !Task.isCancelled else { return }
            scanBusy = false; activity = nil
            if !errors.isEmpty {
                message = "Some folders could not be scanned: " + errors.joined(separator: ", ")
            } else if requested {
                notify("Library refreshed")
            }
            generatePreviews()
            startLookups()
        }
    }

    func previewDirectory(_ entry: CatalogEntry) -> URL {
        cache.directory(for: entry.url, size: entry.fileSize, modificationDate: Date(timeIntervalSince1970: entry.modified))
    }

    private func generatePreviews() {
        guard let catalog else { return }
        previewTask?.cancel()
        let token = UUID()
        previewToken = token
        let pending = entries.filter { $0.availability == .available }
        previewTask = Task(priority: .utility) {
            // Older catalogs may already have preview images but lack movie durations.
            var backfilled = false
            for entry in pending where entry.playCount > 0 && entry.duration == nil {
                guard previewToken == token else { return }
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
            if backfilled { reload() }

            var failuresChanged = false
            for entry in pending {
                guard !Task.isCancelled else { return }
                let directory = previewDirectory(entry)
                do {
                    let generated = try await cache.prepare(media: entry.url, directory: directory)
                    guard previewToken == token else { return }
                    if generated { posterPrepared.send(directory) }
                } catch PreviewError.unsupportedVideo {
                    guard previewToken == token, entry.playbackFailure != PreviewError.unsupportedVideo.localizedDescription else { continue }
                    failuresChanged = true
                    try? catalog.setPlaybackFailure(entryID: entry.id, message: PreviewError.unsupportedVideo.localizedDescription,
                                                    fileSize: entry.fileSize, modified: entry.modified)
                } catch { /* Playback reports decoder errors independently of preview generation. */ }
            }
            if failuresChanged, previewToken == token { reload() }
        }
    }

    func play(_ entry: CatalogEntry, at position: Double) {
        guard phase == .ready, entry.libraryID == libraryID, let catalog else { return }
        playback.open(entry: entry, startAt: position, previewDirectory: previewDirectory(entry), catalog: catalog)
        playing = true
    }

    func hasAlternatives(to current: CatalogEntry) -> Bool {
        phase == .ready && current.libraryID == libraryID && entries.contains { RelatedVideo.canOffer($0, for: current) }
    }

    func playSuggested(_ suggestion: CatalogEntry) {
        guard phase == .ready, suggestion.libraryID == libraryID, let catalog else { return }
        do {
            // Switching back can happen before the browser has reloaded the previous playback session.
            guard let entry = try catalog.entry(suggestion.id), entry.libraryID == libraryID,
                  entry.availability == .available, entry.playbackFailure == nil else {
                reload()
                notify("This video is no longer available to play.", kind: .error)
                return
            }
            play(entry, at: entry.resume)
        } catch { message = error.localizedDescription }
    }

    func endPlayback() { playback.stop(); playing = false; reload() }

    private func startLookups() {
        guard let catalog, let key = try? access.apiKey() else { return }
        worker?.cancel()
        let id = libraryID, stamp = session, client = client
        worker = Task(priority: .utility) {
            await snapshotTask?.value
            guard session == stamp, !Task.isCancelled else { return }
            if let id, entries.contains(where: \.needsLookup) {
                try? await LibraryJobs.detectStudios(libraryID: id, catalog: catalog)
                if session == stamp { reload() }
            }
            while !Task.isCancelled {
                do {
                    while let retryAfter, retryAfter.timeIntervalSinceNow > 0 {
                        try await Task.sleep(for: .seconds(min(86_400, retryAfter.timeIntervalSinceNow)))
                    }
                    if !validated {
                        try await client.validate(key: key)
                        try Task.checkCancellation()
                        validated = true
                    }
                    if let id, entries.contains(where: { $0.needsLookup && $0.availability == .available }) {
                        if directoryUpdated.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true {
                            let directory = try await client.studios(key: key)
                            try Task.checkCancellation()
                            try catalog.saveStudios(directory)
                            directoryUpdated = Date()
                        }
                        try await LibraryJobs.identify(libraryID: id, catalog: catalog, key: key, client: client) {
                            await MainActor.run { if self.session == stamp { _ = self.reload() } }
                        }
                    }
                    guard session == stamp, !Task.isCancelled else { return }
                    networkStatus = nil
                } catch {
                    guard session == stamp, !Task.isCancelled else { return }
                    if case let PRDBError.rateLimited(delay) = error {
                        retryAfter = Date().addingTimeInterval(max(60, delay ?? 60))
                    }
                    handleNetwork(error, key: key)
                    if phase != .ready { return }
                }
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
