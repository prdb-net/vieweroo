import AVKit
import Combine
import SwiftUI
import ViewerooCore

struct PlayerScreen: View {
    let model: LibraryModel
    let session: PlayerSession
    @ObservedObject var window: PlayerWindow
    @State private var lastActivity = Date.now
    @State private var idle = false
    @State private var playing = false
    @State private var adjustingSlider = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var detached: Bool { session === model.secondPlayer }

    private func move(to screen: NSScreen) {
        if !detached { window.leavePlayer() }
        model.movePlayer(session, to: screen)
    }

    private func leave() {
        if detached { model.closeSecondPlayer() }
        else {
            window.leavePlayer()
            model.goBack()
        }
    }

    private var hideControls: Bool {
        window.fullScreen && hideSuggestions
    }

    /// The recommendations lie over the picture. They fade during idle playback in a window
    /// as well, where the transport along the lower edge stays.
    private var hideSuggestions: Bool {
        playing && idle && !adjustingSlider && !voiceOver
    }

    private struct IdleTimer: Equatable {
        let activity: Date
        let playing: Bool
    }

    var body: some View {
        picture
            .background(.black)
            .overlay {
                GeometryReader { viewport in
                    CinemaControls(model: model, session: session, window: window, leave: leave, move: move,
                                   playerHeight: viewport.size.height, suggestionsHidden: hideSuggestions,
                                   adjustingSlider: $adjustingSlider)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .environment(\.colorScheme, .dark)
                .opacity(hideControls ? 0 : 1)
                .allowsHitTesting(!hideControls)
                .accessibilityHidden(hideControls)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hideControls)
            }
            .onContinuousHover { phase in
                if case .active = phase { revealControls() }
            }
            .onReceive(session.playback.$playing.removeDuplicates()) { active in
                if playing != active { playing = active; revealControls() }
            }
            .onChange(of: adjustingSlider) { revealControls() }
            .onReceive(window.keyboardActivity) { revealControls() }
            .onChange(of: window.fullScreen) {
                revealControls()
            }
            // Resuming playback restarts the timer even right after the last pointer movement.
            .task(id: IdleTimer(activity: lastActivity, playing: playing)) {
                guard playing else { return }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                idle = true
            }
    }

    private var picture: some View {
        ZStack {
            PlayerSurface(player: session.playback.player)
                .accessibilityHidden(true)
            Rectangle().fill(.clear).contentShape(Rectangle())
                .gesture(TapGesture(count: 2).onEnded { window.toggle() }
                    .exclusively(before: TapGesture().onEnded {
                        if session.playback.duration > 0 { session.playback.togglePlayback() }
                    }))
                .accessibilityHidden(true)
            VStack {
                PlayerStatus(controller: session.playback)
                Spacer()
            }
            .padding(.top, 48)
        }
    }

    /// Pointer movement arrives many times per second. Restart the idle timer at most twice
    /// a second so the controls and Cinema suggestions are not rebuilt for every event.
    private func revealControls() {
        if idle { idle = false }
        let now = Date.now
        if now.timeIntervalSince(lastActivity) >= 0.5 { lastActivity = now }
    }
}

private struct CinemaControls: View {
    @Bindable var model: LibraryModel
    let session: PlayerSession
    @ObservedObject var window: PlayerWindow
    let leave: () -> Void
    let move: (NSScreen) -> Void
    let playerHeight: CGFloat
    let suggestionsHidden: Bool
    @Binding var adjustingSlider: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let queue = session.cinemaQueue
        let collectionTitle = model.collectionTitle(for: session.collection ?? model.shelf)
        let detached = session === model.secondPlayer
        let backLabel = detached ? "Close Player" : "Return to \(collectionTitle)"
        if let index = queue.firstIndex(where: { $0.id == session.entryID }) {
            let entry = queue[index]
            let previous = queue[..<index].last(where: LibraryModel.cinemaPlayable)
            let next = queue.dropFirst(index + 1).first(where: LibraryModel.cinemaPlayable)
            VStack(alignment: .trailing, spacing: 0) {
                if model.showsCinemaSuggestions {
                    let preferredCount = model.cinemaRecommendationCount.rawValue
                    CinemaSuggestions(model: model, entry: entry, queue: queue,
                                      limit: playerHeight < 640 ? min(preferredCount, 4) : preferredCount) { entry in
                        model.play(entry, in: session)
                    }
                        .padding(.trailing, VSpace.section)
                        .opacity(suggestionsHidden ? 0 : 1)
                        .allowsHitTesting(!suggestionsHidden)
                        .accessibilityHidden(suggestionsHidden)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: suggestionsHidden)
                }

                VStack(spacing: VSpace.tight) {
                    HStack(spacing: VSpace.control) {
                        Button(action: leave) {
                            Label(backLabel, systemImage: detached ? "xmark" : "chevron.left")
                        }
                        .labelStyle(.iconOnly)
                        .keyboardShortcut(.escape, modifiers: [])
                        .help("\(backLabel) (Esc)")

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).font(.headline)
                            Text("\(collectionTitle) · \(index + 1) of \(queue.count)")
                                .font(.caption)
                        }
                        .lineLimit(1)
                        .frame(maxWidth: 200, alignment: .leading)
                        .shadow(color: .black.opacity(0.8), radius: 2, y: 1)

                        PlayerTimeline(controller: session.playback, posterPrepared: model.posterPrepared,
                               onEditingChanged: { adjustingSlider = $0 })
                            .id(entry.id)
                        PlaybackTime(controller: session.playback)
                    }

                    HStack(spacing: VSpace.tight) {
                        step("Previous Video", symbol: "backward.end.fill", to: previous, key: "p")
                        PlaybackButtons(controller: session.playback)
                        step("Next Video", symbol: "forward.end.fill", to: next, key: "n")
                        Spacer(minLength: VSpace.group)
                        EntryReactions(model: model, entry: entry)
                        Toggle(isOn: $model.showsCinemaSuggestions) {
                            Label("More to Watch", systemImage: "sidebar.right")
                        }
                        .toggleStyle(.button)
                        .labelStyle(.iconOnly)
                        .help(model.showsCinemaSuggestions ? "Hide video recommendations" : "Show video recommendations")
                        PlayerOptions(controller: session.playback, window: window, move: move, adjustingSlider: $adjustingSlider)
                            .padding(.leading, VSpace.control)
                    }
                }
                .padding(.horizontal, VSpace.section)
                .padding(.bottom, VSpace.group)
                .padding(.top, VSpace.section)
                .foregroundStyle(.white)
                .tint(.white)
                .background {
                    if reduceTransparency {
                        Color.black
                    } else {
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.38), location: 0.35),
                            .init(color: .black.opacity(0.54), location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    }
                }
            }
        }
    }

    private func step(_ label: String, symbol: String, to entry: CatalogEntry?, key: KeyEquivalent) -> some View {
        Button {
            if let entry { model.play(entry, in: session) }
        } label: { Label(label, systemImage: symbol) }
        .labelStyle(.iconOnly)
        .keyboardShortcut(key, modifiers: [])
        .disabled(entry == nil)
        .help((entry.map { "\(label): \($0.title)" } ?? label) + " (\(String(key.character).uppercased()))")
    }
}

private struct PlaybackTime: View {
    @ObservedObject var controller: PlayerController

    var body: some View {
        Text("\(clockLabel(controller.position)) / \(clockLabel(controller.duration))")
            .font(.callout.monospacedDigit())
            .fixedSize()
    }
}

private struct PlaybackButtons: View {
    @ObservedObject var controller: PlayerController

    private var playLabel: String {
        if controller.ended { return "Replay" }
        return controller.wantsPlayback ? "Pause" : "Play"
    }

    var body: some View {
        HStack(spacing: VSpace.tight) {
            Button { controller.seek(to: controller.position - 10) } label: {
                Label("Back 10 seconds", systemImage: "gobackward.10")
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help("Back 10 seconds (←), 1 second with Shift")
            Button(action: controller.togglePlayback) {
                Label(playLabel, systemImage: controller.ended ? "arrow.counterclockwise" : controller.wantsPlayback ? "pause.fill" : "play.fill")
                    .font(.body.weight(.semibold)).frame(minWidth: 22)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.space, modifiers: [])
            .help("\(playLabel) (Space)")
            Button { controller.seek(to: controller.position + 10) } label: {
                Label("Forward 10 seconds", systemImage: "goforward.10")
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help("Forward 10 seconds (→), 1 second with Shift")
        }
        .disabled(controller.duration <= 0)
        .labelStyle(.iconOnly)
        .background {
            // Shortcuts without a visible button of their own.
            Group {
                Button("Back 1 second") { controller.seek(to: controller.position - 1) }
                    .keyboardShortcut(.leftArrow, modifiers: .shift)
                Button("Forward 1 second") { controller.seek(to: controller.position + 1) }
                    .keyboardShortcut(.rightArrow, modifiers: .shift)
                Button("Volume Up") { controller.stepVolume(by: 0.1) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("Volume Down") { controller.stepVolume(by: -0.1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
            }
            .focusable(false).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

private struct PlayerOptions: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject var window: PlayerWindow
    let move: (NSScreen) -> Void
    @Binding var adjustingSlider: Bool

    var body: some View {
        HStack(spacing: VSpace.control) {
            Menu {
                Button("Set Loop Start") { controller.markLoopStart() }.keyboardShortcut("[", modifiers: [])
                Button("Set Loop End") { controller.markLoopEnd() }.keyboardShortcut("]", modifiers: [])
                    .disabled(controller.loopStart.map { controller.position <= $0 + 0.1 } ?? true)
                Button("Clear Loop") { controller.clearLoop() }.disabled(controller.loopStart == nil)
            } label: {
                Label("Loop", systemImage: "repeat").labelStyle(.iconOnly)
            }
            .fixedSize()
            .disabled(controller.duration <= 0)
            .help("Loop a section between two points ([ and ])")
            HStack(spacing: VSpace.unit) {
                Button(action: controller.toggleMute) {
                    Label(controller.muted ? "Unmute" : "Mute", systemImage: controller.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .labelStyle(.iconOnly)
                }
                .keyboardShortcut("m", modifiers: [])
                .help(controller.muted ? "Unmute (M)" : "Mute (M)")
                Slider(value: Binding(get: { controller.muted ? 0 : Double(controller.volume) },
                                      set: { controller.setVolume(Float($0)) }),
                       in: 0...1, onEditingChanged: { adjustingSlider = $0 })
                    .frame(width: 72)
                    .accessibilityLabel("Volume")
                    .help("Playback volume (↑ and ↓)")
            }
            AirPlayRoute(player: controller.player)
                .frame(width: 28, height: 24)
                .help("Choose an AirPlay video receiver")
            Menu {
                DisplayChoices(select: move)
            } label: {
                Label("Move to Display", systemImage: "display.2").labelStyle(.iconOnly)
            }
            .fixedSize()
            .help("Move this player to a display")
            Button(action: window.toggle) {
                Label(window.fullScreen ? "Exit Full Screen" : "Enter Full Screen",
                      systemImage: window.fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("f", modifiers: [])
            .help(window.fullScreen ? "Exit Full Screen (F or Esc)" : "Enter Full Screen (F)")
        }
    }
}

private struct PlayerStatus: View {
    @ObservedObject var controller: PlayerController
    @State private var showWaiting = false

    var body: some View {
        Group {
            if let error = controller.error {
                VStack(spacing: VSpace.tight) {
                    Image(systemName: "exclamationmark.triangle").font(.title)
                    Text(error).multilineTextAlignment(.center).textSelection(.enabled)
                }
                .foregroundStyle(.white).padding(VSpace.group)
                .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 8))
                .padding(VSpace.group)
            } else if showWaiting && controller.waiting {
                ProgressView("Loading video…").padding(VSpace.group)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                    .environment(\.colorScheme, .dark)
            }
        }
        .task(id: controller.waiting) {
            showWaiting = false
            guard controller.waiting else { return }
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            showWaiting = true
        }
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = false
        view.updatesNowPlayingInfoCenter = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}

private struct AirPlayRoute: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) { view.player = player }
}

private struct PlayerTimeline: View {
    @ObservedObject var controller: PlayerController
    let posterPrepared: PassthroughSubject<URL, Never>
    let onEditingChanged: (Bool) -> Void
    @State private var frames: [PreviewFrame] = []
    @State private var framesRevision = 0
    @State private var hover: CGFloat?
    @State private var draft = 0.0
    @State private var editing = false

    // At either end of the native slider, the knob's center is half its width in from the edge.
    @State private var trackInset: CGFloat = 10

    private var accessibilityPosition: String {
        let position = "\(clockLabel(editing ? draft : controller.position)) of \(clockLabel(controller.duration))"
        guard let start = controller.loopStart else { return position }
        if let end = controller.loopEnd {
            return "\(position). Loop from \(clockLabel(start, tenths: true)) to \(clockLabel(end, tenths: true))."
        }
        return "\(position). Loop start at \(clockLabel(start, tenths: true))."
    }

    var body: some View {
        GeometryReader { layout in
            let width = max(1, layout.size.width)
            let trackWidth = max(1, width - 2 * trackInset)
            Slider(value: Binding(get: { editing ? draft : controller.position }, set: { draft = $0 }),
                   in: 0...max(0.001, controller.duration), onEditingChanged: { started in
                editing = started
                onEditingChanged(started)
                if started { draft = controller.position }
                else { controller.seek(to: draft) }
            })
            .accessibilityLabel("Video timeline")
            .accessibilityValue(accessibilityPosition)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover = min(1, max(0, (point.x - trackInset) / trackWidth))
                case .ended: hover = nil
                }
            }
            .overlay(alignment: .top) {
                LoopTimelineMarks(start: controller.loopStart, end: controller.loopEnd, duration: controller.duration)
                    .padding(.horizontal, trackInset)
                    .frame(height: 10)
                    .offset(y: -10)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .topLeading) {
                let fraction = editing ? CGFloat(draft / max(0.001, controller.duration)) : hover
                if let fraction, controller.duration > 0 {
                    let time = editing ? draft : Double(fraction) * controller.duration
                    let anchor = trackInset + trackWidth * fraction
                    let gap: CGFloat = controller.loopStart == nil ? 4 : 14
                    VStack(spacing: 2) {
                        if let frame = frames.min(by: { abs($0.time - time) < abs($1.time - time) }) {
                            TimelineStill(url: frame.url)
                        }
                        Text(clockLabel(time)).font(.caption2.monospacedDigit())
                    }
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .fixedSize()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .visualEffect { content, geometry in
                        let size = geometry.size
                        return content.offset(x: min(max(0, anchor - size.width / 2), max(0, width - size.width)),
                                              y: -size.height - gap)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
        .frame(height: 18)
        .task { trackInset = NSSliderCell().knobThickness / 2 }
        .onReceive(posterPrepared) { directory in
            if directory == controller.previewDirectory, frames.isEmpty { framesRevision += 1 }
        }
        .task(id: TimelineFramesKey(directory: controller.previewDirectory, revision: framesRevision)) {
            frames = []
            guard let directory = controller.previewDirectory else { return }
            // Previews published by the library arrive through posterPrepared. Poll slowly as
            // well, because the player can also outlive the library's preview run.
            var delay = Duration.seconds(2)
            while !Task.isCancelled {
                let result = await Task.detached(priority: .utility) { PreviewCache.frames(in: directory) }.value
                guard !Task.isCancelled else { return }
                if !result.isEmpty { frames = result; return }
                do { try await Task.sleep(for: delay) } catch { return }
                delay = min(delay * 2, .seconds(60))
            }
        }
    }
}

private struct LoopTimelineMarks: View {
    let start: Double?
    let end: Double?
    let duration: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let startX = width * fraction(start)
            let endX = width * fraction(end)
            KeyframeAnimator(initialValue: 0.0, trigger: end) { pulse in
                if start != nil, end != nil, duration > 0 {
                    let strength = reduceMotion ? 0 : pulse
                    Capsule().fill(.tint)
                        .opacity(0.68 + 0.32 * strength)
                        .frame(width: max(1, endX - startX), height: 2 + 2 * strength)
                        .position(x: (startX + endX) / 2, y: 8)
                    marker("B", at: endX, labelOffset: 6)
                }
            } keyframes: { _ in
                LinearKeyframe(1, duration: 0.08)
                CubicKeyframe(0, duration: 0.28)
            }
            KeyframeAnimator(initialValue: 0.0, trigger: start) { travel in
                if start != nil, duration > 0 {
                    marker("A", at: startX, labelOffset: -6)
                        .offset(y: reduceMotion ? 0 : travel)
                }
            } keyframes: { _ in
                MoveKeyframe(-4)
                CubicKeyframe(0.8, duration: 0.14)
                CubicKeyframe(0, duration: 0.10)
            }
        }
    }

    private func fraction(_ time: Double?) -> Double {
        guard let time, duration > 0 else { return 0 }
        return min(1, max(0, time / duration))
    }

    private func marker(_ letter: String, at x: CGFloat, labelOffset: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Text(letter).font(.system(size: 9, weight: .bold, design: .rounded))
                .fixedSize()
                .position(x: x + labelOffset, y: 4)
            Capsule().fill(.tint)
                .frame(width: 2, height: 7)
                .position(x: x, y: 5.5)
        }
    }
}

struct TimelineStill: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
        }
        .frame(width: 96, height: 54)
        .task(id: url) {
            let bytes = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
            guard !Task.isCancelled else { return }
            image = bytes.flatMap(NSImage.init(data:))
        }
    }
}

func clockLabel(_ seconds: Double, tenths: Bool = false) -> String {
    let bounded = min(max(0, seconds), Double(Int32.max))
    let value = Int(bounded)
    let time = value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
                             : String(format: "%d:%02d", value / 60, value % 60)
    return tenths ? "\(time).\(Int(bounded * 10) % 10)" : time
}

private struct TimelineFramesKey: Equatable {
    let directory: URL?
    let revision: Int
}
