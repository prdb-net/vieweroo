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

enum ActionSymbol: String {
    case add = "plus"
    case edit = "pencil"
    case delete = "trash"
    case remove = "minus"
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
