import AppKit
import Testing
@testable import ViewerooApp

@MainActor
@Test func emptyLibraryTitleBarReceivesClicksAboveScrollableContent() throws {
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
    #expect(window.titleVisibility == .hidden)
    #expect(!window.titlebarAppearsTransparent)
    let frame = try #require(scroll.superview)
    frame.layoutSubtreeIfNeeded()
    let point = NSPoint(x: frame.bounds.midX, y: (frame.bounds.maxY + window.contentLayoutRect.maxY) / 2)
    let target = try #require(frame.hitTest(point))
    #expect(!target.isDescendant(of: scroll))
}
