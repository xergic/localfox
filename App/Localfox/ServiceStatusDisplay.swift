import LocalfoxKit
import SwiftUI

extension ServiceStatus {
    /// Uses the existing palette rather than inventing an indicator: Portfox has
    /// no running/stopped dot because it only ever lists running things.
    var tint: Color {
        switch self {
        case .running: Theme.success
        case .starting, .stopping: Theme.accentText
        case .failed: Theme.danger
        case .stopped: Theme.secondaryText
        case .waiting: Theme.accentText
        }
    }

    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case let .running(_, port): ":\(port)"
        case .stopping: "Stopping"
        case .waiting: "Waiting"
        case .failed: "Failed"
        }
    }

    /// A word in every state, for a place where the port has its own row.
    var title: String {
        isRunning ? "Running" : label
    }
}
