import AppKit
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
    var libraryID: Int64?
    var shelf: Shelf? = .studios
    var query = ""
    var detailID: Int64?
    var playing = false
    var scanBusy = false
    var activity: String?
    var networkStatus: String?
    var previewRevision = 0
    var setupReason: String?
    var message: String?
    var failure: String?
    private let lastLibrary = "lastLibraryID"

    init(access: AccessController = AccessController(), client: PRDBClient = PRDBClient(),
         preferences: UserDefaults = .standard,
         directory: URL = URL.applicationSupportDirectory.appending(path: "net.prdb.vieweroo"),
         cache: PreviewCache = PreviewCache(root: URL.cachesDirectory.appending(path: "net.prdb.vieweroo/Previews"))) {
        self.access = access
        self.client = client
        self.preferences = preferences
        self.directory = directory
        self.cache = cache
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
        catalog = database
        libraries = try database.libraries()
        phase = .ready
        let last = (preferences.object(forKey: lastLibrary) as? NSNumber)?.int64Value
        selectLibrary(libraries.first { $0.id == last }?.id ?? libraries.first?.id)
    }

    private func stopWork() {
        session = UUID()
        scanToken = UUID()
        previewToken = UUID()
        worker?.cancel(); availabilityTask?.cancel(); scanTask?.cancel(); previewTask?.cancel()
        playback.stop(); playing = false
        panel?.cancel(nil); panel = nil
        scanBusy = false; activity = nil; networkStatus = nil
    }

    private func conceal(_ gate: Gate) {
        stopWork()
        phase = gate
        message = nil; detailID = nil; libraryID = nil; query = ""; shelf = .studios
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
        libraryID = id; detailID = nil; shelf = .studios; query = ""
        if let id { preferences.set(id, forKey: lastLibrary) }
        reload()
        guard let catalog else { return }
        let stamp = session
        if let id {
            availabilityTask = Task {
                do {
                    try await Task.detached(priority: .utility) { try catalog.checkSources(libraryID: id) }.value
                    guard session == stamp, !Task.isCancelled else { return }
                    reload()
                    let pending = sources.filter { $0.online && $0.scanPending }
                    if !pending.isEmpty { scan(pending) } else { generatePreviews() }
                } catch { if session == stamp, !Task.isCancelled { message = error.localizedDescription } }
            }
        }
        startLookups()
    }

    func reload() {
        guard phase == .ready, let catalog else { return }
        do {
            libraries = try catalog.libraries()
            guard let id = libraryID else { entries = []; sources = []; playlists = []; orderedIDs = []; return }
            entries = try catalog.entries(libraryID: id)
            sources = try catalog.sources(libraryID: id)
            playlists = try catalog.playlists(libraryID: id)
            loadPlaylist()
        } catch { message = error.localizedDescription }
    }
    func loadPlaylist() {
        if case let .playlist(id) = shelf {
            do { orderedIDs = try catalog?.playlistEntries(id).map(\.id) ?? [] }
            catch { message = error.localizedDescription }
        } else { orderedIDs = [] }
    }
    func change(_ operation: (Catalog) throws -> Void) {
        guard phase == .ready, let catalog else { return }
        do { try operation(catalog); reload() }
        catch { message = error.localizedDescription }
    }
    func createLibrary(_ name: String) {
        change { db in selectLibrary(try db.createLibrary(name: name).id) }
    }
    func deleteLibrary() {
        guard let libraryID else { return }
        change { db in
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
        change { db in
            for url in urls { _ = try db.addSource(libraryID: libraryID, url: url) }
        }
        refresh()
    }

    func refresh() {
        guard phase == .ready, libraryID != nil else { return }
        availabilityTask?.cancel()
        scan(sources)
    }

    private func scan(_ list: [CatalogSource]) {
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
            scanBusy = false; activity = nil; reload()
            if !errors.isEmpty { message = "Some folders could not be scanned: " + errors.joined(separator: ", ") }
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
            for entry in pending {
                guard !Task.isCancelled else { return }
                let directory = previewDirectory(entry)
                do {
                    try await cache.prepare(media: entry.url, directory: directory)
                } catch PreviewError.unsupportedVideo {
                    try? catalog.setPlaybackFailure(entryID: entry.id, message: PreviewError.unsupportedVideo.localizedDescription,
                                                    fileSize: entry.fileSize, modified: entry.modified)
                } catch { /* Playback reports decoder errors independently of preview generation. */ }
                guard previewToken == token else { return }
                previewRevision &+= 1
            }
            if previewToken == token { reload() }
        }
    }

    func play(_ entry: CatalogEntry, at position: Double) {
        guard phase == .ready, entry.libraryID == libraryID, let catalog else { return }
        playback.open(entry: entry, startAt: position, previewDirectory: previewDirectory(entry), catalog: catalog)
        playing = true
    }

    func endPlayback() { playback.stop(); playing = false; reload() }

    private func startLookups() {
        guard let catalog, let key = try? access.apiKey() else { return }
        worker?.cancel()
        let id = libraryID, stamp = session, client = client
        worker = Task(priority: .utility) {
            if let id {
                try? await LibraryJobs.detectStudios(libraryID: id, catalog: catalog)
                if session == stamp { reload() }
            }
            while !Task.isCancelled {
                do {
                    if let retryAfter, retryAfter.timeIntervalSinceNow > 0 {
                        try await Task.sleep(for: .seconds(retryAfter.timeIntervalSinceNow))
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
                            await MainActor.run { if self.session == stamp { self.reload() } }
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
