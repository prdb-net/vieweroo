import Testing
import ViewerooCore
@testable import ViewerooApp

@MainActor
@Test func browseHistoryRestoresCollectionsAndFollowsCatalogEdits() {
    var history = BrowseHistory()
    #expect(!history.canGoBack)
    var studio = history.revisit(.studio("Harbor"))
    studio.query = "dawn"
    studio.filters.tags = ["night": "Night"]
    history.push(studio, from: .studio("Harbor"))
    history.push(BrowseVisit(shelf: .studio("Harbor"), detailID: 7, selectedTile: .video(7)), from: .video(7))
    history.replaceDetail(with: 9)
    #expect(history.visit.detailID == 9)
    #expect(history.back.last?.selectedTile == .video(9))

    history.renameTag("Night", to: "Late Night")
    #expect(history.back.last?.filters.tags == ["late night": "Late Night"])
    history.renameStudio("Harbor", to: "Pier")
    #expect(history.visit.shelf == .studio("Pier"))
    #expect(history.back.allSatisfy { $0.shelf != .studio("Harbor") })

    let leftDetail = history.pop()
    #expect(leftDetail)
    #expect(history.visit.query == "dawn" && history.visit.detailID == nil)
    let leftStudio = history.pop()
    #expect(leftStudio)
    // Reopening keeps the last search of the renamed collection.
    #expect(history.revisit(.studio("Pier")).query == "dawn")
    let exhausted = history.pop()
    #expect(!exhausted)

    history.push(BrowseVisit(shelf: .studio("Pier"), detailID: 3), from: .video(3))
    history.push(BrowseVisit(shelf: .all))
    history.removeStudio("Pier")
    #expect(history.back.allSatisfy { $0.shelf != .studio("Pier") })
    #expect(history.revisit(.studio("Pier")).query.isEmpty)
}

@MainActor
@Test func browseHistoryPrunesVisitsOfDeletedContent() {
    var history = BrowseHistory()
    history.push(BrowseVisit(shelf: .playlist(1)))
    history.push(BrowseVisit(shelf: .playlist(1), detailID: 4))
    history.push(BrowseVisit(shelf: .tag(2)))
    let replaced = history.prune { visit in
        if case .tag = visit.shelf { return false }
        return visit.detailID != 4
    }
    #expect(replaced)
    #expect(history.visit.shelf == .playlist(1) && history.visit.detailID == nil)
    #expect(history.back.count == 1)
    let unchanged = history.prune { _ in true }
    #expect(!unchanged)
}
