import SwiftUI
import ViewerooCore

struct EntryView: View {
    @Bindable var model: LibraryModel
    let entry: CatalogEntry
    @ObservedObject var window: PlayerWindow
    @State private var showingLibrary = false
    @State private var stats: PlaybackStats?
    private var available: Bool { entry.availability == .available }

    var body: some View {
        GeometryReader { layout in
            // Keep the player width stable when a legacy scrollbar appears at the content-height threshold.
            let gutter = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            let pageWidth = min(1320, max(1, layout.size.width - gutter))
            let sideBySide = layout.size.width >= 760 && model.hasAlternatives(to: entry)
            ScrollViewReader { scroll in
                ScrollView {
                    HStack(alignment: .top, spacing: VSpace.section) {
                        VStack(alignment: .leading, spacing: VSpace.section) {
                            overview { scroll.scrollTo(entry.id, anchor: .top) }.id(entry.id)
                            performers
                            if !sideBySide {
                                RelatedVideosView(model: model, current: entry, style: .shelf, onSelect: model.playSuggested)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if sideBySide {
                            RelatedVideosView(model: model, current: entry, onSelect: model.playSuggested)
                                .frame(width: min(304, layout.size.width * 0.31), alignment: .leading)
                        }
                    }
                    .padding(VSpace.section)
                    .frame(width: sideBySide ? pageWidth : min(pageWidth, 780), alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .background(BrowseScrollAnchor(position: model.visit.scroll))
                }
            }
            .sheet(isPresented: $showingLibrary) {
                EntryLibraryDetails(model: model, entry: entry)
                    .frame(width: 692, height: max(340, min(610, layout.size.height - VSpace.section)))
            }
        }
        .task(id: entry.watchTime) { loadHistory() }
        .onReceive(model.playback.recordedInterval) { id in
            if entry.id == id { loadHistory() }
        }
    }

    private func loadHistory() {
        stats = try? model.catalog?.playbackStats(entryID: entry.id)
    }

    private func overview(revealVideo: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: VSpace.group) {
            VStack(alignment: .leading, spacing: VSpace.unit) {
                Text(entry.title)
                    .font(.title.bold()).textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                let studio = model.studioDirectory.studio(for: entry)
                let studioName = studio.name
                HStack(spacing: VSpace.control) {
                    Button { model.browse(.studio(studioName, siteID: studio.siteID), from: .studio(studioName, siteID: studio.siteID)) } label: {
                        HStack(spacing: VSpace.unit) {
                            Text(studioName)
                            Image(systemName: "chevron.forward").font(.caption2)
                        }
                    }
                    .buttonStyle(.link)
                    .help("Browse videos from \(studioName)")
                    if let creator = studio.creator { CreatorProfileView(account: creator) }
                    if let quality = entry.videoInfo?.quality {
                        Text(quality)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: VSpace.unit))
                            .fixedSize()
                            .accessibilityLabel("Video quality, \(quality)")
                    }
                }
            }
            if model.playing {
                PlayerScreen(model: model, window: window)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                playPoster
            }
            if !available || entry.playbackFailure != nil {
                Label(entry.availability == .offline ? "Reconnect the source drive to play this video." :
                        entry.availability == .missing ? "This file is missing from its source folder." :
                        entry.playbackFailure ?? "", systemImage: "exclamationmark.triangle")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: VSpace.tight) {
                    organizationActions
                    detailActions(revealVideo)
                }
                VStack(alignment: .leading, spacing: VSpace.tight) {
                    organizationActions
                    detailActions(revealVideo)
                }
            }
        }
    }

    private var playPoster: some View {
        ZStack(alignment: .bottomLeading) {
            Poster(model: model, entry: entry)
                .contentShape(Rectangle())
                .onTapGesture { if available { model.play(entry) } }
            if available {
                playbackActions
                    .foregroundStyle(.white)
                    .padding(VSpace.group)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: VSpace.tight, style: .continuous))
    }

    private var playbackActions: some View {
        let resume = entry.resume > 0
        let action = resume ? "Resume at \(durationLabel(entry.resume))" : "Play"
        return HStack(spacing: VSpace.tight) {
            Button { model.play(entry) } label: {
                Group {
                    if resume {
                        Label(action, systemImage: "play.fill")
                            .padding(.horizontal, VSpace.group)
                    } else {
                        Label("Play", systemImage: "play.fill")
                            .labelStyle(.iconOnly)
                            .frame(width: VSpace.page)
                    }
                }
                .font(.headline).monospacedDigit()
                .frame(height: VSpace.page)
                .foregroundStyle(.black).background(.white, in: Capsule())
            }
            .help(action)
            .accessibilityLabel(resume ? "Resume \(entry.title) at \(durationLabel(entry.resume))" : "Play \(entry.title)")
            if resume {
                Button { model.play(entry, at: 0) } label: {
                    Label("Play from Beginning", systemImage: "backward.end.fill")
                        .labelStyle(.iconOnly)
                        .frame(width: VSpace.page, height: VSpace.page)
                        .background(.black.opacity(0.76), in: Circle())
                }
                .help("Play from Beginning")
            }
        }
        .buttonStyle(.plain)
    }

    private var organizationActions: some View {
        HStack(spacing: VSpace.tight) {
            EntryReactions(model: model, entry: entry)
            PlaylistMenu(model: model, entryID: entry.id).help("Add to Playlist")
        }
    }

    private func detailActions(_ revealVideo: @escaping () -> Void) -> some View {
        HStack(spacing: VSpace.tight) {
            HistoryButton(model: model, entry: entry, stats: stats, revealVideo: revealVideo)
            Button { showingLibrary = true } label: {
                Label("Library Details", systemImage: "info.circle").labelStyle(.iconOnly)
            }
            .help("Library Details")
        }
    }

    @ViewBuilder private var performers: some View {
        if let people = entry.match?.performers, !people.isEmpty {
            VStack(alignment: .leading, spacing: VSpace.control) {
                Text("Performers").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: VSpace.group) {
                        ForEach(people) { person in
                            Button {
                                model.browse(.performer(person), from: .performer(person.id))
                            } label: {
                                VStack {
                                    AsyncImage(url: model.artworkURL(person.portraitURL)) { phase in
                                        if let image = phase.image { image.resizable().scaledToFill() }
                                        else { Image(systemName: "person.fill").font(.title).foregroundStyle(.tertiary) }
                                    }.frame(width: 60, height: 60).background(.quaternary).clipShape(Circle())
                                    .overlay {
                                        if model.visit.selectedTile == .performer(person.id) {
                                            Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                                        }
                                    }
                                    Text(person.name).lineLimit(2).frame(width: 92)
                                }
                            }.buttonStyle(.plain)
                            .accessibilityAddTraits(model.visit.selectedTile == .performer(person.id) ? .isSelected : [])
                        }
                    }
                    .background(BrowseScrollAnchor(position: model.visit.castScroll))
                }
            }
        }
    }
}

private struct HistoryButton: View {
    let model: LibraryModel
    let entry: CatalogEntry
    let stats: PlaybackStats?
    let revealVideo: () -> Void
    @State private var showing = false

    private var playCount: Int { stats?.playCount ?? entry.playCount }
    private var watchTime: Double { stats?.watchTime ?? entry.watchTime }
    private var summary: String { historySummary(plays: playCount, seconds: watchTime) }

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: VSpace.tight) {
                Label(String(playCount), systemImage: "play.fill")
                Label(watchTimeLabel(watchTime), systemImage: "clock")
                Image(systemName: "chevron.down").font(.caption2)
            }
            .monospacedDigit()
        }
        .accessibilityLabel("Viewing History")
        .accessibilityValue(summary)
        .help("Viewing History · \(summary)")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: VSpace.control) {
                Text("Viewing History").font(.headline)
                Text(summary).foregroundStyle(.secondary)
                Divider()
                if let stats, !stats.segments.isEmpty {
                    ForEach(Array(stats.segments.prefix(5)), id: \.start) { segment in
                        Button {
                            showing = false
                            if model.playing && model.playback.ready && model.playback.error == nil {
                                model.playback.seek(to: segment.start, resume: true)
                            } else {
                                model.play(entry, at: segment.start)
                            }
                            revealVideo()
                        } label: {
                            HStack {
                                Label("\(durationLabel(segment.start)) – \(durationLabel(segment.end))", systemImage: "play.circle")
                                Spacer()
                                Text("\(segment.passes)×").foregroundStyle(.secondary)
                            }
                            .monospacedDigit().contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(entry.availability != .available)
                    }
                } else {
                    Text(playCount == 0 ? "Watch at least 10 seconds in one session to see segments here." : "No segments available.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(VSpace.group).frame(width: 268)
        }
    }
}

private func watchTimeLabel(_ seconds: Double) -> String {
    Duration.seconds(seconds.rounded(.down)).formatted(.units(width: .narrow, maximumUnitCount: 2))
}

private func historySummary(plays: Int, seconds: Double) -> String {
    "\(plays) \(plays == 1 ? "play" : "plays") · \(watchTimeLabel(seconds)) watched"
}

extension CatalogEntry {
    var viewingSummary: String { historySummary(plays: playCount, seconds: watchTime) }
}

private func durationLabel(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "—" }
    let total = Int(seconds)
    return "\(total / 60):" + String(format: "%02d", total % 60)
}
