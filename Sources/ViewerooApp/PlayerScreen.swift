import AVKit
import SwiftUI
import ViewerooCore

struct PlayerScreen: View {
    let model: LibraryModel
    @ObservedObject var window: PlayerWindow
    @State private var videoAspectRatio: CGFloat = 16.0 / 9
    @State private var lastActivity = Date.now
    @State private var idle = false
    @State private var playing = false
    @State private var overHeader = false
    @State private var overTransport = false
    @State private var adjustingVolume = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hideControls: Bool {
        window.fullScreen && playing && idle && !overHeader && !overTransport && !adjustingVolume && !voiceOver
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.cinemaMode {
                picture
                    .background(.black)
                    .overlay(alignment: .bottom) {
                        CinemaControls(model: model, window: window)
                            .environment(\.colorScheme, .dark)
                    }
            } else if window.fullScreen {
                picture
                    .background(.black)
                    .overlay {
                        VStack(spacing: 0) {
                            header.background(.black.opacity(0.86))
                            Spacer()
                            transport.background(.black.opacity(0.86))
                        }
                        .environment(\.colorScheme, .dark)
                        .opacity(hideControls ? 0 : 1)
                        .allowsHitTesting(!hideControls)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hideControls)
                    }
                    .onContinuousHover { if case .active = $0 { revealControls() } }
            } else {
                Color.black.aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { picture }
                    .clipShape(RoundedRectangle(cornerRadius: VSpace.tight, style: .continuous))
                transport
            }
        }
        .onReceive(model.playback.$videoAspectRatio.removeDuplicates()) { videoAspectRatio = $0 ?? 16.0 / 9 }
        .onReceive(model.playback.$playing.removeDuplicates()) { active in
            if playing != active { playing = active; revealControls() }
        }
        .onReceive(window.keyboardActivity) { revealControls() }
        .onChange(of: window.fullScreen) {
            overHeader = false
            overTransport = false
            revealControls()
        }
        .task(id: lastActivity) {
            guard window.fullScreen && playing else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            idle = true
        }
    }

    private var videoSurface: some View {
        GeometryReader { viewport in
            let bounds = CGRect(origin: .zero, size: viewport.size)
            let picture = window.fullScreen || model.cinemaMode ? bounds : AVMakeRect(
                aspectRatio: CGSize(width: videoAspectRatio, height: 1), insideRect: bounds
            )
            PlayerSurface(player: model.playback.player)
                .frame(width: picture.width, height: picture.height)
                .background(.black)
                .position(x: bounds.midX, y: bounds.midY)
        }
        .accessibilityHidden(true)
    }

    private var picture: some View {
        ZStack {
            videoSurface
            Rectangle().fill(.clear).contentShape(Rectangle())
                .gesture(TapGesture(count: 2).onEnded { window.toggle() }
                    .exclusively(before: TapGesture().onEnded {
                        if model.playback.duration > 0 { model.playback.togglePlayback() }
                    }))
                .accessibilityHidden(true)
            VStack {
                PlayerStatus(controller: model.playback)
                if model.cinemaMode { Spacer() }
            }
            .padding(.top, model.cinemaMode ? 48 : 0)
        }
    }

    private func revealControls() {
        idle = false
        lastActivity = .now
    }

    private var header: some View {
        HStack(spacing: VSpace.control) {
            Button {
                window.leavePlayer()
                model.goBack()
            } label: { Label("Back", systemImage: "chevron.left") }
            .labelStyle(.iconOnly)
            .help("Return to the library")
            Text(model.playback.title)
                .font(.headline).lineLimit(1).truncationMode(.tail)
                .help(model.playback.title)
            Spacer(minLength: VSpace.tight)
            if model.pinEnabled {
                Button(action: model.lock) { Label("Lock Vieweroo", systemImage: "lock").labelStyle(.iconOnly) }
                    .help("Lock Vieweroo (⇧⌘L)")
            }
            AirPlayRoute(player: model.playback.player)
                .frame(width: 32, height: 28)
                .help("Choose an AirPlay video receiver")
        }
        .padding(.horizontal, VSpace.group).padding(.vertical, VSpace.tight)
        .onHover { overHeader = $0 }
    }

    private var transport: some View {
        PlayerTransport(controller: model.playback, window: window, adjustingVolume: $adjustingVolume)
            .padding(.horizontal, window.fullScreen ? VSpace.group : VSpace.unit).padding(.vertical, VSpace.control)
            .onHover { overTransport = $0 }
    }
}

private struct CinemaControls: View {
    let model: LibraryModel
    @ObservedObject var window: PlayerWindow
    @State private var adjustingVolume = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let playlist = model.videosInCollection
        if let index = playlist.firstIndex(where: { $0.id == model.detailID }) {
            let entry = playlist[index]
            let previous = playlist[..<index].last(where: LibraryModel.cinemaPlayable)
            let next = playlist.dropFirst(index + 1).first(where: LibraryModel.cinemaPlayable)
            VStack(spacing: VSpace.tight) {
                HStack(spacing: VSpace.control) {
                    Button {
                        window.leavePlayer()
                        model.goBack()
                    } label: { Label("Return to Playlist", systemImage: "chevron.left") }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Return to Playlist (Esc)")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.headline)
                        Text("\(model.collectionTitle) · \(index + 1) of \(playlist.count)")
                            .font(.caption)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)
                    .shadow(color: .black.opacity(0.8), radius: 2, y: 1)

                    PlayerTimeline(controller: model.playback)
                        .id(entry.id)
                    PlaybackTime(controller: model.playback)
                }

                HStack(spacing: VSpace.tight) {
                    step("Previous Video", symbol: "backward.end.fill", to: previous)
                    PlaybackButtons(controller: model.playback)
                    step("Next Video", symbol: "forward.end.fill", to: next)
                    Spacer(minLength: VSpace.group)
                    EntryReactions(model: model, entry: entry)
                    PlayerOptions(controller: model.playback, window: window, adjustingVolume: $adjustingVolume,
                                  cinema: true)
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

    private func step(_ label: String, symbol: String, to entry: CatalogEntry?) -> some View {
        Button {
            if let entry { model.play(entry, suggested: true) }
        } label: { Label(label, systemImage: symbol) }
        .labelStyle(.iconOnly)
        .disabled(entry == nil)
        .help(entry.map { "\(label): \($0.title)" } ?? label)
    }
}

private struct PlayerTransport: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject var window: PlayerWindow
    @Binding var adjustingVolume: Bool

    var body: some View {
        VStack(spacing: VSpace.tight) {
            PlayerTimeline(controller: controller)
                .disabled(controller.duration <= 0)
            HStack(spacing: VSpace.control) {
                PlaybackButtons(controller: controller)
                PlaybackTime(controller: controller).foregroundStyle(.secondary)
                Spacer(minLength: VSpace.unit)
                PlayerOptions(controller: controller, window: window, adjustingVolume: $adjustingVolume)
            }
        }
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
            .help("Back 10 seconds (←)")
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
            .help("Forward 10 seconds (→)")
        }
        .disabled(controller.duration <= 0)
        .labelStyle(.iconOnly)
    }
}

private struct PlayerOptions: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject var window: PlayerWindow
    @Binding var adjustingVolume: Bool
    var cinema = false

    var body: some View {
        HStack(spacing: VSpace.control) {
            Menu {
                Button("Set Loop Start") { controller.markLoopStart() }.keyboardShortcut("[", modifiers: [])
                Button("Set Loop End") { controller.markLoopEnd() }.keyboardShortcut("]", modifiers: [])
                    .disabled(controller.loopStart.map { controller.position <= $0 + 0.1 } ?? true)
                Button("Clear Loop") { controller.clearLoop() }.disabled(controller.loopStart == nil)
            } label: {
                if cinema {
                    Label("Loop", systemImage: "repeat").labelStyle(.iconOnly)
                } else {
                    Label(controller.loopStart.map { start in
                        controller.loopEnd.map { end in
                            let short = end - start < 1
                            return "\(clockLabel(start, tenths: short)) – \(clockLabel(end, tenths: short))"
                        } ?? "From \(clockLabel(start))"
                    } ?? "Loop", systemImage: "repeat")
                }
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
                       in: 0...1, onEditingChanged: { adjustingVolume = $0 })
                    .frame(width: 72)
                    .accessibilityLabel("Volume")
                    .help("Playback volume")
            }
            if cinema || !window.fullScreen {
                AirPlayRoute(player: controller.player)
                    .frame(width: 28, height: 24)
                    .help("Choose an AirPlay video receiver")
            }
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
    @State private var frames: [PreviewFrame] = []
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
        .task(id: controller.previewDirectory) {
            frames = []
            guard let directory = controller.previewDirectory else { return }
            while !Task.isCancelled {
                let result = await Task.detached(priority: .utility) { PreviewCache.frames(in: directory) }.value
                guard !Task.isCancelled else { return }
                if !result.isEmpty { frames = result; return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
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
        .task(id: url) { image = NSImage(contentsOf: url) }
    }
}

func clockLabel(_ seconds: Double, tenths: Bool = false) -> String {
    let bounded = min(max(0, seconds), Double(Int32.max))
    let value = Int(bounded)
    let time = value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
                             : String(format: "%d:%02d", value / 60, value % 60)
    return tenths ? "\(time).\(Int(bounded * 10) % 10)" : time
}
