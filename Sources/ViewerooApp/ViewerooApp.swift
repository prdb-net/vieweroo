import AppKit
import SwiftUI
import ViewerooCore

@main
struct ViewerooApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @FocusedBinding(\.librarySearch) private var librarySearch
    @State private var model: LibraryModel
    private let title: String

    init() {
        #if DEBUG
        if Bundle.main.bundleIdentifier == "net.prdb.vieweroo.test-library" {
            title = "Vieweroo Test Library"
            let root = Bundle.main.bundleURL.deletingLastPathComponent()
            _model = State(initialValue: TestLibraryProfile.model(at: root))
            return
        }
        #endif
        title = "Vieweroo"
        _model = State(initialValue: LibraryModel())
    }

    var body: some Scene {
        Window(Text(verbatim: title), id: "library") {
            RootView(model: model, windowTitle: title)
                .frame(minWidth: 790, minHeight: 535)
                .background(LibraryWindowConfiguration(browsing: model.phase == .ready && !model.playing))
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Search Library") { librarySearch = true }
                    .keyboardShortcut("f")
                    .disabled(model.phase != .ready || model.playing || model.libraryID == nil || librarySearch == nil)
            }
            CommandGroup(after: .newItem) {
                Button("Add Source Folder…") { model.pickSource() }
                    .keyboardShortcut("o")
                    .disabled(model.phase != .ready || model.libraryID == nil)
                Button("Refresh Library") { model.refresh() }
                    .keyboardShortcut("r")
                    .disabled(model.phase != .ready || model.libraryID == nil)
                Divider()
                Button("Lock Vieweroo") { model.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(model.phase != .ready || !model.pinEnabled)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldSaveApplicationState(_ sender: NSApplication) -> Bool { false }
    func applicationShouldRestoreApplicationState(_ sender: NSApplication) -> Bool { false }
}

// Keep AppKit's title bar background so empty areas receive native window gestures.
// While browsing, the toolbar supplies the aligned title.
struct LibraryWindowConfiguration: NSViewRepresentable {
    let browsing: Bool

    final class Host: NSView {
        var browsing = false
        func updateTitlebar() {
            guard let window else { return }
            let visibility: NSWindow.TitleVisibility = browsing ? .hidden : .visible
            if window.titleVisibility != visibility { window.titleVisibility = visibility }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.sharingType = .none
            window?.isRestorable = false
            window?.tabbingMode = .disallowed
            updateTitlebar()
        }
    }
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ nsView: Host, context: Context) {
        nsView.browsing = browsing
        nsView.updateTitlebar()
    }
}

struct RootView: View {
    @Bindable var model: LibraryModel
    let windowTitle: String

    var body: some View {
        Group {
            switch model.phase {
            case .starting: ProgressView()
            case .locked, .setup: AccessView(model: model)
            case .ready:
                LibraryView(model: model, windowTitle: windowTitle)
                    .overlay(alignment: .bottomTrailing) {
                        if let notice = model.notice {
                            ActionNoticeView(notice: notice) {
                                if model.notice?.id == notice.id { model.notice = nil }
                            }
                            .id(notice.id)
                            .padding(.trailing, VSpace.section)
                            .padding(.bottom, model.playing ? 88 : VSpace.section)
                        }
                    }
            case .failed:
                ContentUnavailableView {
                    Label("Vieweroo could not open", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(model.failure ?? "Check access to your local application data.")
                } actions: {
                    Button("Try Again") { model.start() }
                }
            }
        }
        .task { if model.phase == .starting { model.start() } }
        .alert("Vieweroo", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.playback.stop() }
    }
}

struct AccessView: View {
    @Bindable var model: LibraryModel
    @State private var secret = ""
    @State private var recovery = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var setup: Bool { model.phase == .setup }
    var body: some View {
        VStack(alignment: .leading, spacing: VSpace.group) {
            Image(systemName: setup ? "rectangle.stack.badge.play" : "lock.fill")
                .font(.system(size: 44, weight: .light)).foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(setup ? "Connect to PRDB" : recovery ? "Reset your PIN" : "Unlock Vieweroo")
                .font(.largeTitle.bold())
            Text(setup ? (model.setupReason ?? "Enter your personal PRDB API key to identify videos across your libraries.") :
                    recovery ? "Choose a new PIN, then authenticate with your Mac to save it." : "Enter your PIN to open your library.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField(setup ? "PRDB API key" : recovery ? "New PIN" : "PIN", text: $secret)
                .textFieldStyle(.roundedBorder).controlSize(.large).focused($focused).onSubmit { submit() }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(setup ? "Verify Key" : recovery ? "Reset PIN…" : "Unlock") { submit() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(busy || secret.isEmpty)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if !setup {
                    Button(recovery ? "Back to Unlock" : "Forgot PIN?") {
                        recovery.toggle(); error = nil; secret = ""; focused = true
                    }.disabled(busy)
                }
            }
        }
        .frame(width: 355).padding(VSpace.page)
        .onAppear { focused = true }
        .id(model.phase)
    }

    private func submit() {
        guard !busy, !secret.isEmpty else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                if setup { try await model.configure(key: secret) }
                else if recovery { try await model.recover(pin: secret) }
                else { try model.unlock(pin: secret) }
                secret = ""
            } catch { self.error = error.localizedDescription }
        }
    }
}
