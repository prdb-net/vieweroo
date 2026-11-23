import Foundation
import os

/// Writes one player item's intervals and resume positions on a serial queue,
/// so playback never waits for the catalog on the main thread.
public final class PlaybackHistoryWriter: Sendable {
    private let queue = DispatchQueue(label: "net.prdb.vieweroo.history", qos: .utility)
    private let catalog: Catalog
    private let entryID: Int64
    // Sessions removed from Watch History during playback continue under a new ID.
    private let replacements = OSAllocatedUnfairLock(initialState: [Int64: Int64]())

    public init(catalog: Catalog, entryID: Int64) {
        self.catalog = catalog
        self.entryID = entryID
    }

    public func append(session: Int64, start: Double, end: Double,
                       completion: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in
            do {
                let current = replacements.withLock { $0[session] } ?? session
                do {
                    try catalog.recordInterval(sessionID: current, start: start, end: end)
                } catch CatalogError.sessionRemoved {
                    let replacement = try catalog.beginSession(entryID: entryID)
                    replacements.withLock { $0[session] = replacement }
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
