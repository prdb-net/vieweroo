import AppKit
import SwiftUI
import Testing
@testable import ViewerooApp
@testable import ViewerooCore

/// Whether a toolbar with a hidden title claims a click in its empty area in a window the
/// library has not configured.
@MainActor
private func toolbarClaimsClicks() -> Bool {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                          styleMask: [.titled, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.toolbar = NSToolbar(identifier: "ToolbarProbe")
    window.titleVisibility = .hidden
    guard let content = window.contentView, let frame = content.superview else { return false }
    frame.layoutSubtreeIfNeeded()
    let point = NSPoint(x: frame.bounds.midX, y: (frame.bounds.maxY + window.contentLayoutRect.maxY) / 2)
    guard let target = frame.hitTest(point) else { return false }
    return !target.isDescendant(of: content)
}

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
    // On the CI image, macOS 27.0 in a virtual machine, a toolbar with a hidden title lets a
    // click in its empty area through to the content, also in a window the library never
    // configured. The expectation holds wherever AppKit's own toolbar claims that click.
    let claimed = toolbarClaimsClicks()
    withKnownIssue("The toolbar claims no click in its empty area here") {
        #expect(!target.isDescendant(of: scroll))
    } when: { !claimed }
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
    window.contentView = NSHostingView(rootView: BrowserView(model: model, selection: .constant(nil), selectionShortcuts: false))
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

@MainActor
@Test func timelineStillDisplaysTheCachedImageOnFirstAppearance() async throws {
    _ = NSApplication.shared
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
    defer { try? FileManager.default.removeItem(at: url) }
    let fixture = NSImage(size: NSSize(width: 16, height: 9), flipped: false) { rect in
        NSColor.red.setFill()
        rect.fill()
        return true
    }
    let tiff = try #require(fixture.tiffRepresentation)
    let jpeg = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:]))
    try jpeg.write(to: url)

    let host = NSHostingView(rootView: TimelineStill(url: url))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 96, height: 54),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil) }
    let deadline = ContinuousClock.now + .seconds(3)
    repeat {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        // The fixture is drawn and read back in the color space of the current display. On a
        // wide-gamut display its red arrives as about (0.95, 0.29, 0.15), so test for a red
        // frame by dominance instead of fixed limits for green and blue.
        if let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB),
           color.redComponent > 0.8, color.redComponent > 2 * color.greenComponent,
           color.redComponent > 2 * color.blueComponent { return }
        try await Task.sleep(for: .milliseconds(30))
    } while ContinuousClock.now < deadline
    Issue.record("The timeline preview did not display the cached red frame.")
}
