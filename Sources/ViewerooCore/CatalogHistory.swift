import GRDB

public struct WatchedSegment: Hashable, Sendable {
    public let start: Double
    public let end: Double
    public let passes: Int
}

public struct PlaybackStats: Equatable, Sendable {
    public let playCount: Int
    public let watchTime: Double
    /// In descending order of pass count, with earlier sections first on ties.
    public let segments: [WatchedSegment]
}

/// Kept in memory for the lifetime of a bulk edit's Undo notice.
struct RemovedPlaybackSession: Sendable {
    let id: Int64
    let started: String
    var intervals: [ClosedRange<Double>] = []
}

extension Catalog {
    static let visibleSessions = """
        (SELECT s.id, s.entryID,
            (SELECT TOTAL(i.end - i.start) FROM interval i WHERE i.sessionID = s.id) AS watchTime
         FROM session s WHERE watchTime >= \(PlaybackHistory.minimumWatchTime))
        """

    // In start order, only the portion beyond all previous ends adds new coverage.
    // Total watch time includes every pass, even through a fully covered interval.
    static let weightedPlaysQuery = """
        (SELECT ROUND(TOTAL(
            COALESCE(0.8 * MIN(1.0, coverage / e.duration), 0.0)
            + 0.2 * MIN(1.0, watched / MIN(COALESCE(e.duration, 1800.0), 1800.0))
        ), 12) FROM (
            SELECT sessionID, TOTAL(end - start) AS watched,
                TOTAL(MAX(0.0, MIN(end, COALESCE(e.duration, end)) - MAX(start, COALESCE(previousEnd, 0.0)))) AS coverage
            FROM (
                SELECT i.*, MAX(i.end) OVER (
                    PARTITION BY s.id ORDER BY i.start, i.end, i.rowid
                    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                ) AS previousEnd
                FROM session s JOIN interval i ON i.sessionID = s.id WHERE s.entryID = e.id
            )
            GROUP BY sessionID HAVING watched >= \(PlaybackHistory.minimumWatchTime)
        ))
        """

    static func removeHistory(_ db: Database, entryID: Int64) throws -> [RemovedPlaybackSession] {
        let rows = try Row.fetchCursor(db, sql: """
            SELECT s.id, s.started, i.start, i.end
            FROM session s LEFT JOIN interval i ON i.sessionID = s.id
            WHERE s.entryID = ? ORDER BY s.id, i.rowid
            """, arguments: [entryID])
        var sessions: [RemovedPlaybackSession] = []
        while let row = try rows.next() {
            let id: Int64 = row["id"]
            if sessions.last?.id != id {
                sessions.append(RemovedPlaybackSession(id: id, started: row["started"]))
            }
            if let start: Double = row["start"], let end: Double = row["end"] {
                sessions[sessions.count - 1].intervals.append(start...end)
            }
        }
        try db.execute(sql: "DELETE FROM session WHERE entryID = ?", arguments: [entryID])
        return sessions
    }

    static func restoreHistory(_ db: Database, sessions: [RemovedPlaybackSession], entryID: Int64, libraryID: Int64) throws {
        for session in sessions {
            try db.execute(sql: """
                INSERT INTO session(id, started, entryID)
                SELECT ?, ?, id FROM entry WHERE id = ? AND libraryID = ?
                ON CONFLICT(id) DO NOTHING
                """, arguments: [session.id, session.started, entryID, libraryID])
            guard db.changesCount == 1 else { continue }
            for interval in session.intervals {
                try db.execute(sql: "INSERT INTO interval(sessionID, start, end) VALUES (?, ?, ?)",
                               arguments: [session.id, interval.lowerBound, interval.upperBound])
            }
        }
    }

    public func beginSession(entryID: Int64) throws -> Int64 {
        try database.write { db in
            try db.execute(sql: "INSERT INTO session(entryID) VALUES (?)", arguments: [entryID])
            return db.lastInsertedRowID
        }
    }

    public func recordInterval(sessionID: Int64, start: Double, end: Double) throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { throw CatalogError.invalidValue }
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO interval(sessionID,start,end) SELECT id, ?, ? FROM session WHERE id = ?
                """, arguments: [start, end, sessionID])
            guard db.changesCount == 1 else { throw CatalogError.sessionRemoved }
        }
    }

    public func setResume(entryID: Int64, seconds: Double) throws {
        guard seconds.isFinite, seconds >= 0 else { throw CatalogError.invalidValue }
        try database.write { db in
            try db.execute(sql: "UPDATE entry SET resume = ? WHERE id = ?", arguments: [seconds, entryID])
        }
    }

    public func playbackStats(entryID: Int64) throws -> PlaybackStats {
        try database.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(Self.visibleSessions) WHERE entryID = ?", arguments: [entryID]) ?? 0
            let intervals = try Row.fetchCursor(db, sql: """
                SELECT i.start,i.end FROM interval i JOIN \(Self.visibleSessions) s ON s.id = i.sessionID WHERE s.entryID = ?
                """, arguments: [entryID])
            var edges = [Double: Int]()
            var watchTime = 0.0
            while let row = try intervals.next() {
                let start: Double = row["start"]
                let end: Double = row["end"]
                watchTime += end - start
                edges[start, default: 0] += 1
                edges[end, default: 0] -= 1
            }

            // A pass begins or ends only where the number of overlapping intervals changes.
            var segments = [WatchedSegment]()
            var passes = 0
            var previous = 0.0
            for (time, change) in edges.filter({ $0.value != 0 }).sorted(by: { $0.key < $1.key }) {
                if passes > 0 {
                    segments.append(WatchedSegment(start: previous, end: time, passes: passes))
                }
                passes += change
                previous = time
            }
            segments.sort { $0.passes == $1.passes ? $0.start < $1.start : $0.passes > $1.passes }
            return PlaybackStats(playCount: count, watchTime: watchTime, segments: segments)
        }
    }
}
