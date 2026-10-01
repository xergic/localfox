import LocalfoxKit
import SwiftUI

/// Small square icon button, used in headers and hover action clusters.
struct IconButton: View {
    let symbol: String
    var tint: Color = Theme.secondaryText
    var help: String = ""
    var symbolSize: CGFloat = 11
    var frameSize: CGFloat = 20
    /// A round-rect fill behind the glyph, for a button that stands alone in a header.
    var filled = false
    /// Spins the glyph only, so a filled button's background stays put.
    var spins = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(isHovering ? Theme.primaryText : tint)
                .rotationEffect(.degrees(spins ? 360 : 0))
                .animation(
                    spins ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                    value: spins
                )
                .frame(width: frameSize, height: frameSize)
                .background {
                    if filled { ControlBackground(isHovering: isHovering) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// The app icon, name and a subtitle, then a summary line and trailing buttons.
/// The popover is too narrow to hold the summary beside the name, so it stacks it.
struct AppHeader<Summary: View, Trailing: View>: View {
    let subtitle: String
    var stacksSummary = false
    @ViewBuilder let summary: () -> Summary
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        if stacksSummary {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) { identity; Spacer(); trailing() }
                summary()
            }
        } else {
            HStack(spacing: 10) {
                identity
                Spacer(minLength: 16)
                summary().padding(.trailing, 6)
                trailing()
            }
        }
    }

    private var identity: some View {
        HStack(spacing: 10) {
            AppIconView(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppInfo.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text(subtitle)
                    .font(.lfDetail)
                    .foregroundStyle(Theme.secondaryText)
            }
            .lineLimit(1)
        }
    }
}

/// Running, stopped, failed and shared, each only when there is one. Counted in
/// one pass, because the popover and the dashboard header both redraw it on
/// every status change.
struct ServiceSummary: View {
    @Environment(AppState.self) private var state

    var body: some View {
        var (running, stopped, failed, shared) = (0, 0, 0, 0)
        for project in state.projects {
            for service in project.services {
                switch state.status(of: service) {
                case .running: running += 1
                case .stopped, .waiting: stopped += 1
                case .failed: failed += 1
                case .starting, .stopping: break
                }
                if state.tunnel(of: service).isLive { shared += 1 }
            }
        }
        return HStack(spacing: 10) {
            if running > 0 {
                SummaryCount(count: running, label: "running", dot: Theme.success)
            }
            if stopped > 0 {
                SummaryCount(count: stopped, label: "stopped", dot: Theme.tertiaryText)
            }
            if failed > 0 {
                SummaryCount(count: failed, label: "failed", dot: Theme.danger)
            }
            if shared > 0 {
                SummaryCount(count: shared, label: "shared", dot: Theme.publicShare)
            }
        }
    }
}

struct AppIconView: View {
    private static let image = NSApplication.shared.applicationIconImage

    let size: CGFloat

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .frame(width: size, height: size)
        }
    }
}

/// A coloured dot, a bold figure and a label, as in "• 3 running".
struct SummaryCount: View {
    let count: Int
    let label: String
    let dot: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(String(count))
                .font(.lfDetailStrong)
                .foregroundStyle(Theme.primaryText)
            Text(label)
                .font(.lfDetail)
                .foregroundStyle(Theme.secondaryText)
        }
        .fixedSize()
    }
}

struct CardBackground: View {
    var fill: Color = Theme.card
    var border: Color = Theme.separator

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
        shape.fill(fill).overlay(shape.strokeBorder(border, lineWidth: 1))
    }
}

struct ControlBackground: View {
    var fill: Color = Theme.card
    var border: Color = Theme.separator
    var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous)
        shape.fill(isHovering ? Theme.cardHover : fill).overlay(shape.strokeBorder(border, lineWidth: 1))
    }
}

/// A small sentence-case label washed in its own tint.
struct TintedBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.lfBadge)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.badgeRadius, style: .continuous).fill(tint.opacity(0.14))
            )
    }
}

/// A service's port while it runs, its state otherwise. Fixed width, so the
/// hover actions can sit beside it without measuring it.
struct PortPill: View {
    let status: ServiceStatus

    var body: some View {
        Group {
            if let port = status.port {
                HStack(spacing: 3) {
                    Text(":").foregroundStyle(Theme.tertiaryText)
                    // A port is an identifier, not a quantity. Locale grouping
                    // renders 3111 as "3 111".
                    Text(String(port)).foregroundStyle(Theme.primaryText)
                }
                .font(.lfPort)
            } else {
                Text(status.label)
                    .font(.lfBadge)
                    .foregroundStyle(status.tint)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .frame(width: Theme.Metrics.portPillWidth, height: 21)
        .background(ControlBackground(fill: Theme.pill))
    }
}

/// Primary and secondary button chrome.
struct ActionButton: View {
    let title: String
    var symbol: String?
    var isPrimary = false
    var tint: Color = Theme.primaryText
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                }
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(isPrimary ? Theme.onAccent : tint)
            .actionChrome(isPrimary: isPrimary, isHovering: isHovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

extension View {
    /// The chrome an `ActionButton` wears, so anything that has to look like one
    /// without being one still changes with it.
    func actionChrome(isPrimary: Bool = false, isHovering: Bool = false) -> some View {
        padding(.horizontal, 11)
            .frame(height: Theme.Metrics.controlHeight)
            .background(ControlBackground(fill: isPrimary ? Theme.accent : Theme.card, isHovering: isHovering && !isPrimary))
    }
}

struct ErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                IconButton(symbol: "xmark", tint: Theme.danger, help: "Dismiss", action: onDismiss)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.danger.opacity(0.12))
        )
    }
}

/// The three-part empty state used on every surface.
struct EmptyStateView: View {
    let symbol: String
    let message: String
    var hint: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(Theme.tertiaryText)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 20)
    }
}

/// The PATH Localfox recovered from the login shell.
struct PathList: View {
    let entries: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PATH")
                .font(.lfDetail)
                .foregroundStyle(Theme.secondaryText)
            Text(entries.joined(separator: "\n"))
                .font(.lfSubtitle)
                .foregroundStyle(Theme.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A labelled text field with an inline error, shared by the add and edit sheets.
struct LabelledField: View {
    let label: String
    @Binding var text: String
    var monospaced = false
    /// Draws the value as dots. A tunnel token has no business being on screen.
    var isSecure = false
    var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 8)
                if let error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.danger)
                }
            }
            field
                .textFieldStyle(.plain)
                .font(monospaced || isSecure ? .lfSubtitle : .system(size: 12))
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.background)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    error == nil ? Theme.border : Theme.danger.opacity(0.6),
                                    lineWidth: 1
                                )
                        )
                )
        }
    }

    @ViewBuilder
    private var field: some View {
        if isSecure {
            SecureField("", text: $text)
        } else {
            TextField("", text: $text)
        }
    }
}
