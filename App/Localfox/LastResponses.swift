import Foundation
import LocalfoxKit
import Observation
import SwiftUI

/// The last request Caddy logged for each running service.
///
/// Read from the access log the proxy already writes, so a status costs the dev
/// server nothing: no probe, no extra request in its log, no page compiled for
/// nobody. The answer is whatever the last real visitor got.
@MainActor
@Observable
final class LastResponses {
    private(set) var entries: [UUID: AccessLogEntry] = [:]

    func record(_ entry: AccessLogEntry?, for serviceID: UUID) {
        if entries[serviceID] != entry { entries[serviceID] = entry }
    }

    /// A stopped service's last answer describes a process that is gone.
    func forget(_ serviceID: UUID) {
        if entries[serviceID] != nil { entries[serviceID] = nil }
    }
}

@MainActor
extension AppState {
    /// One line per running service, read when the menu opens. The helper filters
    /// by host, so each call reads one line of one route.
    func refreshLastResponses() async {
        guard preferences.recordsRequests, helperClient.state.canServe else { return }
        for service in projects.flatMap(\.services) where status(of: service).isRunning {
            let host = service.domain.value
            guard let tail = try? await helperClient.accessLog(host: host, lines: 1) else { continue }
            lastResponses.record(AccessLogEntry.parse(tail: tail, host: host, limit: 1).last, for: service.id)
        }
    }
}

extension AccessLogEntry.StatusClass {
    /// Shared by the request list and the row pill, so one status never reads in
    /// two colours.
    var tint: Color {
        switch self {
        case .success: Theme.success
        case .redirect: Theme.accentText
        case .clientError, .other: Theme.secondaryText
        case .serverError: Theme.danger
        }
    }
}

/// The last status beside the port. A leaf, so a new reading redraws this pill
/// and not every row around it.
struct LastResponsePill: View {
    @Environment(AppState.self) private var state
    let service: Service

    var body: some View {
        if state.status(of: service).isRunning, let entry = state.lastResponses.entries[service.id] {
            Text(String(entry.status))
                .font(.lfVersion)
                .fontWeight(.semibold)
                .foregroundStyle(entry.statusClass.tint)
                .frame(width: 38, height: 21)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metrics.badgeRadius, style: .continuous)
                        .fill(entry.statusClass.tint.opacity(0.14))
                )
                .help("Last request: \(entry.method) \(entry.uri) · \(entry.milliseconds) ms · "
                    + entry.timestamp.formatted(.relative(presentation: .named)))
        }
    }
}
