import SwiftUI
import ViewerooCore

struct PosterScrubber: View {
    let directory: URL
    let revision: Int
    @State private var fraction: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .overlay {
                    if let fraction {
                        CachedPreview(directory: directory, revision: revision, fraction: fraction)
                            .id(directory)
                            .allowsHitTesting(false)
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        fraction = min(1, max(0, point.x / max(1, geometry.size.width)))
                    case .ended:
                        fraction = nil
                    }
                }
        }
    }
}

// Read the manifest only for the image under the pointer. A newly published
// generation can become available while the pointer is still over that image.
private struct CachedPreview: View {
    let directory: URL
    let revision: Int
    let fraction: CGFloat
    @State private var frames: [PreviewFrame] = []
    @State private var still: (image: NSImage, time: Double)?

    var body: some View {
        let index = min(Int(fraction * CGFloat(frames.count)), frames.count - 1)
        let frame = frames.indices.contains(index) ? frames[index] : nil
        Color.clear
            .overlay {
                if let still {
                    Image(nsImage: still.image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .topLeading) {
                if let still {
                    Text(clockLabel(still.time))
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .foregroundStyle(.white).background(.black.opacity(0.8), in: Capsule())
                        .padding(VSpace.tight)
                }
            }
            .task(id: revision) {
                let available = await Task.detached(priority: .utility) { PreviewCache.frames(in: directory) }.value
                if !Task.isCancelled { frames = available }
            }
            .task(id: frame?.url) {
                guard let frame else { still = nil; return }
                let bytes = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: frame.url) }.value
                guard !Task.isCancelled else { return }
                still = bytes.flatMap(NSImage.init(data:)).map { ($0, frame.time) }
            }
    }
}
