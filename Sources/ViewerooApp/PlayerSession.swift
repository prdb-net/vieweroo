import Combine
import Observation
import ViewerooCore

/// Everything that travels with a video when it changes windows.
@MainActor @Observable
final class PlayerSession {
    let playback = PlayerController()
    private(set) var entryID: Int64?
    private(set) var cinemaQueue: [CatalogEntry] = []
    private(set) var collection: Shelf?
    var cinemaMode: Bool { !cinemaQueue.isEmpty }
    @ObservationIgnored private var recording: AnyCancellable?

    func open(_ entry: CatalogEntry, at position: Double?, model: LibraryModel, catalog: Catalog) {
        entryID = entry.id
        recording = playback.recordedInterval.sink { [weak model] _ in model?.playbackRecorded() }
        playback.open(entry: entry, startAt: position ?? entry.resume,
                      previewDirectory: model.previewDirectory(entry), catalog: catalog)
    }

    func setCinema(_ queue: [CatalogEntry], collection: Shelf) {
        cinemaQueue = queue
        self.collection = collection
    }

    func refresh(entries: [CatalogEntry], playlists: [CatalogPlaylist]) -> Bool {
        guard let entryID else { return true }
        guard cinemaMode else { return entries.contains { $0.id == entryID } }
        let members: Set<Int64>?
        if case let .playlist(id) = collection {
            guard let playlist = playlists.first(where: { $0.id == id }) else { return false }
            members = playlist.memberIDs
        } else {
            members = nil
        }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        cinemaQueue = cinemaQueue.compactMap { entry in
            guard members?.contains(entry.id) != false else { return nil }
            return byID[entry.id]
        }
        return cinemaQueue.contains { $0.id == entryID }
    }

    func stop() {
        playback.stop()
        recording = nil
        entryID = nil
        cinemaQueue = []
        collection = nil
    }
}
