import Foundation

/// Tracks one open player item. A session begins when the media clock first
/// advances during playback. All inputs are timeline seconds at normal speed.
public final class PlaybackHistory {
    static let minimumWatchTime = 10.0

    private let begin: () throws -> Int64
    private let append: (Int64, Double, Double) throws -> Void
    private let resume: (Double) throws -> Void
    private var session: Int64?
    private var intervalStart: Double?
    private var lastPosition: Double?
    private var lastClock = 0.0
    private var wasPlaying = false
    private var recordedWatchTime = 0.0
    private var lastSavedPosition: Double?

    public init(begin: @escaping () throws -> Int64, append: @escaping (Int64, Double, Double) throws -> Void,
                resume: @escaping (Double) throws -> Void) {
        self.begin = begin
        self.append = append
        self.resume = resume
    }

    public func sample(position: Double, playing: Bool, clock: Double) throws {
        guard position.isFinite, position >= 0, clock.isFinite else { return }
        if let previous = lastPosition, wasPlaying {
            let elapsed = max(0, clock - lastClock)
            let advance = position - previous
            if advance >= 0, advance <= elapsed + 0.5 {
                if advance > 0 {
                    if session == nil { session = try begin() }
                    if intervalStart == nil { intervalStart = previous }
                }
            } else {
                // A remote seek can move the player clock before AVFoundation sends its jump notification.
                try finishInterval(at: previous)
            }
        }
        lastPosition = position
        lastClock = clock
        wasPlaying = playing
        if !playing || intervalStart.map({ position - $0 >= 10 }) == true {
            try finishInterval(at: position)
            if session != nil { try savePosition(position) }
        }
    }

    public func jumped(to position: Double, playing: Bool, clock: Double) throws {
        guard position.isFinite, position >= 0 else { return }
        if let previous = lastPosition { try finishInterval(at: previous) }
        lastPosition = position
        lastClock = clock
        wasPlaying = playing
        if session != nil { try savePosition(position) }
    }

    private func finishInterval(at end: Double) throws {
        guard let start = intervalStart else { return }
        intervalStart = nil
        guard let current = session, end > start else { return }
        do {
            try append(current, start, end)
        } catch CatalogError.sessionRemoved {
            // Watch History was cleared during playback. Continue in a new session
            // that must again reach the minimum watch time before it saves a position.
            recordedWatchTime = 0
            lastSavedPosition = nil
            let replacement = try begin()
            session = replacement
            try append(replacement, start, end)
        }
        recordedWatchTime += end - start
    }

    private func savePosition(_ value: Double) throws {
        guard recordedWatchTime >= Self.minimumWatchTime, value != lastSavedPosition else { return }
        try resume(value)
        lastSavedPosition = value
    }
}
