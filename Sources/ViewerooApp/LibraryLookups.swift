import Foundation
import ViewerooCore

/// PRDB access for the open library: key validation, the studio directory, studio
/// recognition and title lookups, with the state the activity view reports.
extension LibraryModel {
    func replacePRDBKey(_ input: String) async throws {
        guard phase == .ready else { throw CancellationError() }
        let stamp = work
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if try access.apiKey() == key {
            do { try await client.validate(key: key) }
            catch {
                guard work === stamp, !Task.isCancelled else { throw CancellationError() }
                handleNetwork(error, key: key)
                throw error
            }
        } else {
            try await access.validateAndStore(key: key, client: client, while: { self.work === stamp })
        }
        try Task.checkCancellation()
        guard phase == .ready, work === stamp else { throw CancellationError() }
        validated = true
        subscriptionRequired = false
        lookupStatus = nil
        startLookups()
        notify("PRDB key verified")
    }

    /// Videos whose finished lookup found no title and that the user has not decided on.
    var unmatchedCount: Int {
        entries.lazy.filter { $0.match == nil && !$0.confirmed && !$0.needsLookup && $0.availability == .available }.count
    }

    func retryUnmatched() {
        guard phase == .ready, let libraryID else { return }
        var queued = 0
        guard change(nil, { queued = try $0.retryUnmatched(libraryID: libraryID) }) else { return }
        notify(queued == 1 ? "Checking 1 video again" : "Checking \(queued) videos again")
        if queued > 0 { startLookups() }
    }

    func retrySubscription() {
        guard phase == .ready, subscriptionRequired else { return }
        validated = false
        subscriptionRequired = false
        lookupStatus = nil
        startLookups()
    }

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
                work[.lookups]?.cancel()
            case PRDBError.rateLimited:
                lookupStatus = "PRDB’s request limit was reached. Pending lookups will retry."
            default:
                lookupStatus = "PRDB unavailable. Pending lookups will retry."
            }
        }
    }

    /// Folder and file name clues depend on the studio names of the library. Look again at
    /// videos without a studio after a studio was created, renamed or deleted.
    func recognizeStudios() {
        guard phase == .ready, let catalog, let id = libraryID else { return }
        let stamp = work
        work[.studioRecognition]?.cancel()
        work[.studioRecognition] = Task(priority: .utility) {
            // Videos that still await their lookup are recognized here as well. Their lookup
            // may be far off while PRDB is unreachable or a first import runs.
            var changed = (try? await LibraryJobs.detectStudios(libraryID: id, catalog: catalog)) ?? 0
            guard work === stamp, !Task.isCancelled else { return }
            changed += (try? await LibraryJobs.detectStudios(libraryID: id, catalog: catalog, scope: .unassigned)) ?? 0
            guard work === stamp, !Task.isCancelled, changed > 0 else { return }
            reload()
        }
    }

    func startLookups() {
        guard let catalog, let key = try? access.apiKey() else { return }
        work[.lookups]?.cancel()
        lookupActivity = nil
        let id = libraryID, stamp = work, client = client
        work[.lookups] = Task(priority: .utility) {
            await work[.snapshot]?.value
            guard work === stamp, !Task.isCancelled else { return }
            if let id {
                var recognized = 0
                if entries.contains(where: \.needsLookup) {
                    lookupActivity = "Recognizing studios…"
                    recognized = (try? await LibraryJobs.detectStudios(libraryID: id, catalog: catalog)) ?? 0
                    guard work === stamp, !Task.isCancelled else { return }
                }
                // Also covers studios that were created before this version recognized them.
                recognized += (try? await LibraryJobs.detectStudios(libraryID: id, catalog: catalog, scope: .unassigned)) ?? 0
                guard work === stamp, !Task.isCancelled else { return }
                lookupActivity = nil
                if recognized > 0 { reload() }
            }
            while !Task.isCancelled && !subscriptionRequired {
                do {
                    if !validated {
                        lookupActivity = "Checking access…"
                        try await client.validate(key: key)
                        try Task.checkCancellation()
                        validated = true
                    }
                    // The catalog remembers the refresh, so a relaunch does not download the directory again.
                    let refreshed = try? catalog.studioDirectoryRefreshed()
                    if let id, refreshed.map({ abs(Date().timeIntervalSince($0)) > 86_400 }) ?? true {
                        lookupActivity = "Updating studio directory…"
                        let directory = try await client.studios(key: key)
                        try Task.checkCancellation()
                        // Thousands of sites in one transaction. Keep the main thread free.
                        try await Task.detached(priority: .utility) { try catalog.saveStudios(directory) }.value
                        try await LibraryJobs.detectStudios(libraryID: id, catalog: catalog)
                        try Task.checkCancellation()
                        reload()
                    }
                    if let id, entries.contains(where: { $0.needsLookup && $0.availability == .available }) {
                        lookupActivity = "Matching videos…"
                        try await LibraryJobs.identify(libraryID: id, catalog: catalog, key: key, client: client,
                                                      failures: lookupFailures) {
                            await MainActor.run { if self.work === stamp { _ = self.reload() } }
                        }
                    }
                    guard work === stamp, !Task.isCancelled else { return }
                    lookupStatus = nil
                } catch {
                    guard work === stamp, !Task.isCancelled else { return }
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
