import SwiftUI
import AVFoundation
import ViewerooCore

struct CollectionCoverPicker: View {
    let model: LibraryModel
    let collection: CoverCollection
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int64?
    @State private var error: String?

    init(model: LibraryModel, collection: CoverCollection) {
        self.model = model
        self.collection = collection
        _selected = State(initialValue: collection.cover?.entryID ?? collection.memberIDs.first)
    }

    private var entries: [CatalogEntry] {
        switch collection.id {
        case let .studio(_, studioID):
            return model.entries.filter { model.studioDirectory.studio(for: $0).id == studioID }
        case .tag:
            let members = Set(collection.memberIDs)
            return model.entries.filter { members.contains($0.id) }
        case .playlist:
            let byID = Dictionary(uniqueKeysWithValues: model.entries.map { ($0.id, $0) })
            return collection.memberIDs.compactMap { byID[$0] }
        }
    }

    var body: some View {
        let entries = self.entries
        VStack(alignment: .leading, spacing: VSpace.group) {
            Text("Choose Cover for “\(collection.name)”").font(.title2.bold()).lineLimit(2)
            HStack(alignment: .top, spacing: VSpace.group) {
                List(entries, selection: $selected) { entry in
                    HStack(spacing: VSpace.tight) {
                        Poster(model: model, entry: entry, scrubbable: false).frame(width: 68)
                        VStack(alignment: .leading) {
                            Text(entry.title).lineLimit(2)
                            if entry.availability != .available {
                                Text(entry.availability == .offline ? "Source offline" : "File missing")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.tag(entry.id)
                }
                .accessibilityLabel("Videos in \(collection.name)")
                .listStyle(.inset)
                .frame(minWidth: 170, idealWidth: 220, maxWidth: 260)
                if let entry = entries.first(where: { $0.id == selected }) {
                    FrameEditor(model: model, collection: collection, entry: entry) { frame in
                        if model.change("Cover saved", onFailure: { error = $0 }, {
                            try $0.saveCover(collection.id, entryID: entry.id, time: frame.time.seconds, image: frame.image, custom: true)
                        }) { dismiss() }
                    }.id(entry.id)
                } else {
                    ContentUnavailableView("Select a video", systemImage: "film")
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Use Automatic Cover") {
                    if model.change("Automatic cover restored", onFailure: { error = $0 }, { try $0.resetCover(collection.id) }) { dismiss() }
                }.disabled(collection.cover?.isCustom != true)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(VSpace.section)
        .frame(minWidth: 680, idealWidth: 860, minHeight: 420, idealHeight: 490)
    }
}

private struct FrameEditor: View {
    struct Request: Equatable {
        let time: CMTime
        var step: Int64 = 0
    }

    let model: LibraryModel
    let collection: CoverCollection
    let entry: CatalogEntry
    let save: (TagFrameReader.Frame) -> Void
    @State private var reader: TagFrameReader?
    @State private var request = Request(time: .zero)
    @State private var loaded: Request?
    @State private var frame: TagFrameReader.Frame?
    @State private var image: NSImage?
    @State private var strip: [(time: Double, image: NSImage)] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: VSpace.control) {
            Color.black.aspectRatio(16/9, contentMode: .fit)
                .overlay {
                    if let image { Image(nsImage: image).resizable().scaledToFit() }
                    else if error == nil { ProgressView().controlSize(.small) }
                }
                .clipShape(RoundedRectangle(cornerRadius: VSpace.tight))
                .accessibilityLabel("Selected frame")
            if let reader {
                HStack(spacing: 2) {
                    ForEach(strip.indices, id: \.self) { index in
                        let sample = strip[index]
                        Button { seek(sample.time) } label: {
                            Rectangle().fill(.quaternary).aspectRatio(16/9, contentMode: .fit)
                                .overlay { Image(nsImage: sample.image).resizable().scaledToFill() }.clipped()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Seek to \(clockLabel(sample.time))")
                    }
                }
                Slider(value: Binding(get: {
                    min(reader.duration, loaded == request ? frame?.time.seconds ?? request.time.seconds : request.time.seconds)
                }, set: seek), in: 0...reader.duration)
                    .accessibilityLabel("Frame position")
                HStack {
                    frameButton("Previous frame", symbol: "backward.frame", key: .leftArrow, direction: -1)
                    frameButton("Next frame", symbol: "forward.frame", key: .rightArrow, direction: 1)
                    if let frame {
                        let millis = Int((frame.time.seconds * 1000).rounded())
                        Text(verbatim: String(format: "%d:%02d.%03d", millis / 60000, millis / 1000 % 60, millis % 1000))
                            .font(.callout.monospacedDigit())
                    }
                    Spacer()
                    Button("Use This Frame") { if loaded == request, let frame { save(frame) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(frame == nil || loaded != request)
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: entry.availability) {
            reader = nil; frame = nil; loaded = nil; error = nil
            if collection.cover?.entryID == entry.id, let bytes = try? await model.catalog?.coverImage(collection.id), !Task.isCancelled {
                image = NSImage(data: bytes)
            }
            guard entry.availability == .available else {
                error = "Reconnect the source or select another video to choose a frame."
                return
            }
            do {
                let source = try await TagFrameReader(url: entry.url)
                try Task.checkCancellation()
                seek(collection.cover?.entryID == entry.id ? collection.cover?.time ?? 0 : 0)
                reader = source
            } catch { if !Task.isCancelled { self.error = "This video could not be opened." } }
        }
        .task(id: reader != nil) {
            guard let reader else { return }
            let directory = model.previewDirectory(entry)
            let thumbs = await Task.detached(priority: .utility) { PreviewCache.frames(in: directory) }.value
            let count = thumbs.isEmpty ? 6 : min(6, thumbs.count)
            var samples: [(time: Double, image: NSImage)] = []
            for index in 0..<count {
                guard !Task.isCancelled else { return }
                let time: Double
                let bytes: Data?
                if thumbs.isEmpty {
                    time = reader.duration * Double(index) / Double(count)
                    bytes = try? await reader.frame(at: CMTime(seconds: time, preferredTimescale: 1_000_000_000)).image
                } else {
                    let sample = thumbs[index * (thumbs.count - 1) / max(1, count - 1)]
                    time = sample.time
                    bytes = await Task.detached(priority: .utility) { try? Data(contentsOf: sample.url) }.value
                }
                if !Task.isCancelled, let bytes, let image = NSImage(data: bytes) { samples.append((time, image)) }
            }
            if !Task.isCancelled { strip = samples }
        }
        .task(id: reader == nil ? nil : request) {
            guard let reader else { return }
            do {
                let target = request
                try await Task.sleep(for: .milliseconds(35))
                let result = try await reader.frame(at: target.time, step: target.step)
                try Task.checkCancellation()
                guard request == target else { return }
                frame = result
                image = NSImage(data: result.image)
                loaded = request
                error = nil
            } catch { if !Task.isCancelled { loaded = nil; self.error = "Couldn’t read this frame. Choose a different position." } }
        }
    }

    private func seek(_ time: Double) {
        request = Request(time: CMTime(seconds: time, preferredTimescale: 1_000_000_000))
    }

    private func frameButton(_ title: String, symbol: String, key: KeyEquivalent, direction: Int64) -> some View {
        Button(title, systemImage: symbol) {
            if let frame { request = Request(time: frame.time, step: direction) }
        }
        .labelStyle(.iconOnly).help(title)
        .keyboardShortcut(key, modifiers: [])
        .disabled(frame == nil || request != loaded)
    }
}
