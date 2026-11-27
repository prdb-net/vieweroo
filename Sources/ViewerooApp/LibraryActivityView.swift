import SwiftUI
import ViewerooCore

struct LibraryActivityButton: View {
    let model: LibraryModel
    let openSettings: () -> Void
    @State private var expanded = false

    private var summary: String {
        if model.loadingLibrary { return "Opening library…" }
        if model.scanBusy { return "Scanning folders…" }
        switch model.previews.phase {
        case .checking: return "Checking previews…"
        case .preparing: return "Preparing previews"
        case .idle: break
        }
        if let activity = model.lookupActivity { return activity }
        if model.networkStatus != nil { return "PRDB needs attention" }
        if !model.previews.failures.isEmpty { return "Preview issues" }
        if model.sources.contains(where: { !$0.online }) { return "Folders offline" }
        return "Ready"
    }

    var body: some View {
        Button { expanded.toggle() } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary).lineLimit(2)
                if model.previews.phase == .preparing {
                    Text("\(model.previews.ready) / \(model.previews.total)").monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Library activity")
        .accessibilityValue(model.previews.phase == .preparing
                            ? "\(summary), \(model.previews.ready) of \(model.previews.total)" : summary)
        .help("Show library activity")
        .popover(isPresented: $expanded, arrowEdge: .trailing) {
            LibraryActivityView(model: model) {
                expanded = false
                openSettings()
            }
        }
    }
}

private struct LibraryActivityView: View {
    let model: LibraryModel
    let openSettings: () -> Void
    @State private var showQueue = false
    @State private var showFailures = false

    var body: some View {
        VStack(alignment: .leading, spacing: VSpace.group) {
            Text("Library Activity").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: VSpace.group) {
                    VStack(alignment: .leading, spacing: VSpace.unit) {
                        Text("Folder scan").font(.headline)
                        Text(model.scanBusy ? model.scanningFolder.map { "Scanning “\($0)”" } ?? "Scanning folders…" : "Idle")
                        ForEach(model.sources.filter { !$0.online }) { source in
                            Label("\(source.url.lastPathComponent) · Offline", systemImage: "externaldrive.badge.xmark")
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: VSpace.unit) {
                        Text("PRDB matching").font(.headline)
                        Text(model.networkStatus ?? model.lookupActivity ?? "Idle")
                        let pending = model.entries.lazy.filter { $0.needsLookup && $0.availability == .available }.count
                        if pending > 0 { Text("\(pending) awaiting lookup").foregroundStyle(.secondary) }
                        let unmatched = model.unmatchedCount
                        if unmatched > 0 {
                            HStack {
                                Text(unmatched == 1 ? "1 video without a title" : "\(unmatched) videos without a title")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Check Again", systemImage: ActionSymbol.refresh.rawValue, action: model.retryUnmatched)
                                    .help("Ask PRDB again for videos without a title")
                                    .disabled(model.subscriptionRequired)
                            }
                        }
                        if model.subscriptionRequired {
                            HStack {
                                IconActionButton(.refresh, "Retry PRDB", action: model.retrySubscription)
                                IconActionButton(.manage, "Settings…", action: openSettings)
                            }
                        }
                    }
                    Divider()
                    previewDetails
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(VSpace.group)
        .frame(width: 320, height: 352)
    }

    @ViewBuilder private var previewDetails: some View {
        let progress = model.previews
        VStack(alignment: .leading, spacing: VSpace.tight) {
            Text("Timeline previews").font(.headline)
            if progress.phase == .checking {
                Text("Checking cached previews…")
            } else if progress.total > 0 {
                Text("\(progress.ready) of \(progress.total) available videos ready").monospacedDigit()
                if let current = progress.remaining.first {
                    ProgressView(value: Double(progress.ready), total: Double(progress.total))
                    Text("Preparing “\(current.title)”")
                    let waiting = progress.remaining.dropFirst()
                    if !waiting.isEmpty {
                        DisclosureGroup("Waiting (\(waiting.count))", isExpanded: $showQueue) {
                            LazyVStack(alignment: .leading, spacing: VSpace.unit) {
                                ForEach(waiting) { Text($0.title).lineLimit(2) }
                            }
                        }
                    }
                }
                if !progress.failures.isEmpty {
                    DisclosureGroup("Failed (\(progress.failures.count))", isExpanded: $showFailures) {
                        LazyVStack(alignment: .leading, spacing: VSpace.tight) {
                            ForEach(progress.failures) { failure in
                                VStack(alignment: .leading) {
                                    Text(failure.entry.title)
                                    Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("Refresh the library to retry.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(model.scanBusy ? "Waiting for the scan to finish" : "Idle")
            }
            let offline = model.entries.lazy.filter { $0.availability == .offline }.count
            let missing = model.entries.lazy.filter { $0.availability == .missing }.count
            if offline > 0 { Text("\(offline) videos on offline drives").foregroundStyle(.secondary) }
            if missing > 0 { Text("\(missing) missing files").foregroundStyle(.secondary) }
        }
        .disclosureGroupStyle(FullWidthDisclosureStyle())
    }
}
