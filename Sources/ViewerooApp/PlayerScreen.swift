import AVKit
import SwiftUI
import ViewerooCore

struct PlayerScreen: View {
    @ObservedObject var controller: PlayerController
    let onClose: () -> Void
    var onLock: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    controller.stop()
                    onClose()
                } label: { Label("Back", systemImage: "chevron.left") }
                .keyboardShortcut(.escape, modifiers: [])
                Text(controller.title).font(.headline).lineLimit(1)
                Spacer()
                if let onLock {
                    Button(action: onLock) { Label("Lock Vieweroo", systemImage: "lock").labelStyle(.iconOnly) }
                        .help("Lock Vieweroo")
                }
                AirPlayRoute(player: controller.player)
                    .frame(width: 34, height: 28)
                    .help("Choose an AirPlay video receiver")
            }
            .padding(14)
            ZStack {
                Color.black
                PlayerSurface(player: controller.player)
                if let error = controller.error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(error).multilineTextAlignment(.center).textSelection(.enabled)
                    }
                    .foregroundStyle(.white)
                    .padding(20).background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 8))
                    .padding()
                }
            }
            VStack(spacing: 8) {
                PlayerTimeline(controller: controller)
                HStack(spacing: 12) {
                    Button { controller.seek(to: controller.position - 10) } label: {
                        Label("Back 10 seconds", systemImage: "gobackward.10")
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    Button { controller.togglePlayback() } label: {
                        Label(controller.playing ? "Pause" : "Play",
                              systemImage: controller.playing ? "pause.fill" : "play.fill")
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    Button { controller.seek(to: controller.position + 10) } label: {
                        Label("Forward 10 seconds", systemImage: "goforward.10")
                    }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    Text("\(clockLabel(controller.position)) / \(clockLabel(controller.duration))")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if let start = controller.loopStart {
                        Text(controller.loopEnd.map { "\(clockLabel(start)) – \(clockLabel($0))" } ?? clockLabel(start))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Menu {
                        Button("Set Loop Start") { controller.markLoopStart() }.keyboardShortcut("[", modifiers: [])
                        Button("Set Loop End") { controller.markLoopEnd() }.keyboardShortcut("]", modifiers: [])
                            .disabled(controller.loopStart.map { controller.position <= $0 + 0.1 } ?? true)
                        Button("Clear Loop") { controller.clearLoop() }.disabled(controller.loopStart == nil)
                    } label: { Label("Loop", systemImage: "repeat") }
                    .labelStyle(.titleAndIcon).fixedSize()
                }
                .labelStyle(.iconOnly)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .disabled(controller.duration <= 0)
        }
        .onDisappear { controller.stop() }
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
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

    var body: some View {
        GeometryReader { layout in
            let width = max(1, layout.size.width)
            Slider(value: Binding(get: { editing ? draft : controller.position }, set: { draft = $0 }),
                   in: 0...max(0.001, controller.duration), onEditingChanged: { started in
                editing = started
                if started { draft = controller.position }
                else { controller.seek(to: draft) }
            })
            .accessibilityLabel("Video timeline")
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover = min(1, max(0, point.x / width))
                case .ended: hover = nil
                }
            }
            .overlay(alignment: .leading) {
                if let hover {
                    let time = editing ? draft : Double(hover) * controller.duration
                    VStack(spacing: 3) {
                        if let frame = frames.min(by: { abs($0.time - time) < abs($1.time - time) }),
                           let image = NSImage(contentsOf: frame.url) {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 144, height: 81)
                        }
                        Text(clockLabel(time)).font(.caption.monospacedDigit())
                    }
                    .frame(width: 148).padding(4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .fixedSize()
                    .alignmentGuide(VerticalAlignment.center) { $0[.bottom] + 12 }
                    .offset(x: min(max(0, width * hover - 78), max(0, width - 156)))
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 18)
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

private func clockLabel(_ seconds: Double) -> String {
    let value = Int(min(max(0, seconds), Double(Int32.max)))
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
    return String(format: "%d:%02d", value / 60, value % 60)
}
