import AppKit
import Combine
import SwiftUI

/// Controls full screen for one playback window.
@MainActor
final class PlayerWindow: NSObject, ObservableObject {
    private weak var window: NSWindow?
    @Published private(set) var fullScreen = false
    let keyboardActivity = PassthroughSubject<Void, Never>()
    /// Marks the start (false) or end (true) of a loop. Returns whether the key was used.
    var loopKey: ((_ end: Bool) -> Bool)?

    /// The loop keys are [ and ]. Many layouts type them only with Option, as Option-5 and
    /// Option-6 on a German keyboard, so the two keys at their place on a US keyboard, to the
    /// right of P, work as well.
    private static func loopKey(_ event: NSEvent) -> Bool? {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.characters == "[" && modifiers.isSubset(of: [.option]) { return false }
        if event.characters == "]" && modifiers.isSubset(of: [.option]) { return true }
        guard modifiers.isEmpty else { return nil }
        return event.keyCode == 33 ? false : event.keyCode == 30 ? true : nil
    }
    private var keyMonitor: Any?
    private var toolbarWasVisible: Bool?
    private var transitioning = false
    private var enteredFromPlayer = false
    var usingSecondPlayer = false
    private var windowed: (frame: NSRect, style: NSWindow.StyleMask, level: NSWindow.Level)?

    func attach(to window: NSWindow?) {
        guard self.window !== window || (window == nil && keyMonitor != nil) else { return }
        restoreWindowFrame()
        NotificationCenter.default.removeObserver(self)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let toolbarWasVisible { self.window?.toolbar?.isVisible = toolbarWasVisible }
        self.window = window
        toolbarWasVisible = window?.toolbar?.isVisible
        transitioning = false
        guard let window else {
            fullScreen = false
            enteredFromPlayer = false
            return
        }
        fullScreen = window.styleMask.contains(.fullScreen)
        if fullScreen { window.toolbar?.isVisible = false }
        // The library and player share a window. Escape first leaves fullscreen even
        // when the transport is hidden and focus is still in the library view.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window, window.attachedSheet == nil else { return event }
            // Any key brings back what faded during idle playback, in a window as in full screen.
            self.keyboardActivity.send()
            if !(window.firstResponder is NSText), !event.isARepeat, let end = Self.loopKey(event),
               self.loopKey?(end) == true { return nil }
            guard self.fullScreen, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
            if !event.isARepeat { self.toggle() }
            return nil
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(updateLevel), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(updateLevel), name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(willEnter), name: NSWindow.willEnterFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(willExit), name: NSWindow.willExitFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(didChangeFullScreen), name: NSWindow.didEnterFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(didChangeFullScreen), name: NSWindow.didExitFullScreenNotification, object: window)
    }

    @objc private func willEnter() {
        transitioning = true
        fullScreen = true
        window?.toolbar?.isVisible = false
    }

    @objc private func willExit() {
        transitioning = true
        enteredFromPlayer = false
    }

    @objc private func didChangeFullScreen() {
        transitioning = false
        fullScreen = window?.styleMask.contains(.fullScreen) == true
        if !fullScreen, let toolbarWasVisible { window?.toolbar?.isVisible = toolbarWasVisible }
    }

    func toggle() {
        guard let window, !transitioning else { return }
        enteredFromPlayer = !fullScreen
        if windowed != nil {
            restoreWindowFrame()
            fullScreen = false
        } else if !fullScreen, usingSecondPlayer, !NSScreen.screensHaveSeparateSpaces,
                  NSScreen.screens.count > 1, let screen = window.screen {
            // Native full screen changes the Space on every display in this configuration.
            windowed = (window.frame, window.styleMask, window.level)
            window.toolbar?.isVisible = false
            window.styleMask = [.borderless, .resizable]
            updateLevel()
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            fullScreen = true
        } else {
            window.toggleFullScreen(nil)
        }
    }

    @objc private func updateLevel() {
        guard let windowed else { return }
        window?.level = NSApp.isActive ? .init(rawValue: NSWindow.Level.mainMenu.rawValue + 1) : windowed.level
    }

    private func restoreWindowFrame() {
        guard let saved = windowed, let window else { return }
        windowed = nil
        window.level = saved.level
        window.styleMask = saved.style
        window.setFrame(saved.frame, display: true)
        if let toolbarWasVisible { window.toolbar?.isVisible = toolbarWasVisible }
    }

    func leavePlayer() {
        if fullScreen && enteredFromPlayer { toggle() }
    }
}

struct PlayerWindowReader: NSViewRepresentable {
    let presentation: PlayerWindow

    final class Host: NSView {
        weak var presentation: PlayerWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            presentation?.attach(to: window)
        }
    }

    func makeNSView(context: Context) -> Host {
        let host = Host()
        host.presentation = presentation
        return host
    }

    func updateNSView(_ view: Host, context: Context) {}

    static func dismantleNSView(_ view: Host, coordinator: ()) {
        view.presentation?.attach(to: nil)
        view.presentation = nil
    }
}
