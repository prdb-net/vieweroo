import SwiftUI

enum VideoReaction: String {
    case favorite = "Favorite"
    case like = "Like"
    case dislike = "Dislike"

    var symbol: String {
        switch self {
        case .favorite: "heart"
        case .like: "hand.thumbsup"
        case .dislike: "hand.thumbsdown"
        }
    }

    func tint(in scheme: ColorScheme) -> Color {
        switch (self, scheme) {
        case (.favorite, .dark): Color(red: 1, green: 0.51, blue: 0.69)
        case (.favorite, _): Color(red: 0.69, green: 0.15, blue: 0.38)
        case (.like, .dark): Color(red: 0.40, green: 0.85, blue: 0.70)
        case (.like, _): Color(red: 0, green: 0.46, blue: 0.39)
        case (.dislike, .dark): Color(red: 0.77, green: 0.64, blue: 1)
        case (.dislike, _): Color(red: 0.40, green: 0.27, blue: 0.69)
        }
    }

    var duration: Double {
        switch self {
        case .favorite: 0.56
        case .like: 0.425
        case .dislike: 0.325
        }
    }
}

struct ReactionButton: View {
    let reaction: VideoReaction
    let isSelected: Bool
    let save: () -> Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activation = 0

    private var helpText: String {
        switch reaction {
        case .favorite: isSelected ? "Remove from Favorites" : "Add to Favorites"
        case .like: isSelected ? "Clear Like" : "Like Video"
        case .dislike: isSelected ? "Clear Dislike" : "Dislike Video"
        }
    }

    var body: some View {
        let tint = reaction.tint(in: scheme)
        Button {
            let selecting = !isSelected
            if save(), selecting, !reduceMotion { activation += 1 }
        } label: {
            Group {
                let glyph = Image(systemName: reaction.symbol + (isSelected ? ".fill" : ""))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? tint : Color.primary)
                    .frame(width: 17, height: 17)
                if reduceMotion { glyph }
                else {
                    glyph.keyframeAnimator(initialValue: ReactionFrame(), trigger: activation) { icon, frame in
                        let emphasis = isSelected ? frame.emphasis : 0
                        icon.scaleEffect(1 + emphasis * (reaction == .dislike ? 0.08 : 0.25))
                            .rotationEffect(.degrees(reaction == .like ? -14 * emphasis : 0))
                            .offset(y: reaction == .favorite ? 0 : (reaction == .like ? -3 : 4) * emphasis)
                            .overlay {
                                if isSelected, frame.travel > 0, frame.travel < 1 {
                                    ReactionBurst(reaction: reaction, progress: frame.travel).foregroundStyle(tint)
                                        .allowsHitTesting(false).accessibilityHidden(true)
                                }
                            }
                    } keyframes: { _ in
                        KeyframeTrack(\.emphasis) {
                            MoveKeyframe(0)
                            CubicKeyframe(1, duration: 0.11)
                            CubicKeyframe(-0.1, duration: 0.13)
                            CubicKeyframe(0, duration: 0.08)
                        }
                        KeyframeTrack(\.travel) {
                            MoveKeyframe(0)
                            LinearKeyframe(1, duration: reaction.duration)
                        }
                    }
                }
            }
            .padding(.horizontal, VSpace.tight)
            .frame(minHeight: 26)
            .contentShape(.rect)
        }
        .buttonStyle(ReactionButtonStyle(tint: isSelected ? tint : nil))
        .help(helpText)
        .accessibilityLabel(reaction.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ReactionBurst: View {
    let reaction: VideoReaction
    let progress: Double

    var body: some View {
        let travel = 1 - pow(1 - progress, 2)
        let opacity = min(1, progress * 8, (1 - progress) * 3)
        switch reaction {
        case .favorite:
            ZStack {
                heart(size: 7, x: -14, y: -23, angle: -24, travel: travel)
                heart(size: 9, x: 1, y: -30, angle: 9, travel: travel)
                heart(size: 6, x: 14, y: -20, angle: 27, travel: travel)
            }
            .opacity(opacity)
        case .like:
            ZStack {
                ForEach([-75, -35, 8, 52], id: \.self) { angle in
                    Capsule().frame(width: 2, height: 4)
                        .offset(y: -7 - 14 * travel)
                        .rotationEffect(.degrees(Double(angle)))
                }
            }
            .opacity(opacity)
        case .dislike:
            Capsule().frame(width: 5 + 12 * travel, height: 2)
                .offset(y: 13)
                .opacity(min(1, max(0, (progress - 0.24) * 9), (1 - progress) * 3))
        }
    }

    private func heart(size: CGFloat, x: CGFloat, y: CGFloat, angle: Double, travel: Double) -> some View {
        Image(systemName: "heart.fill").font(.system(size: size))
            .scaleEffect(0.5 + 0.5 * travel)
            .rotationEffect(.degrees(angle * travel))
            .offset(x: x * travel, y: -4 + y * travel)
    }
}

private struct ReactionFrame {
    var emphasis = 0.0
    var travel = 0.0
}

private struct ReactionButtonStyle: ButtonStyle {
    let tint: Color?
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let color = tint ?? .primary
        let restingFill = tint == nil ? 0.06 : 0.12
        let border = tint == nil ? 0.18 : 0.55
        configuration.label
            .background {
                shape.fill(color.opacity(configuration.isPressed ? 0.20 : restingFill))
            }
            .overlay {
                shape.strokeBorder(color.opacity(contrast == .increased ? 0.8 : border))
                    .allowsHitTesting(false)
            }
    }
}
