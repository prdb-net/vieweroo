import AppKit
import SwiftUI
import Testing
@testable import ViewerooApp
@testable import ViewerooCore

@MainActor
@Test func emptyLibraryTitleBarReceivesClicksAboveScrollableContent() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                          styleMask: [.titled, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.toolbar = NSToolbar(identifier: "LibraryWindowTest")
    let scroll = NSScrollView()
    window.contentView = scroll
    let host = LibraryWindowConfiguration.Host()
    scroll.addSubview(host)

    host.browsing = true
    host.updateTitlebar()
    #expect(window.titleVisibility == .visible)
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    #expect(window.titleVisibility == .hidden)
    #expect(!window.titlebarAppearsTransparent)
    let frame = try #require(scroll.superview)
    frame.layoutSubtreeIfNeeded()
    let point = NSPoint(x: frame.bounds.midX, y: (frame.bounds.maxY + window.contentLayoutRect.maxY) / 2)
    let target = try #require(frame.hitTest(point))
    #expect(!target.isDescendant(of: scroll))
}

@MainActor
@Test func browserGridHeightStaysStableWhenTheScrollbarConsumesWidth() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "vieweroo.scroll-tests." + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let model = LibraryModel(preferences: preferences, directory: root, cache: PreviewCache(root: root))
    let catalog = try Catalog(path: ":memory:")
    let library = try catalog.createLibrary(name: "Grid")
    let source = try catalog.addSource(libraryID: library.id, url: root)
    for i in 0..<40 { try Data().write(to: root.appending(path: "Movie-\(i).mp4")) }
    try CatalogScanner(catalog: catalog).scan(source: source)
    model.phase = .ready
    model.libraryID = library.id
    model.entries = try catalog.entries(libraryID: library.id)
    model.browse(.all)

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 500),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: BrowserView(model: model))
    window.orderBack(nil)
    defer { window.orderOut(nil) }
    let deadline = ContinuousClock.now + .seconds(3)
    while model.visit.scroll.view == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let scroll = try #require(model.visit.scroll.view)
    let document = try #require(scroll.documentView)
    scroll.scrollerStyle = .legacy
    scroll.autohidesScrollers = false
    func measure(showScroller: Bool) async throws -> NSSize {
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            scroll.hasVerticalScroller = showScroller
            scroll.tile()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
            let width = scroll.contentView.bounds.width
            let gutter = scroll.bounds.width - width
            if document.frame.height > scroll.contentView.bounds.height,
               showScroller ? gutter > 1 : gutter < 1 {
                return NSSize(width: width, height: document.frame.height)
            }
        } while ContinuousClock.now < deadline
        return NSSize(width: scroll.contentView.bounds.width, height: document.frame.height)
    }
    let withoutScroller = try await measure(showScroller: false)
    let withScroller = try await measure(showScroller: true)
    #expect(withScroller.width < withoutScroller.width)
    #expect(withScroller.height > scroll.contentView.bounds.height)
    #expect(abs(withScroller.height - withoutScroller.height) <= 1)
}
