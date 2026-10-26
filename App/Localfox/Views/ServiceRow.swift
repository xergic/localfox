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
    /// Holds the actions on screen while the QR popover is open, because the
    /// pointer leaves the row to reach it and the button would vanish under it.
    @State private var showsQRCode = false

    private var isSelected: Bool { isKeyboardSelected || selection?.wrappedValue == service.id }
    private var showsActions: Bool { showsHoverActions && (isHovering || forcesHover || showsQRCode) }

    var body: some View {
        HStack(spacing: 10) {
            ServiceIconView(
                type: service.framework,
                isPortRoute: service.kind == .portRoute,
                size: Theme.Metrics.rowIcon(compact: isCompact)
            )
            Group {
                // A line that does not fit falls back to two for this row alone.
                // `fixedSize` keeps the one line from being chosen and then
                // squeezed, which would truncate the domain this row exists to show.
                if isCompact {
                    ViewThatFits(in: .horizontal) {
                        oneLine.fixedSize(horizontal: true, vertical: false)
                        twoLines
                    }
                } else {
                    twoLines
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            trailingSlot
        }
        .padding(.horizontal, Theme.Metrics.listRowPaddingH)
        .padding(.vertical, Theme.Metrics.rowPaddingV(compact: isCompact))
        .background(rowFill, in: .row)
        .contentShape(Rectangle())
        .onTapGesture { selection?.wrappedValue = service.id }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .contextMenu { menu }
        .opacity(status.isTransitioning ? 0.5 : 1)
    }

    private var isCompact: Bool { state.preferences.compactRows }

    private var twoLines: some View {
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
            domainText
        }
    }

    private var oneLine: some View {
        HStack(spacing: 6) {
            nameText
            domainText
            if let shareLabel { shareBadge(shareLabel) }
        }
    }

    private var domainText: some View {
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

    /// On hover the actions take the port pill's place, so they never cover the
    /// name or the domain. Both are always laid out in one slot as wide as the
    /// wider of them, so the text beside it never re-truncates as the pointer
    /// moves across rows.
    private var trailingSlot: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 8) {
                LastResponsePill(service: service)
                PortPill(status: status)
            }
            .opacity(showsActions ? 0 : 1)
            if showsHoverActions {
                actions
                    .opacity(showsActions ? 1 : 0)
                    .allowsHitTesting(showsActions)
            }
        }
    }

    private var actions: some View {
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
            if let url = state.url(for: service) {
                IconButton(symbol: "globe", help: "Open in browser") { NSWorkspace.shared.open(url) }
                IconButton(symbol: "doc.on.doc", help: "Copy URL") { Pasteboard.copy(url.absoluteString) }
            }
            if let shared = state.publicURL(for: service) {
                IconButton(symbol: "qrcode", help: "Open the public URL on your phone") { showsQRCode = true }
                    .popover(isPresented: $showsQRCode, arrowEdge: .bottom) { QRCodeView(url: shared) }
            }
            if let directory = service.directory {
                IconButton(symbol: "folder", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }
            }
        }
    }

    private var isHighlighted: Bool { isHovering || showsActions }

    private var rowFill: Color {
        if isSelected { return Theme.selectedRow }
        return isHighlighted ? Theme.cardHover : .clear
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
            Button("Copy URL") { Pasteboard.copy(url.absoluteString) }
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
                Button("Copy Public URL") { Pasteboard.copy(url.absoluteString) }
                Button("Stop Sharing") { Task { await state.unshare(service) } }
            } else if !tunnel.isTransitioning {
                Button("Share Publicly…") { requestShare() }
            }
        }
    }

    private func requestShare() {
        guard status.isRunning else { return }
        if !state.preferences.warningAccepted {
            guard confirmsPublicShare() else { return }
            state.preferences.warningAccepted = true
        }
        Task { await state.share(service) }
    }

    /// An app-modal `NSAlert`, not a SwiftUI dialog. This row lives in the menu
    /// bar popover, and a dialog attached to that window first dimmed it without
    /// appearing, then appeared with a Share button that took no clicks.
    private func confirmsPublicShare() -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Share \(service.name) on the public internet?"
        alert.informativeText = SharingWarning.exposure(.quick)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Share Publicly").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
