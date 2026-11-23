import AVFoundation
import Combine
import Foundation
import ViewerooCore

@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var title = ""
    @Published private(set) var volume: Float = 1
    @Published private(set) var muted = false
    @Published private(set) var waiting = false
    @Published private(set) var ended = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var videoAspectRatio: CGFloat?
    @Published private(set) var playing = false
    @Published private(set) var loopStart: Double?
    @Published private(set) var loopEnd: Double?
    @Published private(set) var error: String?
    @Published private(set) var previewDirectory: URL?
    private var history: PlaybackHistory?
    private var historyWriter: PlaybackHistoryWriter?
    private var reportUnsupported: ((String) throws -> Void)?
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var periodicObserver: Any?
    private var generation = UUID()
    private var sourceURL: URL?
    private var mediaServer: AirPlayMediaServer?
    private var routeObservation: NSKeyValueObservation?
    private var itemStartAt = 0.0
    private var handoffPosition: Double { ready ? position : itemStartAt }
    private var airPlayFailed = false
    private let makeMediaServer: (URL) throws -> AirPlayMediaServer
    private var seekID: UUID?
    /// Set from the loop's end notification until the seek back to its start completes.
    private var restartingLoop = false
    @Published private(set) var wantsPlayback = false
    private(set) var ready = false
    let recordedInterval = PassthroughSubject<Int64, Never>()
    private var audibleVolume: Float = 1

    init(makeMediaServer: @escaping (URL) throws -> AirPlayMediaServer = { try AirPlayMediaServer(movie: $0) }) {
        self.makeMediaServer = makeMediaServer
        player.actionAtItemEnd = .pause
    }

    func open(entry: CatalogEntry, startAt: Double, previewDirectory: URL, catalog: Catalog) {
        let id = entry.id
        let writer = PlaybackHistoryWriter(catalog: catalog, entryID: id)
        // Completions arrive on the writer queue. Ignore those of an item that was replaced.
        let finished: @Sendable (Error?, Bool) -> Void = { [weak self] error, interval in
            Task { @MainActor in
                guard let self, self.historyWriter === writer else { return }
                if let error { self.error = "Viewing history could not be saved. \(error.localizedDescription)" }
                else if interval { self.recordedInterval.send(id) }
            }
        }
        let history = PlaybackHistory(begin: { [weak self] in
            if entry.duration == nil, let duration = self?.duration, duration > 0 {
                try catalog.setDuration(duration, for: entry)
            }
            return try catalog.beginSession(entryID: id)
        }, append: { session, start, end in
            writer.append(session: session, start: start, end: end) { finished($0, true) }
        }, resume: { seconds in
            writer.resume(at: seconds) { finished($0, false) }
        })
        open(url: entry.url, title: entry.title, startAt: startAt, previewDirectory: previewDirectory, history: history)
        historyWriter = writer
        reportUnsupported = { try catalog.setPlaybackFailure(entryID: id, message: $0, fileSize: entry.fileSize, modified: entry.modified) }
    }

    func open(url: URL, title: String, startAt: Double, previewDirectory: URL, history: PlaybackHistory) {
        stop()
        self.title = title
        self.history = history
        self.previewDirectory = previewDirectory
        wantsPlayback = true
        sourceURL = url
        player.allowsExternalPlayback = true
        routeObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, !self.player.isExternalPlaybackActive else { return }
                self.externalPlaybackDidEnd()
            }
        }
        installItem(url: url, startAt: startAt)
    }

    func sourceRenamed(from oldURL: URL, to entry: CatalogEntry, previewDirectory: URL) {
        guard sourceURL == oldURL else { return }
        sourceURL = entry.url
        title = entry.title
        self.previewDirectory = previewDirectory
        // The active HTTP stream holds its own open file descriptor.
        if mediaServer == nil {
            sample(playing: false)
            installItem(url: entry.url, startAt: handoffPosition)
        }
    }

    func externalPlaybackDidEnd() {
        guard mediaServer != nil || airPlayFailed, let sourceURL else { return }
        sample(playing: false)
        closeMediaServer()
        airPlayFailed = false
        installItem(url: sourceURL, startAt: handoffPosition)
    }

    private func installItem(url: URL, startAt: Double) {
        detachItemObservers()
        error = nil
        waiting = true
        itemStartAt = startAt
        let token = generation
        let item = AVPlayerItem(url: url)
        if let loopEnd { item.forwardPlaybackEndTime = CMTime(seconds: loopEnd, preferredTimescale: 60_000) }
        player.replaceCurrentItem(with: item)

        observations.append(item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                let size = item.presentationSize
                guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return }
                self.videoAspectRatio = size.width / size.height
            }
        })
        observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if item.status == .failed { self.playbackFailed(item.error) }
                if item.status == .readyToPlay, !self.ready {
                    self.ready = true
                    self.waiting = false
                    self.duration = max(0, item.duration.seconds.isFinite ? item.duration.seconds : 0)
                    let initial = startAt.isFinite && startAt < self.duration - 0.05 ? startAt : 0
                    self.seek(to: initial, resume: self.wantsPlayback)
                }
            }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if self.ready { self.waiting = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate }
                self.sample()
            }
        })
        let rateChangeReason = AVPlayer.rateDidChangeReasonKey
        notifications.append(NotificationCenter.default.addObserver(forName: AVPlayer.rateDidChangeNotification,
                                                                   object: player, queue: .main) { [weak self] event in
            let hasReason = event.userInfo?[rateChangeReason] != nil
            MainActor.assumeIsolated {
                guard let self, self.generation == token, self.ready, item.status == .readyToPlay else { return }
                let requested = self.player.rate != 0
                // AVPlayer sets its rate to zero without a reason at a loop boundary. The end-time
                // notification decides whether to play the next pass. Setting the end time at the
                // current position also stops the item while the seek back to the loop start runs,
                // and the stop can arrive after that seek has moved the clock.
                if !requested, !hasReason, let end = self.loopEnd,
                   self.restartingLoop || self.seekID != nil || self.player.currentTime().seconds >= end - 0.05 { return }
                if self.wantsPlayback != requested { self.wantsPlayback = requested }
            }
        })
        periodicObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 5), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.sample()
            }
        }
        listen(for: .AVPlayerItemDidPlayToEndTime, item: item) { controller, _ in
            // A seek into the loop is already on its way and resumes the next pass itself.
            if controller.seekID != nil, controller.loopEnd != nil { return }
            controller.sample(playing: false)
            if let start = controller.loopStart, controller.loopEnd != nil, controller.wantsPlayback {
                controller.seek(to: start, resume: true)
                controller.restartingLoop = true
            } else {
                controller.wantsPlayback = false
                controller.ended = true
            }
        }
        listen(for: .AVPlayerItemTimeJumped, item: item) { controller, _ in
            guard controller.seekID == nil else { return }
            controller.didJump()
        }
        listen(for: .AVPlayerItemFailedToPlayToEndTime, item: item) { controller, error in
            controller.playbackFailed(error ?? item.error)
        }
    }

    private func listen(for name: Notification.Name, item: AVPlayerItem,
                        action: @escaping @MainActor @Sendable (PlayerController, Error?) -> Void) {
        let token = generation
        notifications.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] event in
            let failure = event.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                action(self, failure)
            }
        })
    }

    private func playbackFailed(_ underlying: Error?) {
        if mediaServer != nil || airPlayFailed {
            failAirPlay(underlying)
            return
        }
        if player.isExternalPlaybackActive || Self.isAirPlayAssetError(underlying) {
            startAirPlayStream()
            return
        }
        waiting = false
        wantsPlayback = false
        sample(playing: false)
        player.pause()
        let explanation = underlying?.localizedDescription ?? "AVFoundation could not decode this video."
        error = explanation
        if let underlying, PreviewError.isUnsupported(underlying) {
            do { try reportUnsupported?(explanation) }
            catch { self.error = explanation + " The failure could not be saved to the catalog." }
        }
    }

    private static func isAirPlayAssetError(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        if error.domain == AVFoundationErrorDomain,
           error.code == AVError.externalPlaybackNotSupportedForAsset.rawValue { return true }
        // Core Media's VideoFormatCannotBeStreamedToAirPlayDevice can be wrapped in "Cannot Play".
        if ["NSOSStatusErrorDomain", "CoreMediaErrorDomain"].contains(error.domain), error.code == -17226 { return true }
        return isAirPlayAssetError(error.userInfo[NSUnderlyingErrorKey] as? Error)
    }

    private func startAirPlayStream() {
        guard let sourceURL, sourceURL.isFileURL else { failAirPlay(nil); return }
        sample(playing: false)
        itemStartAt = handoffPosition
        detachItemObservers()
        error = nil
        airPlayFailed = false
        waiting = true
        do {
            let server = try makeMediaServer(sourceURL)
            mediaServer = server
            server.start { [weak self, weak server] result in
                Task { @MainActor in
                    guard let self, let server, self.mediaServer === server else { return }
                    switch result {
                    case .success(let url): self.installItem(url: url, startAt: self.handoffPosition)
                    case .failure(let error): self.failAirPlay(error)
                    }
                }
            }
        } catch { failAirPlay(error) }
    }

    private func failAirPlay(_ underlying: Error?) {
        sample(playing: false)
        itemStartAt = handoffPosition
        detachItemObservers()
        closeMediaServer()
        player.pause()
        waiting = false
        wantsPlayback = false
        airPlayFailed = true
        error = "AirPlay could not stream this video. Check that the receiver can reach your Mac on the local network and supports this video format."
        if let underlying { error? += " " + underlying.localizedDescription }
    }

    private func closeMediaServer() {
        mediaServer?.stop()
        mediaServer = nil
    }

    private func sample(playing override: Bool? = nil) {
        guard ready, seekID == nil else { return }
        let time = player.currentTime().seconds
        guard time.isFinite else { return }
        position = max(0, time)
        playing = override ?? (player.timeControlStatus == .playing)
        do { try history?.sample(position: position, playing: playing, clock: ProcessInfo.processInfo.systemUptime) }
        catch { self.error = "Viewing history could not be saved. \(error.localizedDescription)" }
    }

    private func didJump(to target: Double? = nil, playing: Bool? = nil) {
        let time = target ?? player.currentTime().seconds
        guard ready, time.isFinite else { return }
        position = max(0, time)
        do {
            try history?.jumped(to: position, playing: playing ?? (player.timeControlStatus == .playing),
                                clock: ProcessInfo.processInfo.systemUptime)
        } catch { self.error = "The playback position could not be saved. \(error.localizedDescription)" }
    }

    func setVolume(_ level: Float) {
        guard level.isFinite else { return }
        volume = max(0, min(1, level))
        if volume > 0 { audibleVolume = volume }
        player.volume = volume
        muted = volume == 0
        player.isMuted = muted
    }

    var isAudible: Bool { wantsPlayback && !muted && volume > 0 }

    func toggleMute() {
        if muted && volume == 0 { setVolume(audibleVolume); return }
        muted.toggle()
        player.isMuted = muted
    }

    func togglePlayback() {
        if wantsPlayback {
            sample(playing: false)
            wantsPlayback = false
            player.pause()
        } else {
            wantsPlayback = true
            if airPlayFailed, let sourceURL {
                if player.isExternalPlaybackActive { startAirPlayStream() }
                else {
                    airPlayFailed = false
                    installItem(url: sourceURL, startAt: handoffPosition)
                }
            } else if ready, duration > 0, ended || position >= (loopEnd ?? duration) - 0.05 {
                seek(to: loopStart ?? 0, resume: true)
            } else if ready { player.play() }
        }
    }

    func seek(to seconds: Double, resume: Bool? = nil) {
        guard ready, seconds.isFinite else { return }
        sample(playing: false)
        ended = false
        let target = max(0, min(seconds, duration))
        if let loopStart, let loopEnd, target < loopStart || target >= loopEnd { clearLoop() }
        wantsPlayback = resume ?? wantsPlayback
        // AVPlayer preserves its desired rate across seeks. An artificial pause
        // here would be indistinguishable from a pause requested on the receiver.
        if !wantsPlayback, player.rate != 0 { player.pause() }
        let ticket = UUID()
        seekID = ticket
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 60_000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.seekID == ticket else { return }
                self.seekID = nil
                self.restartingLoop = false
                self.didJump()
                if finished, self.wantsPlayback { self.player.play() }
            }
        }
    }

    func markLoopStart() {
        clearLoop()
        loopStart = position
    }

    func markLoopEnd() {
        guard let loopStart, position > loopStart + 0.1 else { return }
        loopEnd = position
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: position, preferredTimescale: 60_000)
        seek(to: loopStart, resume: true)
    }

    func clearLoop() {
        loopStart = nil
        loopEnd = nil
        player.currentItem?.forwardPlaybackEndTime = .invalid
    }

    private func detachItemObservers() {
        ready = false
        restartingLoop = false
        playing = false
        generation = UUID()
        seekID = nil
        observations.removeAll()
        for token in notifications { NotificationCenter.default.removeObserver(token) }
        notifications.removeAll()
        if let periodicObserver { player.removeTimeObserver(periodicObserver) }
        periodicObserver = nil
    }

    func stop() {
        if ready, seekID != nil {
            // The seek target is already the visible position. Save it even though
            // AVFoundation will not report the completed jump for this item.
            seekID = nil
            didJump(to: position, playing: false)
        } else {
            sample(playing: false)
        }
        routeObservation = nil
        detachItemObservers()
        closeMediaServer()
        sourceURL = nil
        airPlayFailed = false
        wantsPlayback = false
        player.pause()
        player.allowsExternalPlayback = false
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
        clearLoop()
        title = ""
        ended = false
        waiting = false
        error = nil
        history = nil
        // Stopping also covers quitting and locking. Keep the final position.
        historyWriter?.flush()
        historyWriter = nil
        reportUnsupported = nil
        position = 0
        duration = 0
        videoAspectRatio = nil
        previewDirectory = nil
    }
}
