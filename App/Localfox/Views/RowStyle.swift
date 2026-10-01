import SwiftUI

/// The popover draws each service as its own card under a bare heading; the
/// dashboard sidebar keeps compact rows. An environment value rather than a
/// parameter, so `ProjectSection` and `ServiceRow` pick it up without threading
/// it through every initializer.
enum RowStyle {
    case compact
    case card

    var horizontalPadding: CGFloat { self == .card ? Theme.Metrics.rowPaddingH : 10 }
    var verticalPadding: CGFloat { self == .card ? Theme.Metrics.rowPaddingV : 7 }
    var radius: CGFloat { self == .card ? Theme.Metrics.cardRadius : Theme.Metrics.rowRadius }
    var restFill: Color { self == .card ? Theme.card : .clear }
    var restBorder: Color { self == .card ? Theme.separator : .clear }
    var hoverBorder: Color { self == .card ? Theme.border : .clear }

    var sectionSpacing: CGFloat { self == .card ? 6 : 2 }
    var rowIndent: CGFloat { self == .card ? 0 : 7 }
    /// A card heading above cards would read as one more row, so the popover
    /// drops the fill and lets the heading sit on the background.
    var headerFill: Color { self == .card ? .clear : Theme.card }
    var headerHorizontalPadding: CGFloat { self == .card ? 4 : 10 }
    var headerVerticalPadding: CGFloat { self == .card ? 4 : 8 }
    var headerActionsInset: CGFloat { self == .card ? horizontalPadding : 8 }
    /// The ring that cuts the running dot out of the project icon, in whatever
    /// the heading sits on.
    var dotRing: Color { self == .card ? Theme.background : Theme.card }
}

extension EnvironmentValues {
    @Entry var rowStyle: RowStyle = .compact
}
