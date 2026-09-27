import AppKit
import LocalfoxKit
import SwiftUI

/// The main window. Chrome only; everything renderable lives in `DashboardContent`.
struct DashboardView: View {
    @Environment(AppState.self) private var state
    @State private var window: NSWindow?

    var body: some View {
        DashboardContent()
            .background(Theme.background)
            .themedSurface(state.appearance.colorScheme)
            .background(WindowAccessor(onAttach: attach))
            // `attach` runs once per window, so a preference flipped while the
            // dashboard is open would leave the AppKit chrome on the old theme.
            .onChange(of: state.appearance.colorScheme) {
                if let window { applyAppearance(to: window) }
            }
    }

    private func attach(_ window: NSWindow) {
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.isRestorable = false
        applyAppearance(to: window)
    }

    /// The window is drawn by SwiftUI, but its own background flashes the other
    /// theme during a resize without this.
    private func applyAppearance(to window: NSWindow) {
        window.appearance = state.appearance.nsAppearance
        window.backgroundColor = NSColor(Theme.background)
    }
}

/// Deliberately free of `NavigationSplitView`, `List`, `.toolbar` and
/// `.searchable`, all of which need a hosting window and render blank under
/// `ImageRenderer`, which is how the design is reviewed.
struct DashboardContent: View {
    @Environment(AppState.self) private var state

    var scrolls = true
    @State private var selection: UUID?
    @State private var isAddingProject = false

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            topBar
            Divider().overlay(Theme.separator)
            HStack(spacing: 0) {
                sidebar
                    .frame(width: Theme.Metrics.sidebarWidth)
                Divider().overlay(Theme.separator)
                detail
            }
        }
        .sheet(isPresented: $isAddingProject) {
            AddProjectSheet().environment(state)
        }
        .sheet(isPresented: $state.presentsPreferences) {
            PreferencesSheet().environment(state)
        }
        // The helper is approved in System Settings, outside this process, so
        // returning to Localfox is the only signal that anything changed.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            Task { await state.refreshSetup() }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("Localfox")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.primaryText)

            Spacer(minLength: 16)

            StatusPill(
                text: "\(state.runningCount) running",
                tint: state.runningCount > 0 ? Theme.success : nil
            )

            IconButton(
                symbol: "plus",
                help: "Add a project",
                symbolSize: Theme.Metrics.dashboardSymbolSize,
                frameSize: Theme.Metrics.dashboardButtonSize
            ) { isAddingProject = true }

            IconButton(
                symbol: "gearshape",
                help: "Preferences",
                symbolSize: Theme.Metrics.dashboardSymbolSize,
                frameSize: Theme.Metrics.dashboardButtonSize
            ) { state.presentsPreferences = true }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if state.projects.isEmpty {
                VStack(spacing: 10) {
                    EmptyStateView(
                        symbol: "folder.badge.plus",
                        message: "No projects yet",
                        hint: "Add a project directory to get started"
                    )
                    ActionButton(title: "Add Project", symbol: "plus", isPrimary: true) {
                        isAddingProject = true
                    }
                }
            } else {
                // scrollDisabled is not enough: ImageRenderer lays out in one
                // pass and never draws a ScrollView's content at all, which is
                // why the snapshot came out empty.
                Scrollable(scrolls: scrolls) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(state.projects) { project in
                            ProjectSection(
                                project: project,
                                selection: $selection,
                                showsHoverActions: false,
                                showsRemove: true,
                                showsEdit: true
                            )
                        }
                    }
                    .padding(10)
                }
            }
            Spacer(minLength: 0)
            Divider().overlay(Theme.separator)
            HStack {
                Text("\(state.projects.count) project\(state.projects.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        Scrollable(scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 16) {
                if let error = state.lastError {
                    ErrorBanner(message: error) { state.clearError() }
                }
                if let service = selectedService {
                    ServiceDetailPane(service: service, scrolls: scrolls)
                } else {
                    SetupCard()
                    DiagnosticsCard()
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var selectedService: Service? {
        guard let selection else { return nil }
        for project in state.projects {
            if let service = project.service(id: selection) { return service }
        }
        return nil
    }
}

/// The setup wall, which is the whole interface until HTTPS actually works.
private struct SetupCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        DetailCard(title: "LOCAL HTTPS", symbol: "lock.shield") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledRow(label: "Helper", value: helperText, tint: helperTint)
                CardDivider()
                LabeledRow(label: "Certificate", value: trustText, tint: trustTint)

                if state.needsSetup {
                    Text(explanation)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                    if let blocker = HelperIdentity.registrationBlocker() {
                        CardDivider()
                        Label(blocker.message, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    actions
                }
                if let fingerprint = state.trust.identity?.fingerprint {
                    CardDivider()
                    LabeledRow(label: "Fingerprint", value: Self.grouped(fingerprint))
                }
            }
        }
    }

    /// One action per state, matching the remedy the state machine reports.
    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            switch state.helper {
            case .notRegistered:
                ActionButton(title: "Install Helper", symbol: "arrow.down.circle", isPrimary: true) {
                    Task { await state.installHelper() }
                }
            case .requiresApproval:
                ActionButton(title: "Approve in System Settings", symbol: "gearshape", isPrimary: true) {
                    state.openHelperApproval()
                }
            case .enabledButUnreachable, .versionMismatch:
                ActionButton(title: "Reinstall Helper", symbol: "arrow.clockwise", isPrimary: true) {
                    Task { await state.reinstallHelper() }
                }
            case .ready:
                switch state.trust.remedy {
                case .install:
                    ActionButton(title: "Trust Certificate", symbol: "checkmark.seal", isPrimary: true) {
                        Task { await state.installCertificate() }
                    }
                case .reinstall, .repair, .regenerate:
                    ActionButton(title: "Repair Certificate", symbol: "wrench", isPrimary: true) {
                        Task { await state.repairCertificate() }
                    }
                case .startProxy:
                    Text("Start a service to create the certificate authority.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                case .none:
                    EmptyView()
                }
            }

            if state.trust.identity != nil {
                ActionButton(title: "Remove", tint: Theme.danger) {
                    Task { await state.removeCertificate() }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    /// Grouped in fours, because a user comparing this against Keychain Access
    /// is reading it a character at a time.
    static func grouped(_ fingerprint: String) -> String {
        stride(from: 0, to: fingerprint.count, by: 4).map {
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: $0)
            let end = fingerprint.index(start, offsetBy: 4, limitedBy: fingerprint.endIndex)
                ?? fingerprint.endIndex
            return String(fingerprint[start..<end]).uppercased()
        }.joined(separator: " ")
    }

    private var helperText: String {
        switch state.helper {
        case .notRegistered: "Not installed"
        case .requiresApproval: "Waiting for approval"
        case .enabledButUnreachable: "Not responding"
        case let .versionMismatch(expected, found): "Version \(found), expected \(expected)"
        case let .ready(version, running): "Ready \(version)\(running ? ", proxy up" : "")"
        }
    }

    private var helperTint: Color {
        state.helper.canServe ? Theme.success : Theme.warning
    }

    private var trustText: String {
        switch state.trust {
        case .notGenerated: "Not created yet"
        case .notInstalled: "Not installed"
        case .installedNotTrusted: "Installed but not trusted"
        case .stale: "An older certificate is installed"
        case .expired: "Expired"
        case .trusted: "Trusted"
        }
    }

    private var trustTint: Color {
        state.trust.isUsable ? Theme.success : Theme.warning
    }

    /// Localfox has no unprivileged fallback, so this explains the wall rather
    /// than quietly serving on another port.
    private var explanation: String {
        if !state.helper.canServe {
            return """
            Localfox serves on ports 80 and 443, which macOS reserves for root. \
            Its helper runs as a background service you approve once in System \
            Settings under Login Items & Extensions.
            """
        }
        return """
        Localfox issues certificates from its own local authority. Trusting it \
        once is what makes https:// work without a browser warning.
        """
    }
}

/// Collapsed by default. The PATH answers exactly one question, "why was my
/// command not found", and the failure that raises it now prints the PATH itself,
/// so this is the second place to look rather than the first thing the window shows.
private struct DiagnosticsCard: View {
    @Environment(AppState.self) private var state
    @State private var isExpanded = false

    var body: some View {
        DetailCard(title: "DIAGNOSTICS", symbol: "stethoscope", isExpanded: $isExpanded) {
            if let environment = state.shellEnvironment {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledRow(label: "Shell", value: environment.shell)
                    CardDivider()
                    PathList(entries: environment.pathEntries)
                }
            } else {
                Text("Reading your login shell…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

/// Bordered card with an uppercase title, matching the house style.
struct DetailCard<Content: View>: View {
    let title: String
    var symbol: String?
    /// When bound, the title row becomes a disclosure and the card collapses to
    /// its header, for a panel that is only wanted once something has gone wrong.
    var isExpanded: Binding<Bool>?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let isExpanded {
                Button { isExpanded.wrappedValue.toggle() } label: {
                    titleRow(isOpen: isExpanded.wrappedValue)
                }
                .buttonStyle(.plain)
            } else {
                titleRow(isOpen: nil)
            }

            if isExpanded?.wrappedValue ?? true {
                cardBody
            }
        }
    }

    private func titleRow(isOpen: Bool?) -> some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9))
            }
            Text(title).kerning(0.8)
            if let isOpen {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            Spacer(minLength: 0)
        }
        .font(.lfSection)
        .foregroundStyle(Theme.tertiaryText)
        .contentShape(Rectangle())
    }

    private var cardBody: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .fill(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
            )
    }
}

struct LabeledRow: View {
    let label: String
    let value: String
    var tint: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 12)
            Text(value)
                .font(.lfSubtitle)
                .foregroundStyle(tint ?? Theme.primaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}

struct CardDivider: View {
    var body: some View {
        Divider().overlay(Theme.separator)
    }
}

/// Wraps content in a `ScrollView` only when it is going to be drawn on screen.
///
/// `ImageRenderer` lays out in a single pass and never draws scroll content, so
/// a snapshot of a scrollable pane comes out blank.
struct Scrollable<Content: View>: View {
    var scrolls = true
    @ViewBuilder let content: Content

    var body: some View {
        if scrolls {
            ScrollView { content }
        } else {
            content
        }
    }
}
