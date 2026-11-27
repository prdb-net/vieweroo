import SwiftUI

/// Distances in points. Keep related captions close and separate independent tasks.
enum VSpace {
    static let unit: CGFloat = 4
    static let tight: CGFloat = 8
    static let control: CGFloat = 12
    static let group: CGFloat = 16
    static let section: CGFloat = 24
    static let page: CGFloat = 32
}

struct FullWidthDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: VSpace.unit) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: VSpace.control)
                    configuration.label
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, VSpace.unit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, VSpace.control + VSpace.unit)
            }
        }
    }
}

enum ActionSymbol: String {
    case add = "plus"
    case edit = "pencil"
    case delete = "trash"
    case manage = "gearshape"
    case refresh = "arrow.clockwise"
    case search = "magnifyingglass"
}

struct IconActionButton: View {
    let symbol: ActionSymbol
    let title: String
    let targetLabel: String?
    let action: () -> Void

    init(_ symbol: ActionSymbol, _ title: String, targetLabel: String? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.targetLabel = targetLabel
        self.action = action
    }

    var body: some View {
        Button(title, systemImage: symbol.rawValue, action: action)
            .labelStyle(.iconOnly)
            .help(title)
            .accessibilityLabel(targetLabel ?? title)
    }
}
