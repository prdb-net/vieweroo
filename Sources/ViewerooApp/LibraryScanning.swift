import AppKit
import Foundation
import ViewerooCore

/// Source folders, scans, video-info probes and preview generation of the open library.
/// The model keeps the state. These methods run the work in its `LibraryWork` slots.
extension LibraryModel {
    func pickSource() {
        guard phase == .ready, libraryID != nil, let window = NSApp.keyWindow, panel == nil else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.prompt = "Add Folder"; picker.allowsMultipleSelection = true
        panel = picker
        let stamp = work
        picker.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.work === stamp else { return }
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
        work[.availability]?.cancel()
        unreadableVideoInfo.removeAll()
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

    func scan(_ list: [CatalogSource], requested: Bool = false) {
        guard let catalog else { return }
        refreshRequested = refreshRequested || requested
        var queued = Set(scanQueue.map(\.id))
        for source in list where (requested || source.id != scanningSourceID) && queued.insert(source.id).inserted {
            scanQueue.append(source)
        }
        guard !scanBusy else { return }
        let token = UUID()
        scanToken = token; scanBusy = true
        work[.scan] = Task {
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

    private func readVideoInfo(in entries: [CatalogEntry], catalog: Catalog) {
        work[.videoInfo]?.cancel()
        work[.videoInfo] = Task(priority: .utility) {
            let updates = DiscoveryUpdates()
            var pendingReload = false
            // Older catalogs know the video track of an entry but not yet its duration.
            for entry in entries where entry.videoInfo == nil || entry.duration == nil {
                guard !Task.isCancelled else { return }
                let identity = "\(entry.id):\(entry.fileSize):\(entry.modified)"
                guard !unreadableVideoInfo.contains(identity) else { continue }
                do {
                    guard let probe = try await VideoInfo.probe(entry.url) else {
                        unreadableVideoInfo.insert(identity)
                        continue
                    }
                    try Task.checkCancellation()
                    try await catalog.storeVideoInfo(probe.info, duration: probe.duration, for: entry)
                    guard !Task.isCancelled else { return }
                    if probe.duration == nil { unreadableVideoInfo.insert(identity) }
                    pendingReload = true
                    if entry.id == detailID || updates.shouldRefresh() {
                        reload()
                        pendingReload = false
                    }
                } catch {
                    // Probe a failing file again after it changes, on refresh or on the next launch.
                    if !Task.isCancelled { unreadableVideoInfo.insert(identity) }
                }
            }
            if pendingReload && !Task.isCancelled { reload() }
        }
    }

    func generatePreviews(only selection: [CatalogEntry]? = nil) {
        guard let catalog else { return }
        work[.previews]?.cancel()
        let token = UUID()
        previewToken = token
        let pending = (selection ?? entries).filter { $0.availability == .available }
        // A rename keeps the cached video info. Leave a running probe of the library alone.
        if selection == nil { readVideoInfo(in: pending, catalog: catalog) }
        previews = PreviewProgress(phase: .checking)
        work[.previews] = Task(priority: .utility) {
            guard let missing = try? await PreviewProgress.missing(in: pending, cache: cache),
                  previewToken == token else { return }
            previews = PreviewProgress(phase: .preparing, total: pending.count, remaining: missing)
            var failuresChanged = false
            let finished = await withTaskGroup(of: (CatalogEntry, URL, (any Error)?).self) { group in
                var queue = missing.makeIterator()
                var running = 0
                while true {
                    while running < PreviewProgress.workers, let entry = queue.next() {
                        let directory = previewDirectory(entry)
                        running += 1
                        group.addTask { [cache] in
                            do {
                                _ = try await cache.prepare(media: entry.url, directory: directory)
                                return (entry, directory, nil)
                            } catch { return (entry, directory, error) }
                        }
                    }
                    guard let (entry, directory, failure) = await group.next() else { return true }
                    running -= 1
                    guard previewToken == token, !Task.isCancelled else {
                        group.cancelAll()
                        return false
                    }
                    if let failure {
                        previews.failures.append(.init(entry: entry, reason: failure.localizedDescription))
                        if case PreviewError.unsupportedVideo = failure, entry.playbackFailure != failure.localizedDescription {
                            failuresChanged = true
                            let message = failure.localizedDescription
                            // The catalog write must not hold up the main thread behind a scan.
                            _ = try? await Task.detached(priority: .utility) {
                                try catalog.setPlaybackFailure(entryID: entry.id, message: message,
                                                               fileSize: entry.fileSize, modified: entry.modified)
                            }.value
                            guard previewToken == token, !Task.isCancelled else {
                                group.cancelAll()
                                return false
                            }
                        }
                    } else {
                        posterPrepared.send(directory)
                        if automaticCovers?.candidates.values.contains(where: { $0.contains(where: { $0.id == entry.id }) }) == true {
                            automaticCovers = nil
                            reload()
                        }
                    }
                    previews.finish(entry)
                }
            }
            guard finished, previewToken == token else { return }
            previews.phase = .idle
            previews.remaining = []
            if failuresChanged { reload() }
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
