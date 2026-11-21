import SwiftUI

enum BrowseTile: Hashable {
    case studio(String), video(Int64), performer(String), playlist(Int64)
}

@MainActor
struct BrowseVisit: Identifiable {
    let id = UUID()
    var shelf: Shelf = .studios
    var query = ""
    var detailID: Int64?
    var selectedTile: BrowseTile?
    var detailsExpanded = false
    let castScroll = BrowseScrollPosition()
    let scroll = BrowseScrollPosition()
}

// ScrollViewReader can reveal a tile, but a tall row may be partly offscreen.
// Save the clip origin so Back also restores that part of the row on macOS 14.
@MainActor
final class BrowseScrollPosition {
    weak var view: NSScrollView?
    private(set) var origin = NSPoint.zero

    func save() {
        if let view { origin = view.contentView.bounds.origin }
    }
}

struct BrowseScrollAnchor: View {
    let position: BrowseScrollPosition

    var body: some View {
        ScrollAttachment(position: position)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct ScrollAttachment: NSViewRepresentable {
    let position: BrowseScrollPosition

    final class Anchor: NSView {
        let position: BrowseScrollPosition
        init(position: BrowseScrollPosition) {
            self.position = position
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = enclosingScrollView, window != nil else { return }
                position.view = scroll
                if position.origin != .zero {
                    scroll.contentView.scroll(to: position.origin)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }
    }

    func makeNSView(context: Context) -> Anchor { Anchor(position: position) }
    func updateNSView(_ nsView: Anchor, context: Context) {}
}
