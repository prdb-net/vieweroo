import ViewerooCore

/// The current browsing visit, its Back stack and the last view of each collection
/// during one library session. Catalog edits that rename or remove a collection
/// update all three together.
@MainActor
struct BrowseHistory {
    var visit = BrowseVisit()
    private(set) var back: [BrowseVisit] = []
    private var lastCollections: [CollectionKey: BrowseVisit] = [:]

    var canGoBack: Bool { !back.isEmpty }

    /// A previous view of the destination keeps its search, filters and scroll origin.
    func revisit(_ destination: Shelf) -> BrowseVisit {
        lastCollections[CollectionKey(destination)]?.reopened(on: destination) ?? BrowseVisit(shelf: destination)
    }

    mutating func push(_ next: BrowseVisit, from tile: BrowseTile? = nil) {
        if let tile { visit.selectedTile = tile }
        saveCurrentLocation()
        back.append(visit)
        visit = next
    }

    /// Returns false when there is nothing to go back to.
    mutating func pop() -> Bool {
        guard let previous = back.popLast() else { return false }
        saveCurrentLocation()
        visit = previous
        return true
    }

    mutating func saveCurrentLocation() {
        visit.scroll.save()
        visit.castScroll.save()
        guard visit.detailID == nil else { return }
        let key = CollectionKey(visit.shelf)
        // Back can display an older search. Passing through it does not apply it again.
        if let latest = lastCollections[key], latest.query != visit.query || latest.filters != visit.filters { return }
        lastCollections[key] = visit
    }

    /// Show another video in the open detail visit. Back highlights the latest video.
    mutating func replaceDetail(with id: Int64) {
        visit.detailID = id
        visit.selectedTile = .video(id)
        if let index = back.indices.last { back[index].selectedTile = .video(id) }
    }

    /// Clearing the search of a collection that was opened without one returns to that view.
    func clearingSearchReturns(to shelf: Shelf) -> Bool {
        guard let previous = back.last else { return false }
        return previous.shelf == shelf && previous.detailID == nil && previous.query.isEmpty && previous.filters.isEmpty
    }

    mutating func rememberCollection() {
        lastCollections[CollectionKey(visit.shelf)] = visit
    }

    mutating func renameTag(_ name: String, to newName: String) {
        func update(_ visit: inout BrowseVisit) {
            if visit.filters.tags.removeValue(forKey: name.lowercased()) != nil {
                visit.filters.tags[newName.lowercased()] = newName
            }
        }
        update(&visit)
        for index in back.indices { update(&back[index]) }
        for key in lastCollections.keys { update(&lastCollections[key]!) }
    }

    mutating func renameStudio(_ name: String, to newName: String) {
        visit.renameStudio(name, to: newName)
        for index in back.indices { back[index].renameStudio(name, to: newName) }
        let oldKey = CollectionKey(.studio(name)), newKey = CollectionKey(.studio(newName))
        if let saved = lastCollections.removeValue(forKey: oldKey) { lastCollections[newKey] = saved }
        for key in lastCollections.keys { lastCollections[key]?.renameStudio(name, to: newName) }
    }

    /// Detail visits opened from the studio would reopen over an empty collection.
    mutating func removeStudio(_ name: String) {
        let key = CollectionKey(.studio(name))
        lastCollections.removeValue(forKey: key)
        back.removeAll { CollectionKey($0.shelf) == key }
    }

    /// Drop visits whose video, tag or playlist no longer exists. Returns true when the
    /// current visit was replaced by the latest valid one.
    mutating func prune(keeping valid: (BrowseVisit) -> Bool) -> Bool {
        back.removeAll { !valid($0) }
        lastCollections = lastCollections.filter { valid($0.value) }
        guard !valid(visit) else { return false }
        visit = back.popLast() ?? BrowseVisit()
        return true
    }
}
