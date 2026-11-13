import SwiftUI

struct PreferencesCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    /// Clipped, so a row's square hover fill follows the card's rounded corners
    /// and the hairline is drawn over it rather than under.
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.separator, lineWidth: 1))
    }
}

/// A titled group of rows in a card, the preferences twin of `DetailCard`.
struct PreferencesSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .groupLabelStyle()
                .padding(.leading, 2)
            PreferencesCard(content: content)
        }
    }
}

struct PreferenceDivider: View {
    var body: some View {
        Divider().overlay(Theme.separator)
            .padding(.horizontal, Theme.Metrics.rowPaddingH)
    }
}

struct PreferenceRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                if let subtitle {
                    Text(subtitle)
                        .font(.lfCaption)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
                .fixedSize()
                .accessibilityLabel(title)
        }
        .padding(.horizontal, Theme.Metrics.rowPaddingH)
        .padding(.vertical, 12)
    }
}

/// Hand-drawn rather than `Picker(.segmented)`, which renders as an empty block
/// under `ImageRenderer` and ignores the palette.
struct SegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.lfCaption.weight(.medium))
                        .foregroundStyle(option.value == selection ? Theme.onAccent : Theme.secondaryText)
                        .padding(.horizontal, 9)
                        .frame(height: Theme.Metrics.controlHeightSmall - 4)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius - 2, style: .continuous)
                                .fill(option.value == selection ? Theme.accent : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(ControlBackground(fill: Theme.pill))
    }
}
