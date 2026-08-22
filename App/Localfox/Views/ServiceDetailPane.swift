import AppKit
import LocalfoxKit
import SwiftUI

/// Everything known about one service, including its recent output.
struct ServiceDetailPane: View {
    let service: Service
    var scrolls = true

    @Environment(AppState.self) private var state
    @State private var confirmsShare = false

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

            logs
        }
        .confirmationDialog(
            "Share \(service.name) on the public internet?",
            isPresented: $confirmsShare,
            titleVisibility: .visible
        ) {
            Button("Share Publicly", role: .destructive) { confirmedShare() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SharingWarning.text)
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
        Task { await state.share(service) }
    }

    /// Skips the dialog once the user has accepted it, because a warning shown
    /// every time is a warning nobody reads.
    private func requestShare() {
        guard status.isRunning else { return }
        if state.sharing.warningAccepted {
            Task { await state.share(service) }
        } else {
            confirmsShare = true
        }
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
                } else {
                    ActionButton(
                        title: tunnel.isTransitioning ? "Sharing…" : "Share",
                        symbol: "antenna.radiowaves.left.and.right"
                    ) {
                        requestShare()
                    }
                    .disabled(tunnel.isTransitioning)
                }
            }
        }
        .opacity(status.isTransitioning ? 0.5 : 1)
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
