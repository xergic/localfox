import SwiftUI

/// Categories stay independent of the live controls so navigation also renders in snapshots.
enum PreferencesCategory: String, CaseIterable {
    case general
    case appearance
    case proxy
    case sharing

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .proxy: "Proxy"
        case .sharing: "Sharing"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .proxy: "arrow.triangle.branch"
        case .sharing: "network"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Startup, shortcuts, notifications and updates"
        case .appearance: "Choose how Localfox and its service lists look"
        case .proxy: "Control request recording for your local services"
        case .sharing: "Configure how services are shared with public tunnels"
        }
    }
}

struct PreferencesSidebar: View {
    @Binding var selection: PreferencesCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(PreferencesCategory.allCases, id: \.self) { category in
                PreferencesNavigationItem(
                    title: category.title,
                    symbol: category.symbol,
                    isSelected: selection == category
                ) { selection = category }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 160)
        .frame(maxHeight: .infinity)
        .background(Theme.card.opacity(0.45))
        .accessibilityLabel("Settings categories")
    }
}

private struct PreferencesNavigationItem: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.accentText : Theme.secondaryText)
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(
                RoundedRectangle.row.fill(isSelected ? Theme.selectedRow : isHovering ? Theme.cardHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct PreferencesPageHeading: View {
    let category: PreferencesCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(category.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text(category.subtitle)
                .font(.lfCaption)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }
}
