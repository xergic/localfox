import AppKit
import LocalfoxKit
import SwiftUI

/// Everything known about one service, including its recent output.
struct ServiceDetailPane: View {
    let service: Service
    var scrolls = true

    @Environment(AppState.self) private var state

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
                        if !failure.output.isEmpty {
                            LogText(text: failure.output)
                        }
                    }
                }
            }

            logs
        }
    }

    private var status: ServiceStatus { state.status(of: service) }

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
            \(command) was not found. Localfox runs commands through your login \
            shell; check the PATH shown under Command Environment.
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
