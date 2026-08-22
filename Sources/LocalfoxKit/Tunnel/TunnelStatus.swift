import Foundation

/// Whether a service is currently reachable from the public internet.
///
/// Deliberately not `Codable`, for the same reason `ServiceStatus` is not: a
/// status is runtime truth, not saved configuration. Here the point is sharper
/// than a redraw cost. A persisted tunnel would come back after a relaunch the
/// user did not connect to the share they asked for an hour ago, and a public
/// URL nobody remembers opening is the one failure this feature must not have.
public enum TunnelStatus: Sendable, Equatable {
    case off
    case starting
    case live(URL)
    case failed(String)

    public var url: URL? {
        if case let .live(url) = self { return url }
        return nil
    }

    public var isLive: Bool { url != nil }

    /// Covers `starting` only: a live tunnel is settled, and a failed one needs
    /// its message shown rather than a spinner.
    public var isTransitioning: Bool { self == .starting }
}
