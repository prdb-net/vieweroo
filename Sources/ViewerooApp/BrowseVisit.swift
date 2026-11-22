import SwiftUI
import ViewerooCore

// API labels and portraits may change between two links to the same collection.
enum CollectionKey: Hashable {
    case shelf(Shelf), studio(String), performer(String)

    init(_ shelf: Shelf) {
        switch shelf {
        case let .studio(name, siteID):
            self = .studio(StudioOption(name: name, isCustom: false, siteID: siteID).id)
        case let .performer(person):
            self = .performer(person.id)
        default:
            self = .shelf(shelf)
        }
    }
}

enum BrowseTile: Hashable {
    case studio(String, siteID: String? = nil), video(Int64), performer(String), playlist(Int64)
}

@MainActor
struct BrowseVisit: Identifiable {
    let id = UUID()
    var shelf: Shelf = .studios
    var query = ""
    var filters = CollectionFilters()
    var detailID: Int64?
    var selectedTile: BrowseTile?
    let castScroll = BrowseScrollPosition()
    private(set) var scroll = BrowseScrollPosition()

    // A direct revisit starts a new history entry with its own scroll attachment.
    func reopened(on destination: Shelf) -> BrowseVisit {
        BrowseVisit(shelf: destination, query: query, filters: filters, selectedTile: selectedTile,
                    scroll: BrowseScrollPosition(origin: scroll.origin))
    }

    mutating func renameStudio(_ name: String, to newName: String) {
        let oldID = StudioOption(name: name, isCustom: true).id
        if filters.studios.removeValue(forKey: oldID) != nil {
            filters.studios[StudioOption(name: newName, isCustom: true).id] = newName
        }
        if case let .studio(current, nil) = shelf, current.caseInsensitiveCompare(name) == .orderedSame {
            shelf = .studio(newName)
        }
        if case let .studio(current, nil) = selectedTile, current.caseInsensitiveCompare(name) == .orderedSame {
            selectedTile = .studio(newName)
        }
    }
}

// ScrollViewReader can reveal a tile, but a tall row may be partly offscreen.
// Save the clip origin so Back also restores that part of the row on macOS 14.
@MainActor
final class BrowseScrollPosition {
    weak var view: NSScrollView?
    private(set) var origin: NSPoint

    init(origin: NSPoint = .zero) { self.origin = origin }

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
                    let clip = scroll.contentView
                    let target = NSRect(origin: position.origin, size: clip.bounds.size)
                    clip.scroll(to: clip.constrainBoundsRect(target).origin)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }
    }

    func makeNSView(context: Context) -> Anchor { Anchor(position: position) }
    func updateNSView(_ nsView: Anchor, context: Context) {}
}
