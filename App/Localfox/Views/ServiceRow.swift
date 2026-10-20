import LocalfoxKit
import SwiftUI

struct ServiceRow: View {
    let service: Service
    var forcesHover = false
    var selection: Binding<UUID?>?
    /// The dashboard sidebar shows its actions in the detail pane instead, which
    /// buys back the reserved width. Without that, `api.wishfox.localhost` does
    /// not fit in three hundred points and truncates to `api.wishfox.local…`,
    /// hiding the one thing the row exists to show.
    var showsHoverActions = true
    var isKeyboardSelected = false

    @Environment(AppState.self) private var state
    @State private var isHovering = false
    @State private var confirmsShare = false

    private var isSelected: Bool { isKeyboardSelected || selection?.wrappedValue == service.id }
    private var showsActions: Bool { showsHoverActions && (isHovering || forcesHover) }

    var body: some View {
        HStack(spacing: 10) {
            ServiceIconView(type: service.framework, isPortRoute: service.kind == .portRoute)
            VStack(alignment: .leading, spacing: 1) {
                // Beside the name, not the domain. A service name is a word, and
                // beside the domain the badge truncated the one fact the row shows.
                // A public tunnel the user has forgotten is the failure that
                // matters here, so it is marked at rest and not behind hover.
                // A name too long to sit beside the badge drops the badge to a
                // line of its own rather than truncating the name.
                if let shareLabel {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { nameText; shareBadge(shareLabel) }
                        VStack(alignment: .leading, spacing: 3) { nameText; shareBadge(shareLabel) }
                    }
                } else {
                    nameText
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
                    if status.isActive {
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
                    if let directory = service.directory {
                        IconButton(symbol: "folder", help: "Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([directory])
                        }
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
        if status.isActive {
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
        if service.kind == .command { shareItems }
        if let directory = service.directory {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            }
            Button("Open in Terminal") {
                // `open -a` rather than AppleScript, which would need the automation
                // entitlement and a TCC prompt for a one-line action.
                NSWorkspace.shared.open(
                    [directory],
                    withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                    configuration: NSWorkspace.OpenConfiguration()
                )
            }
        }
        if service.kind == .command {
            Divider()
            Text(service.command)
        }
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

    private var nameText: some View {
        Text(service.name)
            .font(.lfName)
            .foregroundStyle(Theme.primaryText)
            .lineLimit(1)
    }

    private func shareBadge(_ label: String) -> some View {
        TintedBadge(text: label, tint: shareTint)
            .fixedSize()
            .help(shareHelp)
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
        return status.isActive ? Theme.Metrics.rowActionsWidth : Theme.Metrics.rowActionsWidth - 20
    }
}
