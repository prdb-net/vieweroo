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

extension Catalog {
    public func beginSession(entryID: Int64) throws -> Int64 {
        try database.write { db in
            try db.execute(sql: "INSERT INTO session(entryID) VALUES (?)", arguments: [entryID])
            return db.lastInsertedRowID
        }
    }

    public func recordInterval(sessionID: Int64, start: Double, end: Double) throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { throw CatalogError.invalidValue }
        try database.write { db in
            try db.execute(sql: "INSERT INTO interval(sessionID,start,end) VALUES (?,?,?)", arguments: [sessionID, start, end])
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
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session WHERE entryID = ?", arguments: [entryID]) ?? 0
            let intervals = try Row.fetchCursor(db, sql: """
                SELECT i.start,i.end FROM interval i JOIN session s ON s.id = i.sessionID WHERE s.entryID = ?
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
