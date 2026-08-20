import AppKit
import LocalfoxKit
import SwiftUI

/// The main window. Chrome only; everything renderable lives in `DashboardContent`.
struct DashboardView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        DashboardContent()
            .background(Theme.background)
            .environment(\.colorScheme, .dark)
            .background(WindowAccessor(onAttach: attach))
    }

    private func attach(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // The window is drawn dark by SwiftUI, but its own background flashes
        // light during a resize without this.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.background)
        window.isRestorable = false
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
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Image(.menuBarFox)
                .renderingMode(.template)
                .resizable()
                .frame(width: 20, height: 20)
                .foregroundStyle(Theme.accent)
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
                            ProjectSection(project: project, selection: $selection)
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
                    EnvironmentCard()
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
                }
            }
        }
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
        state.helper.canServe ? Theme.success : Theme.accent
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
        state.trust.isUsable ? Theme.success : Theme.accent
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

private struct EnvironmentCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        DetailCard(title: "COMMAND ENVIRONMENT", symbol: "terminal") {
            if let environment = state.shellEnvironment {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledRow(label: "Shell", value: environment.shell)
                    CardDivider()
                    // Shown because "command not found" is the single most common
                    // failure, and seeing the PATH turns it into self diagnosis.
                    Text("PATH")
                        .font(.lfSection)
                        .kerning(0.8)
                        .foregroundStyle(Theme.tertiaryText)
                    Text(environment.pathEntries.joined(separator: "\n"))
                        .font(.lfSubtitle)
                        .foregroundStyle(Theme.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
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
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9))
                }
                Text(title).kerning(0.8)
            }
            .font(.lfSection)
            .foregroundStyle(Theme.tertiaryText)

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
