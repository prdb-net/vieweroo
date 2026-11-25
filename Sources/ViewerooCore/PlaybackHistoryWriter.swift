import Foundation
import os

/// Writes one player item's intervals and resume positions on a serial queue,
/// so playback never waits for the catalog on the main thread.
public final class PlaybackHistoryWriter: Sendable {
    private let queue = DispatchQueue(label: "net.prdb.vieweroo.history", qos: .utility)
    private let catalog: Catalog
    private let entryID: Int64
    private struct Sessions {
        // Catalog sessions by the session the player knows: a local token from `begin`, or
        // a catalog session that was removed from Watch History and continues under a new ID.
        var current: [Int64: Int64] = [:]
        var lastToken: Int64 = 0
    }
    private let sessions = OSAllocatedUnfairLock(initialState: Sessions())

    public init(catalog: Catalog, entryID: Int64) {
        self.catalog = catalog
        self.entryID = entryID
    }

    /// Open a session without waiting for the catalog. Returns a local token for `append`.
    /// The session row, and a duration the entry still lacks, are written on the queue.
    public func begin(duration: Double? = nil, of entry: CatalogEntry? = nil) -> Int64 {
        let token = sessions.withLock { state in
            state.lastToken -= 1
            return state.lastToken
        }
        queue.async { [self] in
            if let duration, let entry { try? catalog.setDuration(duration, for: entry) }
            // A failed insert is repeated by the first interval of this token.
            if let session = try? catalog.beginSession(entryID: entryID) {
                sessions.withLock { $0.current[token] = session }
            }
        }
        return token
    }

    public func append(session: Int64, start: Double, end: Double,
                       completion: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in
            do {
                var current = sessions.withLock { $0.current[session] }
                if current == nil, session < 0 {
                    // A local token whose session could not be stored yet.
                    let stored = try catalog.beginSession(entryID: entryID)
                    sessions.withLock { $0.current[session] = stored }
                    current = stored
                }
                do {
                    try catalog.recordInterval(sessionID: current ?? session, start: start, end: end)
                } catch CatalogError.sessionRemoved {
                    let replacement = try catalog.beginSession(entryID: entryID)
                    sessions.withLock { $0.current[session] = replacement }
                    try catalog.recordInterval(sessionID: replacement, start: start, end: end)
                }
                completion(nil)
            } catch { completion(error) }
        }
    }

    public func resume(at seconds: Double, completion: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in
            do {
                try catalog.setResume(entryID: entryID, seconds: seconds)
                completion(nil)
            } catch { completion(error) }
        }
    }

    /// Wait for every queued write, for example before the app quits.
    public func flush() { queue.sync {} }
}
