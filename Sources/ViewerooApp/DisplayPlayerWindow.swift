import AppKit
import SwiftUI

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

@MainActor @Observable
private final class ConnectedDisplays: NSObject {
    static let shared = ConnectedDisplays()
    private(set) var screens = NSScreen.screens

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func refresh() { screens = NSScreen.screens }
}

struct DisplayChoices: View {
    let select: (NSScreen) -> Void

    var body: some View {
        let screens = ConnectedDisplays.shared.screens
        ForEach(Array(screens.enumerated()), id: \.element.displayID) { index, screen in
            let name = screen.localizedName
            let duplicate = screens.filter { $0.localizedName == name }.count > 1
            Button(duplicate ? "\(name) (\(index + 1))" : name) { select(screen) }
        }
    }
}

@MainActor
final class DisplayPlayerWindow: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private weak var model: LibraryModel?
    private var presentation: PlayerWindow?
    private var displayID: CGDirectDisplayID?

    func present(_ session: PlayerSession, model: LibraryModel, on screen: NSScreen, fullScreen: Bool = true) {
        dismiss()
        self.model = model
        displayID = screen.displayID
        let controls = PlayerWindow()
        controls.usingSecondPlayer = true
        presentation = controls
        let player = NSWindow(contentRect: .init(x: 0, y: 0, width: 960, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window = player
        player.title = "Vieweroo Player"
        player.isReleasedWhenClosed = false
        player.isRestorable = false
        player.sharingType = .none
        player.tabbingMode = .disallowed
        player.collectionBehavior = [.fullScreenPrimary]
        player.backgroundColor = .black
        player.contentViewController = NSHostingController(rootView:
            PlayerScreen(model: model, session: session, window: controls)
                .background(.black).environment(\.colorScheme, .dark))
        let bounds = screen.visibleFrame
        let width = min(960, bounds.width), height = min(600, bounds.height)
        player.minSize = NSSize(width: 720, height: 360)
        player.setFrame(.init(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                              width: width, height: height), display: false)
        player.delegate = self
        controls.attach(to: player)
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        player.makeKeyAndOrderFront(nil)
        if fullScreen { controls.toggle() }
    }

    func dismiss() {
        NotificationCenter.default.removeObserver(self)
        presentation?.attach(to: nil)
        presentation = nil
        window?.delegate = nil
        window?.orderOut(nil)
        window?.contentViewController = nil
        window?.close()
        window = nil
        displayID = nil
    }

    func windowWillClose(_ notification: Notification) {
        // AppKit is already closing this window.
        window?.delegate = nil
        window = nil
        model?.closeSecondPlayer()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        // AppKit may relocate the window before it announces a disconnected display.
        guard NSScreen.screens.contains(where: { $0.displayID == displayID }) else {
            displaysChanged()
            return
        }
        if let screen = window?.screen { displayID = screen.displayID }
    }

    @objc private func displaysChanged() {
        recoverIfDisplayDisconnected(available: NSScreen.screens)
    }

    func recoverIfDisplayDisconnected(available: [NSScreen]) {
        guard let displayID, !available.contains(where: { $0.displayID == displayID }),
              let model, let session = model.secondPlayer else { return }
        if session.playback.wantsPlayback { session.playback.togglePlayback() }
        if let screen = available.first { present(session, model: model, on: screen, fullScreen: false) }
    }
}
