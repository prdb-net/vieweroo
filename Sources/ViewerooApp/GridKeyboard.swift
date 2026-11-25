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
/// click, so the grid listens for these keys in its window. The keys stay with a control that
/// has the keyboard focus, such as the sidebar list or a text field, and a click in the grid
/// takes the focus from it, as a click in a Finder window does.
@MainActor
final class GridKeyboard {
    /// Set by the grid on every update. Returns true when the key was used.
    var handle: (GridKey) -> Bool = { _ in false }
    private var monitors: [Any] = []
    private weak var host: NSView?

    /// Whether a view with keys of its own has the focus: a text being edited, a list, a slider.
    private static func focusedControl(in window: NSWindow) -> Bool {
        window.firstResponder is NSText || window.firstResponder is NSControl
    }

    func attach(to host: NSView?) {
        let attached = host?.window == nil ? nil : host
        guard self.host !== attached || (attached == nil && !monitors.isEmpty) else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        self.host = attached
        guard attached != nil else { return }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, let window = self.host?.window, event.window === window, window.attachedSheet == nil,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  !Self.focusedControl(in: window), let key = GridKey(keyCode: event.keyCode) else { return event }
            if key == .activate || key == .details {
                // With Full Keyboard Access, Space presses the button that has the focus ring.
                if NSApp.isFullKeyboardAccessEnabled { return event }
                // A held key must not play a video in the collection it just opened.
                if event.isARepeat { return nil }
            }
            return self.handle(key) ? nil : event
        }) { monitors.append(keys) }
        if let clicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            if let self, let host = self.host, let window = host.window, event.window === window,
               host.convert(host.bounds, to: nil).contains(event.locationInWindow), Self.focusedControl(in: window) {
                window.makeFirstResponder(nil)
            }
            return event
        }) { monitors.append(clicks) }
    }
}

/// Covers the grid it serves, so a click inside its bounds counts as a click in the grid.
struct GridKeyReader: NSViewRepresentable {
    let keyboard: GridKeyboard

    final class Host: NSView {
        var keyboard: GridKeyboard?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            keyboard?.attach(to: window == nil ? nil : self)
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
