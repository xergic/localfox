import SwiftUI

/// Ported from Portfox, whose card and row chrome this matches exactly.
struct PreferencesSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var launchAtLogin = LaunchAtLogin()

    /// `ImageRenderer` lays out in a single pass and never draws scroll content.
    var scrolls = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.separator)
            Scrollable(scrolls: scrolls) { sections }
            Divider().overlay(Theme.separator)
            footer
        }
        .frame(width: 560)
        .background(Theme.background)
        .themedSurface(state.appearance.colorScheme)
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .fill(Theme.card)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("Localfox Preferences")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text("Configure appearance, startup and sharing")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }

            Spacer()

            IconButton(symbol: "xmark", help: "Close") { dismiss() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 16) {
            appearanceSection
            generalSection
            sharingSection
        }
        .padding(14)
    }

    private var sharingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("SHARING", symbol: "antenna.radiowaves.left.and.right")
            PreferencesCard {
                @Bindable var sharing = state.sharing
                PreferenceRow(
                    title: "Rewrite the Host header",
                    subtitle: "Needed by Vite and Next, wrong for Django ALLOWED_HOSTS and OAuth"
                ) {
                    Toggle("", isOn: $sharing.rewritesHostHeader)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                }
                CardDivider()
                PreferenceRow(
                    title: "Warn before sharing",
                    subtitle: "Ask what a public tunnel exposes each time one is opened"
                ) {
                    Toggle("", isOn: Binding(
                        get: { !sharing.warningAccepted },
                        set: { sharing.warningAccepted = !$0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("APPEARANCE", symbol: "paintbrush")
            PreferencesCard {
                @Bindable var appearance = state.appearance
                PreferenceRow(
                    title: "Appearance",
                    subtitle: "Follow the system theme, or pin Localfox to light or dark"
                ) {
                    SegmentedControl(
                        selection: $appearance.preference,
                        options: AppAppearance.allCases.map { ($0, $0.displayName) }
                    )
                }
            }
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("GENERAL", symbol: "gearshape")
            PreferencesCard {
                PreferenceRow(
                    title: "Launch at login",
                    subtitle: "Start Localfox automatically when you log in"
                ) {
                    Toggle("", isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.set($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                }
                if let error = launchAtLogin.lastError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            ActionButton(title: "Done") { dismiss() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func sectionLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(title)
                .font(.lfSection)
                .kerning(0.8)
        }
        .foregroundStyle(Theme.tertiaryText)
        .padding(.horizontal, 2)
    }
}

private struct PreferencesCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .fill(Theme.card)
            )
    }
}

private struct PreferenceRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Hand-drawn rather than `Picker(.segmented)`, which renders as an empty block
/// under `ImageRenderer` and ignores the palette.
private struct SegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.mono(11, .medium))
                        .foregroundStyle(option.value == selection ? Theme.onAccent : Theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(option.value == selection ? Theme.accent : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.pill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
        )
    }
}
