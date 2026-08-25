import AppKit
import LocalfoxKit
import SwiftUI

/// Everything known about one service, including its recent output.
struct ServiceDetailPane: View {
    let service: Service
    var scrolls = true

    @Environment(AppState.self) private var state
    @State private var confirmsShare = false
    /// Which share the user asked for, held across the confirmation.
    @State private var pendingMode: ShareMode = .quick

    enum ShareMode: Hashable {
        case quick
        case named
        case ssh

        var warning: String {
            switch self {
            case .quick: SharingWarning.text
            case .named: SharingWarning.namedText
            case .ssh: SharingWarning.sshText
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(alignment: .top, spacing: 16) {
                DetailCard(title: "CONFIGURATION", symbol: "slider.horizontal.3") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledRow(label: "Framework", value: service.framework.displayName)
                        CardDivider()
                        LabeledRow(label: "Command", value: service.command)
                        CardDivider()
                        LabeledRow(label: "Directory", value: service.directory.path)
                        CardDivider()
                        LabeledRow(label: "Port", value: portDescription)
                    }
                }
                DetailCard(title: "STATUS", symbol: "bolt.horizontal") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledRow(label: "State", value: status.label, tint: status.tint)
                        CardDivider()
                        LabeledRow(label: "Domain", value: service.domain.value)
                        if case let .running(pid, port) = status {
                            CardDivider()
                            LabeledRow(label: "Process", value: "pid \(pid)")
                            CardDivider()
                            LabeledRow(label: "Proxying", value: "127.0.0.1:\(port)")
                        }
                        if tunnel != .off {
                            CardDivider()
                            publicRow
                        }
                    }
                }
            }

            if case let .failed(failure) = status {
                DetailCard(title: "WHY IT FAILED", symbol: "exclamationmark.triangle") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Self.explain(failure.reason))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                        // Inline rather than a pointer to the diagnostics panel.
                        // The PATH is the whole answer to this one failure, and
                        // sending the user somewhere else to read it is a step
                        // that buys nothing.
                        if case .commandNotFound = failure.reason,
                           let environment = state.shellEnvironment {
                            CardDivider()
                            PathList(entries: environment.pathEntries)
                        }
                        if !failure.output.isEmpty {
                            LogText(text: failure.output)
                        }
                    }
                }
            }

            requestsCard
            logs
        }
        // Polls only while this pane is on screen, and restarts when the pane
        // moves to another service. The access log is read over XPC, so a
        // dashboard nobody is looking at must not pay for it.
        .task(id: service.id) {
            while !Task.isCancelled {
                await state.refreshRequests(for: service)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .confirmationDialog(
            "Share \(service.name) on the public internet?",
            isPresented: $confirmsShare,
            titleVisibility: .visible
        ) {
            Button("Share Publicly", role: .destructive) { confirmedShare() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingMode.warning)
        }
    }

    private var status: ServiceStatus { state.status(of: service) }

    private var tunnel: TunnelStatus { state.tunnel(of: service) }

    @ViewBuilder
    private var publicRow: some View {
        switch tunnel {
        case .off:
            EmptyView()
        case .starting:
            LabeledRow(label: "Public URL", value: "Opening tunnel…", tint: Theme.accentText)
        case let .live(url):
            HStack(spacing: 6) {
                LabeledRow(label: "Public URL", value: url.absoluteString, tint: Theme.success)
                IconButton(symbol: "doc.on.doc", help: "Copy public URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
        case let .failed(message):
            LabeledRow(label: "Public URL", value: message, tint: Theme.danger)
        }
    }

    private func confirmedShare() {
        state.sharing.warningAccepted = true
        Task { await start(pendingMode) }
    }

    /// Skips the dialog once the user has accepted it, because a warning shown
    /// every time is a warning nobody reads.
    private func requestShare(_ mode: ShareMode) {
        guard status.isRunning else { return }
        pendingMode = mode
        if state.sharing.warningAccepted {
            Task { await start(mode) }
        } else {
            confirmsShare = true
        }
    }

    private func start(_ mode: ShareMode) async {
        switch mode {
        case .quick: await state.share(service)
        case .named: await state.shareNamed(service)
        case .ssh: await state.shareSSH(service)
        }
    }

    /// The modes beyond Quick that this service actually has configured.
    private var extraModes: [ShareMode] {
        var modes: [ShareMode] = []
        if state.tunnelTargets.isConfigured(service.id) { modes.append(.named) }
        if state.tunnelTargets.ssh(for: service.id) != nil { modes.append(.ssh) }
        return modes
    }

    private var portDescription: String {
        switch service.portMode {
        case .auto:
            if let expected = service.expectedPort {
                return "Auto, \(expected) expected"
            }
            return "Auto"
        case let .fixed(port):
            return "Fixed at \(port)"
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text("https://\(service.domain.value)")
                    .font(.lfSubtitle)
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)

            if status.isRunning {
                ActionButton(title: "Stop", symbol: "stop.fill", tint: Theme.danger) {
                    Task { await state.stop(service) }
                }
                ActionButton(title: "Restart", symbol: "arrow.clockwise") {
                    Task { await state.restart(service) }
                }
            } else {
                ActionButton(title: "Start", symbol: "play.fill", isPrimary: true) {
                    Task { await state.start(service) }
                }
            }

            if let url = state.url(for: service) {
                ActionButton(title: "Open", symbol: "globe") { NSWorkspace.shared.open(url) }
            }

            // Only while running: a tunnel needs the discovered port, and under
            // Auto that does not exist until the dev server has bound it.
            if status.isRunning {
                if tunnel.isLive {
                    ActionButton(
                        title: "Stop Sharing",
                        symbol: "antenna.radiowaves.left.and.right.slash",
                        tint: Theme.danger
                    ) {
                        Task { await state.unshare(service) }
                    }
                } else if !extraModes.isEmpty {
                    // A menu only once there is a choice to make. With nothing
                    // else configured there is exactly one thing Share can do,
                    // and a one-item menu is a button with an extra click.
                    ShareMenu(
                        extraModes: extraModes,
                        isTransitioning: tunnel.isTransitioning,
                        onSelect: requestShare
                    )
                } else {
                    ActionButton(
                        title: tunnel.isTransitioning ? "Sharing…" : "Share",
                        symbol: "antenna.radiowaves.left.and.right"
                    ) {
                        requestShare(.quick)
                    }
                    .disabled(tunnel.isTransitioning)
                }
            }
        }
        .opacity(status.isTransitioning ? 0.5 : 1)
    }

    @ViewBuilder
    private var requestsCard: some View {
        let entries = state.requests(for: service)
        DetailCard(title: "REQUESTS", symbol: "arrow.left.arrow.right") {
            if !state.proxy.recordsRequests {
                Text("Turn on Record requests in Preferences to see traffic here.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            } else if entries.isEmpty {
                Text(status.isRunning ? "No requests yet." : "Start the service to see its requests.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                Scrollable(scrolls: scrolls) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Newest first: the reason to open this panel is always
                        // the request that just happened.
                        ForEach(entries.reversed()) { entry in
                            RequestRow(entry: entry)
                        }
                    }
                }
                .frame(maxHeight: scrolls ? 200 : nil)
            }
        }
    }

    @ViewBuilder
    private var logs: some View {
        let text = state.log(for: service)
        DetailCard(title: "OUTPUT", symbol: "text.alignleft") {
            if text.isEmpty {
                Text(status.isRunning ? "No output yet." : "Start the service to see its output.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                LogText(text: text, scrolls: scrolls)
            }
        }
    }

    /// Says what went wrong in words the user can act on. An exit code alone is
    /// not something anybody can do anything about.
    static func explain(_ reason: ServiceStatus.Failure.Reason) -> String {
        switch reason {
        case let .exited(code):
            "The command exited with status \(code)."
        case let .signalled(signal):
            "The command was stopped by signal \(signal)."
        case let .commandNotFound(command):
            """
            \(command) was not found on the PATH Localfox recovered from your \
            login shell.
            """
        case .noPortDiscovered:
            """
            The command is running but never opened a port Localfox could find. \
            Set the port by hand if this server does not listen on one.
            """
        case let .spawnFailed(code):
            "The command could not be started (errno \(code))."
        }
    }
}

/// Share, with the two tunnel kinds behind it.
private struct ShareMenu: View {
    let extraModes: [ServiceDetailPane.ShareMode]
    let isTransitioning: Bool
    let onSelect: (ServiceDetailPane.ShareMode) -> Void

    var body: some View {
        Menu {
            Button("Quick Tunnel") { onSelect(.quick) }
            ForEach(extraModes, id: \.self) { mode in
                Button(Self.title(mode)) { onSelect(mode) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .medium))
                Text(isTransitioning ? "Sharing…" : "Share")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.pill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isTransitioning)
    }

    private static func title(_ mode: ServiceDetailPane.ShareMode) -> String {
        switch mode {
        case .quick: "Quick Tunnel"
        case .named: "Named Tunnel"
        case .ssh: "SSH Tunnel"
        }
    }
}

/// One handled request, as the access log recorded it.
private struct RequestRow: View {
    let entry: AccessLogEntry

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.method)
                .font(.mono(10, .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 46, alignment: .leading)
            Text(entry.uri)
                .font(.lfSubtitle)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("\(entry.milliseconds) ms")
                .font(.mono(10))
                .foregroundStyle(Theme.tertiaryText)
            Text(Self.size(entry.size))
                .font(.mono(10))
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 58, alignment: .trailing)
            StatusPill(text: "\(entry.status)", tint: Self.tint(entry.statusClass))
        }
        .padding(.vertical, 3)
    }

    private static func tint(_ statusClass: AccessLogEntry.StatusClass) -> Color {
        switch statusClass {
        case .success: Theme.success
        case .redirect: Theme.accentText
        case .clientError, .other: Theme.secondaryText
        case .serverError: Theme.danger
        }
    }

    private static func size(_ bytes: Int) -> String {
        bytes < 1_024 ? "\(bytes) B" : "\(bytes / 1_024) kB"
    }
}

/// Monospaced, selectable output on the darkest surface.
private struct LogText: View {
    let text: String
    var scrolls = true

    var body: some View {
        Scrollable(scrolls: scrolls) {
            Text(text)
                .font(.lfSubtitle)
                .foregroundStyle(Theme.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
        }
        .frame(maxHeight: scrolls ? 260 : nil)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.background)
        )
    }
}
