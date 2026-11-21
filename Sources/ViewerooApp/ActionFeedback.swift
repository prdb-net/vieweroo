import Accessibility
import SwiftUI

struct ActionNotice: Identifiable {
    enum Kind {
        case success, favorite, error

        var symbol: String {
            switch self {
            case .success: "checkmark"
            case .favorite: "heart.fill"
            case .error: "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .success: .accentColor
            case .favorite: .pink
            case .error: .orange
            }
        }
    }

    let id = UUID()
    let text: String
    let kind: Kind
    var lifetime: TimeInterval { kind == .error ? 5 : 3.2 }
}

/// Mounted once at the window edge. The notice identity restarts its animation and timer
/// even when two successive actions produce the same message.
struct ActionNoticeView: View {
    let notice: ActionNotice
    let onExpire: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var visible = false
    @State private var elapsed = false

    var body: some View {
        HStack(spacing: VSpace.control) {
            ZStack {
                Circle().fill(notice.kind.tint.opacity(0.12))
                Image(systemName: notice.kind.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(notice.kind.tint)
                    .scaleEffect(reduceMotion || visible ? 1 : 0.62)
                    .symbolEffect(.bounce, options: .nonRepeating,
                                  value: !reduceMotion && notice.kind == .favorite && elapsed)
                if notice.kind == .favorite && !reduceMotion {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(notice.kind.tint)
                        .keyframeAnimator(initialValue: 0.0, trigger: elapsed) { spark, phase in
                            spark.opacity(1 - abs(2 * phase - 1))
                                .offset(x: 11, y: -6 - 8 * phase)
                        } keyframes: { _ in
                            LinearKeyframe(1, duration: 0.8)
                        }
                }
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
            Text(notice.text)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, VSpace.control)
        .padding(.trailing, VSpace.group)
        .padding(.vertical, VSpace.tight)
        .frame(minWidth: 176, maxWidth: 352, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background {
            if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
            else { Rectangle().fill(.regularMaterial) }
        }
        .overlay(alignment: .bottomLeading) {
            if !reduceMotion {
                Rectangle().fill(notice.kind.tint)
                    .frame(height: 2)
                    .scaleEffect(x: elapsed ? 0 : 1, y: 1, anchor: .leading)
                    .accessibilityHidden(true)
            }
        }
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            if reduceTransparency || contrast == .increased {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.primary.opacity(contrast == .increased ? 0.5 : 0.16), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .opacity(visible ? 1 : 0)
        .offset(x: visible || reduceMotion ? 0 : 16, y: visible || reduceMotion ? 0 : 8)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .task {
            withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.34)) { visible = true }
            withAnimation(.linear(duration: notice.lifetime)) { elapsed = true }
            var announcement = AttributedString(notice.text)
            announcement.accessibilitySpeechAnnouncementPriority = .low
            AccessibilityNotification.Announcement(announcement).post()
            do {
                try await Task.sleep(for: .seconds(notice.lifetime - 0.2))
                withAnimation(.easeIn(duration: 0.2)) { visible = false }
                try await Task.sleep(for: .milliseconds(200))
                onExpire()
            } catch { /* A replacement notice or the lock screen cancels this lifetime. */ }
        }
    }
}
