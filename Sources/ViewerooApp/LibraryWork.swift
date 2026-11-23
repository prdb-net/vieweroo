/// Background tasks that belong to one opened library session. Leaving the library,
/// locking or replacing the key cancels them together. A task compares its captured
/// work object with the model's current one before it applies a result.
@MainActor
final class LibraryWork {
    enum Slot: CaseIterable {
        case lookups, availability, scan, videoInfo, previews, snapshot, playbackRefresh
    }

    private var tasks: [Slot: Task<Void, Never>] = [:]
    private(set) var isCancelled = false

    subscript(slot: Slot) -> Task<Void, Never>? {
        get { tasks[slot] }
        set { tasks[slot] = newValue }
    }

    /// Cancel every task and mark results that still arrive as stale.
    func cancel() {
        isCancelled = true
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }
}
