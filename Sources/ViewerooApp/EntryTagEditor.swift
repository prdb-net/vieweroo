import SwiftUI
import ViewerooCore

struct EntryTagEditor: View {
    let model: LibraryModel
    let entry: CatalogEntry
    @State private var selected: [String]
    @State private var libraryTags: [String] = []
    @State private var draft = ""
    @State private var error: String?

    init(model: LibraryModel, entry: CatalogEntry) {
        self.model = model
        self.entry = entry
        _selected = State(initialValue: entry.tags)
    }

    private var available: [String] {
        let assigned = Set(selected.map { $0.lowercased() })
        return libraryTags.filter { !assigned.contains($0.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VSpace.tight) {
            HStack {
                Text("Tags").font(.headline)
                Spacer()
                let options = available
                Menu("Choose Tag") {
                    ForEach(options, id: \.self) { tag in Button(tag) { add(tag) } }
                }
                .fixedSize().disabled(options.isEmpty)
            }
            if !selected.isEmpty {
                ChipRows {
                    ForEach(selected, id: \.self) { tag in
                        MetadataChip(name: tag, removeLabel: "Remove tag \(tag)") {
                            save(selected.filter { $0 != tag })
                        }
                    }
                }
            }
            HStack {
                TextField("New tag", text: $draft).onSubmit { add(draft) }
                IconActionButton(.add, "Add Tag") { add(draft) }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
        }
        .onAppear {
            // Only other entries can supply an unassigned tag in this single-window editor.
            var seen = Set<String>()
            libraryTags = model.entries.filter { $0.id != entry.id }
                .flatMap(\.tags)
                .filter { seen.insert($0.lowercased()).inserted }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    private func add(_ value: String) {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if selected.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            error = "This tag is already on the video."
            return
        }
        let existing = available.first { $0.caseInsensitiveCompare(name) == .orderedSame }
        if save(selected + [existing ?? name]), value == draft { draft = "" }
    }

    @discardableResult private func save(_ tags: [String]) -> Bool {
        let saved = model.change(onFailure: { error = $0 }) { try $0.setTags(entryID: entry.id, tags: tags) }
        if saved { selected = tags; error = nil }
        return saved
    }
}

struct MetadataChip: View {
    let name: String
    var removeLabel: String?
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: VSpace.unit) {
            Text(name).lineLimit(1).help(name)
            if let remove, let removeLabel {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).accessibilityLabel(removeLabel).help(removeLabel)
            }
        }
        .padding(.horizontal, VSpace.tight)
        .padding(.vertical, VSpace.unit)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}

struct ChipRows: Layout {
    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        return subviews.map { chip in
            let size = chip.sizeThatFits(ProposedViewSize(width: min(width, chip.sizeThatFits(.unspecified).width), height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + VSpace.unit
                rowHeight = 0
            }
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            x += size.width + VSpace.unit
            rowHeight = max(rowHeight, size.height)
            return frame
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (chip, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            chip.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       proposal: ProposedViewSize(frame.size))
        }
    }
}
