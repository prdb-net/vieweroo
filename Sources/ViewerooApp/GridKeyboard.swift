import AppKit
import SwiftUI

enum GridKey {
    case left, right, up, down, activate, details

    init?(keyCode: UInt16) {
        switch keyCode {
        case 123: self = .left
        case 124: self = .right
        case 125: self = .down
        case 126: self = .up
        case 36, 76: self = .activate
        case 49: self = .details
        default: return nil
        }
    }
}

/// Arrow keys, Return and Space for a tile grid. SwiftUI buttons take no keyboard focus on a
/// click, so the grid listens for these keys in its window while no text is being edited.
@MainActor
final class GridKeyboard {
    /// Set by the grid on every update. Returns true when the key was used.
    var handle: (GridKey) -> Bool = { _ in false }
    private var monitor: Any?
    private weak var window: NSWindow?

    func attach(to window: NSWindow?) {
        guard self.window !== window || (window == nil && monitor != nil) else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        self.window = window
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window, window.attachedSheet == nil,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  // A field editor has the keys while a search, tag or file name is typed.
                  !(window.firstResponder is NSText),
                  let key = GridKey(keyCode: event.keyCode) else { return event }
            return self.handle(key) ? nil : event
        }
    }
}

struct GridKeyReader: NSViewRepresentable {
    let keyboard: GridKeyboard

    final class Host: NSView {
        var keyboard: GridKeyboard?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            keyboard?.attach(to: window)
        }
    }

    func makeNSView(context: Context) -> Host {
        let host = Host()
        host.keyboard = keyboard
        return host
    }

    func updateNSView(_ view: Host, context: Context) {}

    static func dismantleNSView(_ view: Host, coordinator: ()) {
        view.keyboard?.attach(to: nil)
        view.keyboard = nil
    }
}
