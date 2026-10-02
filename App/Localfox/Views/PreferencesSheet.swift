import SwiftUI

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
                .fill(Theme.accent)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("Localfox preferences")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text("Configure appearance, startup and sharing")
                    .font(.lfDetail)
                    .foregroundStyle(Theme.secondaryText)
            }

            Spacer()

            IconButton(
                symbol: "xmark",
                help: "Close",
                frameSize: Theme.Metrics.headerButtonSize,
                filled: true
            ) { dismiss() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 14) {
            appearanceSection
            generalSection
            proxySection
            sharingSection
        }
        .padding(16)
    }

    private var proxySection: some View {
        DetailCard(title: "Proxy", symbol: "arrow.left.arrow.right") {
            PreferenceRow(
                title: "Record requests",
                subtitle: "Method, URL, status and duration. Headers and cookies are never recorded"
            ) {
                Toggle("", isOn: Binding(
                    get: { state.preferences.recordsRequests },
                    // The proxy only learns about this through a route sync,
                    // so the write and the sync are one action.
                    set: { enabled in
                        state.preferences.recordsRequests = enabled
                        Task { await state.syncProxy() }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
            }
        }
    }

    private var sharingSection: some View {
        DetailCard(title: "Sharing", symbol: "antenna.radiowaves.left.and.right") {
            @Bindable var preferences = state.preferences
            VStack(alignment: .leading, spacing: Theme.Metrics.cardPaddingV) {
                PreferenceRow(
                    title: "Rewrite the Host header",
                    subtitle: "Needed by Vite and Next, wrong for Django ALLOWED_HOSTS and OAuth"
                ) {
                    Toggle("", isOn: $preferences.rewritesHostHeader)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                }
                CardDivider()
                PreferenceRow(
                    title: "Warn before sharing",
                    subtitle: "Ask what a public tunnel exposes each time one is opened"
                ) {
                    Toggle("", isOn: Binding(
                        get: { !preferences.warningAccepted },
                        set: { preferences.warningAccepted = !$0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private var appearanceSection: some View {
        DetailCard(title: "Appearance", symbol: "paintbrush") {
            @Bindable var appearance = state.appearance
            PreferenceRow(
                title: "Theme",
                subtitle: "Follow the system theme, or pin Localfox to light or dark"
            ) {
                SegmentedControl(
                    selection: $appearance.preference,
                    options: AppAppearance.allCases.map { ($0, $0.displayName) }
                )
            }
        }
    }

    private var generalSection: some View {
        DetailCard(title: "General", symbol: "gearshape") {
            VStack(alignment: .leading, spacing: Theme.Metrics.cardPaddingV) {
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
                        .font(.lfBadge)
                        .foregroundStyle(Theme.danger)
                }
                CardDivider()
                PreferenceRow(
                    title: "Share anonymous usage data",
                    subtitle: "Never includes domains, paths or ports"
                ) {
                    Toggle("", isOn: Binding(
                        get: { state.preferences.sharesUsageData },
                        set: { enabled in
                            state.preferences.sharesUsageData = enabled
                            Telemetry.setEnabled(enabled)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            ActionButton(title: "Done", symbol: "checkmark", isPrimary: true) { dismiss() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
                    .font(.lfDetailStrong)
                    .foregroundStyle(Theme.primaryText)
                if let subtitle {
                    Text(subtitle)
                        .font(.lfBadge)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
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
                        .font(.lfBadge)
                        .foregroundStyle(option.value == selection ? Theme.onAccent : Theme.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(height: Theme.Metrics.controlHeight - 8)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Metrics.badgeRadius + 1, style: .continuous)
                                .fill(option.value == selection ? Theme.accent : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(ControlBackground(fill: Theme.pill))
    }
}
