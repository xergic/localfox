import LocalfoxKit
import SwiftUI

/// The menu bar popover: runtime status and quick actions only.
struct MenuView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var scrolls = true
    var forcesHover = false

    @State private var listHeight: CGFloat = Theme.Metrics.maximumListHeight
    @State private var isRefreshing = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.separator)

            if state.needsSetup {
                setupWall
            } else if state.projects.isEmpty {
                EmptyStateView(
                    symbol: "folder.badge.plus",
                    message: "No projects yet",
                    hint: "Add one from the Localfox window"
                )
            } else {
                list
            }

            Divider().overlay(Theme.separator)
            footer
        }
        .frame(width: Theme.Metrics.popoverWidth)
        .background(Theme.background)
        .themedSurface(state.appearance.colorScheme)
    }

    private var header: some View {
        AppHeader(subtitle: "Local HTTPS domains", stacksSummary: true) {
            if !state.needsSetup { ServiceSummary() }
        } trailing: {
            // The helper is approved in System Settings, outside this process,
            // and nothing else re-reads it while only the popover is open.
            IconButton(
                symbol: "arrow.trianglehead.2.clockwise",
                help: "Check setup again",
                symbolSize: Theme.Metrics.headerSymbolSize,
                frameSize: Theme.Metrics.headerButtonSize,
                filled: true,
                spins: isRefreshing
            ) {
                guard !isRefreshing else { return }
                isRefreshing = true
                Task {
                    await state.refreshSetup()
                    isRefreshing = false
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// Localfox has no unprivileged fallback, so an unapproved helper blocks the
    /// list rather than quietly serving on a different port.
    private var setupWall: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 24))
                .foregroundStyle(Theme.accentText)
                .padding(.bottom, 2)
            Text("Finish setting up local HTTPS")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text(setupReason)
                .font(.lfDetail)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ActionButton(title: "Open Setup", symbol: "arrow.up.forward.app", isPrimary: true) {
                WindowPresenter.showDashboard(openWindow)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 28)
    }

    private var setupReason: String {
        if !state.helper.canServe {
            return "Localfox needs its helper approved before it can serve ports 80 and 443."
        }
        return "Localfox needs its certificate authority trusted before HTTPS will work."
    }

    private var list: some View {
        MeasuredScrollView(height: $listHeight, maximum: Theme.Metrics.maximumListHeight, scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 12) {
                if let error = state.lastError {
                    ErrorBanner(message: error) { state.clearError() }
                }
                ForEach(state.projects) { project in
                    ProjectSection(project: project, forcesHover: forcesHover)
                }
            }
            .padding(12)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            FooterButton(symbol: "macwindow", title: "Localfox") {
                WindowPresenter.showDashboard(openWindow)
            }
            FooterButton(symbol: "slider.horizontal.3", title: "Settings…") {
                // Requested before the window has laid out, which is why the flag
                // lives on `AppState` rather than in the dashboard's own state.
                WindowPresenter.showDashboard(openWindow)
                state.presentsPreferences = true
            }
            Spacer(minLength: 0)
            Text(AppInfo.versionLabel)
                .font(.lfVersion)
                .foregroundStyle(Theme.tertiaryText)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct FooterButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 12))
            .foregroundStyle(isHovering ? Theme.primaryText : Theme.secondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A project heading and its services.
struct ProjectSection: View {
    let project: Project
    var forcesHover = false
    /// Bound only by the dashboard. The popover has nowhere to show a detail
    /// pane, so it leaves this nil and rows stay unselectable.
    var selection: Binding<UUID?>?
    var showsHoverActions = true
    /// Dashboard only. The popover is a launcher, and a destructive action one
    /// mis-click from Start all does not belong in a window that dismisses itself.
    var showsRemove = false
    /// Dashboard only, for a second reason: a sheet presented from the popover
    /// attaches to a window that closes when it resigns key, which loses the
    /// edit mid-typing.
    var showsEdit = false

    @Environment(AppState.self) private var state
    @State private var isConfirmingRemove = false
    @State private var isEditing = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                ServiceIconView(
                    type: project.services.first?.framework ?? .unknown,
                    projectIconPath: state.iconPath(for: project),
                    size: Theme.Metrics.projectIcon
                )
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(anyRunning ? Theme.success : Theme.tertiaryText)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(Theme.background, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
                Text(project.name)
                    .font(.lfProject)
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize()
                // Hidden rather than squeezed while the actions are up. Reserving
                // room for four buttons the way `ServiceRow` does leaves a 300pt
                // sidebar rendering `~/Work/Wishfox/wishfox-api` as `…i`, and the
                // path is worth more at rest than under the pointer.
                Text(project.displayPath)
                    .font(.lfSubtitle)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(project.displayPath)
                    .opacity(showsActions ? 0 : 1)
                Spacer(minLength: 0)
            }
            // Bare on the background, because a card heading above cards would
            // read as one more row.
            .padding(4)
            .overlay(alignment: .trailing) {
                if showsActions { headerActions }
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }

            ForEach(project.services) { service in
                ServiceRow(
                    service: service,
                    forcesHover: forcesHover,
                    selection: selection,
                    showsHoverActions: showsHoverActions
                )
            }
        }
        .sheet(isPresented: $isEditing) {
            EditProjectSheet(project: project).environment(state)
        }
        .alert("Remove \(project.name)?", isPresented: $isConfirmingRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let selected = selection?.wrappedValue, project.service(id: selected) != nil {
                    selection?.wrappedValue = nil
                }
                Task { await state.remove(projectID: project.id) }
            }
        } message: {
            Text("Localfox forgets this project and its services. Nothing on disk changes.")
        }
    }

    private var headerActions: some View {
        HStack(spacing: 1) {
            if anyRunning {
                IconButton(symbol: "stop.fill", tint: Theme.danger, help: "Stop all") {
                    Task { await state.stopAll(project) }
                }
            } else {
                IconButton(symbol: "play.fill", tint: Theme.success, help: "Start all") {
                    Task { await state.startAll(project) }
                }
            }
            IconButton(symbol: "folder", help: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.directory])
            }
            if showsEdit {
                IconButton(symbol: "pencil", help: "Edit project") { isEditing = true }
            }
            if showsRemove {
                IconButton(symbol: "trash", help: "Remove project") { isConfirmingRemove = true }
            }
        }
        .padding(.trailing, Theme.Metrics.rowPaddingH)
    }

    private var showsActions: Bool { isHovering || forcesHover }

    private var anyRunning: Bool {
        project.services.contains { state.status(of: $0).isRunning }
    }
}

struct ServiceRow: View {
    let service: Service
    var forcesHover = false
    var selection: Binding<UUID?>?
    /// The dashboard sidebar shows its actions in the detail pane instead, which
    /// buys back the reserved width. Without that, `api.wishfox.localhost` does
    /// not fit in three hundred points and truncates to `api.wishfox.local…`,
    /// hiding the one thing the row exists to show.
    var showsHoverActions = true

    @Environment(AppState.self) private var state
    @State private var isHovering = false
    @State private var confirmsShare = false

    private var isSelected: Bool { selection?.wrappedValue == service.id }
    private var showsActions: Bool { showsHoverActions && (isHovering || forcesHover) }

    var body: some View {
        HStack(spacing: 10) {
            ServiceIconView(type: service.framework)
            VStack(alignment: .leading, spacing: 1) {
                // Beside the name, not the domain. A service name is a word, and
                // beside the domain the badge truncated the one fact the row shows.
                // A public tunnel the user has forgotten is the failure that
                // matters here, so it is marked at rest and not behind hover.
                HStack(spacing: 6) {
                    Text(service.name)
                        .font(.lfName)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    if let shareLabel {
                        TintedBadge(text: shareLabel, tint: shareTint)
                            .fixedSize()
                            .help(shareHelp)
                    }
                }
                Text(service.domain.value)
                    .font(.lfSubtitle)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    // Tail, not middle. The subdomain is what distinguishes
                    // api.wishfox.localhost from admin.wishfox.localhost, and
                    // middle truncation ate exactly that: "wishfo…calhost".
                    .truncationMode(.tail)
                    .help(service.domain.value)
            }
            .layoutPriority(1)
            // Reserved even at rest, so revealing the actions never
            // re-truncates the text or shifts the row under the pointer.
            .padding(.trailing, reservedActionWidth)

            Spacer(minLength: 0)

            PortPill(status: status)
        }
        .padding(.horizontal, Theme.Metrics.rowPaddingH)
        .padding(.vertical, Theme.Metrics.rowPaddingV)
        .overlay(alignment: .trailing) {
            if showsActions {
                HStack(spacing: 1) {
                    if status.isRunning {
                        IconButton(symbol: "stop.fill", tint: Theme.danger, help: "Stop") {
                            Task { await state.stop(service) }
                        }
                        IconButton(symbol: "arrow.clockwise", help: "Restart") {
                            Task { await state.restart(service) }
                        }
                    } else if !status.isTransitioning {
                        IconButton(symbol: "play.fill", tint: Theme.success, help: "Start") {
                            Task { await state.start(service) }
                        }
                    }
                    if state.url(for: service) != nil {
                        IconButton(symbol: "globe", help: "Open in browser") {
                            if let url = state.url(for: service) { NSWorkspace.shared.open(url) }
                        }
                    }
                    IconButton(symbol: "folder", help: "Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([service.directory])
                    }
                }
                .padding(3)
                .background(ControlBackground(fill: Theme.cardHover))
                .padding(.trailing, Theme.Metrics.portPillWidth + Theme.Metrics.rowPaddingH + 4)
            }
        }
        .background(CardBackground(fill: rowFill, border: borderColor))
        .contentShape(Rectangle())
        .onTapGesture { selection?.wrappedValue = service.id }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .contextMenu { menu }
        .confirmationDialog(
            "Share \(service.name) on the public internet?",
            isPresented: $confirmsShare,
            titleVisibility: .visible
        ) {
            Button("Share Publicly", role: .destructive) {
                state.preferences.warningAccepted = true
                Task { await state.share(service) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SharingWarning.exposure(.quick))
        }
        .opacity(status.isTransitioning ? 0.5 : 1)
    }

    private var isHighlighted: Bool { isHovering || showsActions }

    private var rowFill: Color {
        if isSelected { return Theme.selectedRow }
        return isHighlighted ? Theme.cardHover : Theme.card
    }

    private var borderColor: Color {
        if isSelected { return Theme.selectedBorder }
        return isHighlighted ? Theme.border : Theme.separator
    }

    @ViewBuilder
    private var menu: some View {
        if status.isRunning {
            Button("Stop") { Task { await state.stop(service) } }
            Button("Restart") { Task { await state.restart(service) } }
        } else {
            Button("Start") { Task { await state.start(service) } }
        }
        Divider()
        if let url = state.url(for: service) {
            Button("Open in Browser") { NSWorkspace.shared.open(url) }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        shareItems
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([service.directory])
        }
        Button("Open in Terminal") {
            // `open -a` rather than AppleScript, which would need the automation
            // entitlement and a TCC prompt for a one-line action.
            NSWorkspace.shared.open(
                [service.directory],
                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
        Divider()
        Text(service.command)
    }

    private var status: ServiceStatus { state.status(of: service) }

    private var tunnel: TunnelStatus { state.tunnel(of: service) }

    /// Matches `ServiceStatus.tint`: green only when the tunnel is actually
    /// carrying traffic, red when it failed. One tint for both would show a
    /// healthy-looking badge on a share that never opened.
    private var shareTint: Color {
        switch tunnel {
        case .live: Theme.publicShare
        case .failed: Theme.danger
        case .starting, .off: Theme.accentText
        }
    }

    private var shareLabel: String? {
        switch tunnel {
        case .off: nil
        case .starting: "Sharing"
        case .live: "Shared"
        case .failed: "Share failed"
        }
    }

    private var shareHelp: String {
        switch tunnel {
        case .off: "Not shared"
        case .starting: "Opening a public tunnel…"
        case let .live(url): "Shared publicly at \(url.absoluteString)"
        case let .failed(message): "Sharing failed. \(message)"
        }
    }

    @ViewBuilder
    private var shareItems: some View {
        if status.isRunning {
            Divider()
            if let url = state.publicURL(for: service) {
                Button("Copy Public URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                Button("Stop Sharing") { Task { await state.unshare(service) } }
            } else if !tunnel.isTransitioning {
                Button("Share Publicly…") { requestShare() }
            }
        }
    }

    private func requestShare() {
        guard status.isRunning else { return }
        if state.preferences.warningAccepted {
            Task { await state.share(service) }
        } else {
            confirmsShare = true
        }
    }

    /// A running service shows three actions, a stopped one shows two. Reserving
    /// the larger width always would cost the domain twenty points of a
    /// three-hundred point sidebar for nothing.
    private var reservedActionWidth: CGFloat {
        guard showsHoverActions else { return 0 }
        return status.isRunning ? Theme.Metrics.rowActionsWidth : Theme.Metrics.rowActionsWidth - 20
    }
}
