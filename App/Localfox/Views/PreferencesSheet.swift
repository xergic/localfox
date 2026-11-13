import KeyboardShortcuts
import SwiftUI

struct PreferencesSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var launchAtLogin = LaunchAtLogin()
    @State private var category: PreferencesCategory

    /// `ImageRenderer` lays out in a single pass and never draws scroll content.
    var scrolls = true

    init(category: PreferencesCategory = .general, scrolls: Bool = true) {
        _category = State(initialValue: category)
        self.scrolls = scrolls
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.separator)
            HStack(spacing: 0) {
                PreferencesSidebar(selection: $category)
                Divider().overlay(Theme.separator)
                VStack(alignment: .leading, spacing: 0) {
                    PreferencesPageHeading(category: category)
                    Scrollable(scrolls: scrolls) { sections }
                        .id(category)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: 480)
            Divider().overlay(Theme.separator)
            footer
        }
        .frame(width: 720)
        .background(Theme.background)
        .themedSurface(state.appearance.colorScheme)
    }

    private var header: some View {
        HStack(spacing: 8) {
            RoundedRectangle.row
                .fill(Theme.accent)
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                )

            Text("Localfox preferences")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.primaryText)

            Spacer()

            IconButton(
                symbol: "xmark",
                help: "Close",
                frameSize: Theme.Metrics.headerButtonSize,
                filled: true
            ) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch category {
            case .general: generalSection
            case .appearance: appearanceSection
            case .proxy: proxySection
            case .sharing: sharingSection
            }
        }
        .padding(20)
    }

    private var proxySection: some View {
        PreferencesSection(title: "Request logging") {
            PreferenceRow(
                title: "Record requests",
                subtitle: "Method, URL, status and duration. Headers and cookies are never recorded"
            ) {
                PreferenceCheckbox(isOn: Binding(
                    get: { state.preferences.recordsRequests },
                    // The proxy only learns about this through a route sync,
                    // so the write and the sync are one action.
                    set: { enabled in
                        state.preferences.recordsRequests = enabled
                        Task { await state.syncProxy() }
                    }
                ))
            }
        }
    }

    private var sharingSection: some View {
        PreferencesSection(title: "Public tunnels") {
            @Bindable var preferences = state.preferences
            VStack(alignment: .leading, spacing: 0) {
                PreferenceRow(
                    title: "Rewrite the Host header",
                    subtitle: "Helps Vite and Next.js. Turn off for Django host checks or OAuth."
                ) {
                    PreferenceCheckbox(isOn: $preferences.rewritesHostHeader)
                }
                PreferenceDivider()
                PreferenceRow(
                    title: "Warn before sharing",
                    subtitle: "Ask what a public tunnel exposes each time one is opened"
                ) {
                    PreferenceCheckbox(isOn: Binding(
                        get: { !preferences.warningAccepted },
                        set: { preferences.warningAccepted = !$0 }
                    ))
                }
            }
        }
    }

    private var appearanceSection: some View {
        PreferencesSection(title: "Theme and service list") {
            @Bindable var appearance = state.appearance
            @Bindable var preferences = state.preferences
            VStack(alignment: .leading, spacing: 0) {
                PreferenceRow(
                    title: "Theme",
                    subtitle: "Use your Mac’s appearance or choose your own"
                ) {
                    SegmentedControl(
                        selection: $appearance.preference,
                        options: AppAppearance.allCases.map { ($0, $0.displayName) }
                    )
                }
                PreferenceDivider()
                PreferenceRow(
                    title: "Compact rows",
                    subtitle: "One line per service, so more fit before the list scrolls"
                ) {
                    PreferenceCheckbox(isOn: $preferences.compactRows)
                }
            }
        }
    }

    private var generalSection: some View {
        PreferencesSection(title: "Startup and behavior") {
            VStack(alignment: .leading, spacing: 0) {
                PreferenceRow(
                    title: "Launch at login",
                    subtitle: "Start Localfox automatically when you log in"
                ) {
                    PreferenceCheckbox(isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.set($0) }
                    ))
                }
                if let error = launchAtLogin.lastError {
                    Text(error)
                        .font(.lfCaption)
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, Theme.Metrics.rowPaddingH)
                        .padding(.bottom, 12)
                }
                if Updater.shared.isAvailable {
                    PreferenceDivider()
                    updateRows
                }
                PreferenceDivider()
                PreferenceRow(
                    title: "Open Localfox",
                    subtitle: "A shortcut that opens the menu from any app"
                ) {
                    KeyboardShortcuts.Recorder(for: .togglePopover)
                        .frame(width: 140)
                }
                PreferenceDivider()
                PreferenceRow(
                    title: "Service notifications",
                    subtitle: "Notify when a service is ready or stops unexpectedly"
                ) {
                    PreferenceCheckbox(isOn: Binding(
                        get: { state.preferences.notifiesCrashes },
                        set: { state.preferences.notifiesCrashes = $0 }
                    ))
                }
                PreferenceDivider()
                PreferenceRow(
                    title: "Share anonymous usage data",
                    subtitle: "Never includes domains, paths or ports"
                ) {
                    PreferenceCheckbox(isOn: Binding(
                        get: { state.preferences.sharesUsageData },
                        set: { enabled in
                            state.preferences.sharesUsageData = enabled
                            Telemetry.setEnabled(enabled)
                        }
                    ))
                }
            }
        }
    }

    @ViewBuilder private var updateRows: some View {
        @Bindable var updater = Updater.shared
        PreferenceRow(
            title: "Check for updates automatically",
            subtitle: "Look for a new version once a day"
        ) {
            PreferenceCheckbox(isOn: $updater.automaticallyChecks)
        }
        PreferenceDivider()
        PreferenceRow(title: "Check for updates") {
            ActionButton(title: "Check Now", symbol: "arrow.down.circle") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }

    private var footer: some View {
        HStack {
            Text("Changes are saved automatically")
                .font(.lfCaption)
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            ActionButton(title: "Done", symbol: "checkmark", isPrimary: true) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}
