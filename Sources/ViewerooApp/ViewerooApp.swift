import AppKit
import SwiftUI
import ViewerooCore

@main
struct ViewerooApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @FocusedBinding(\.showAppSettings) private var showAppSettings
    @FocusedBinding(\.librarySearch) private var librarySearch
    @State private var model: LibraryModel
    private let title: String

    init() {
        #if DEBUG
        if let root = TestLibraryProfile.root(for: .main) {
            title = "Vieweroo Test Library"
            _model = State(initialValue: TestLibraryProfile.model(at: root))
            return
        }
        #endif
        title = "Vieweroo"
        _model = State(initialValue: LibraryModel())
    }

    var body: some Scene {
        Window(Text(verbatim: title), id: "library") {
            RootView(model: model)
                .frame(minWidth: 790, minHeight: 535)
                .background {
                    LibraryWindowConfiguration(browsing: model.phase == .ready)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { showAppSettings = true }
                    .keyboardShortcut(",")
                    .disabled(model.phase != .ready || showAppSettings == nil)
            }
            CommandGroup(after: .sidebar) {
                Button("Find in Collection") { librarySearch = true }
                    .keyboardShortcut("f")
                    .disabled(model.phase != .ready || model.libraryID == nil || librarySearch == nil)
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
// The library menu occupies a single leading toolbar item while browsing.
struct LibraryWindowConfiguration: NSViewRepresentable {
    let browsing: Bool

    final class Host: NSView {
        var browsing = false
        private var titlebarUpdatePending = false
        private var titleVisibility: NSWindow.TitleVisibility { browsing ? .hidden : .visible }

        func updateTitlebar() {
            guard let window, window.titleVisibility != titleVisibility, !titlebarUpdatePending else { return }
            // Changing window chrome can request another constraint pass. Let SwiftUI
            // finish attaching and hit-testing its views before changing the window.
            titlebarUpdatePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                titlebarUpdatePending = false
                guard let window = self.window, window.titleVisibility != titleVisibility else { return }
                window.titleVisibility = titleVisibility
            }
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

    var body: some View {
        Group {
            switch model.phase {
            case .starting: ProgressView()
            case .locked, .setup: AccessView(model: model)
            case .ready:
                LibraryView(model: model)
                    .overlay(alignment: .bottomTrailing) {
                        if let notice = model.notice {
                            ActionNoticeView(notice: notice, onUndo: { model.undoBulkEdit(notice) }) {
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
