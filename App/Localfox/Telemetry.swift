import Foundation
import LocalfoxKit
import TelemetryDeck

/// Every parameter is a closed enum and no error text is sent, because a
/// message can quote a domain, path or port.
@MainActor
enum Telemetry {
    enum Outcome: String {
        case success
        case failure
    }

    enum ShareMode: String {
        case quick
        case named
        case ssh

        init(_ plan: TunnelPlan) {
            switch plan {
            case .quick: self = .quick
            case .named: self = .named
            case .ssh: self = .ssh
            }
        }
    }

    enum HelperOutcome: String {
        case ready
        case needsApproval = "needs_approval"
        case failure
    }

    enum Signal {
        case projectAdded
        case projectRemoved
        case serviceStarted
        case certificateTrusted(Outcome)
        case certificateUntrusted(Outcome)
        case helperInstalled(HelperOutcome)
        case shareStarted(ShareMode)

        var name: String {
            switch self {
            case .projectAdded: "Localfox.Project.added"
            case .projectRemoved: "Localfox.Project.removed"
            case .serviceStarted: "Localfox.Service.started"
            case .certificateTrusted: "Localfox.Certificate.trusted"
            case .certificateUntrusted: "Localfox.Certificate.untrusted"
            case .helperInstalled: "Localfox.Helper.installed"
            case .shareStarted: "Localfox.Share.started"
            }
        }

        var parameters: [String: String] {
            switch self {
            case .projectAdded, .projectRemoved, .serviceStarted: [:]
            case let .certificateTrusted(outcome), let .certificateUntrusted(outcome): ["outcome": outcome.rawValue]
            case let .helperInstalled(outcome): ["outcome": outcome.rawValue]
            case let .shareStarted(mode): ["mode": mode.rawValue]
            }
        }
    }

    private static let appID = "6BDAE13B-BD8A-4093-ADE1-E162C0CF2C8F"
    private static var isRunning = false

    static func setEnabled(_ enabled: Bool) {
        guard enabled != isRunning else { return }
        if enabled {
            guard SnapshotRenderer.request == nil else { return }
            TelemetryDeck.initialize(config: .init(appID: appID))
        } else {
            TelemetryDeck.terminate()
        }
        isRunning = enabled
    }

    static func send(_ signal: Signal) {
        guard isRunning else { return }
        TelemetryDeck.signal(signal.name, parameters: signal.parameters)
    }
}
