import LocalfoxKit
import SwiftUI

/// The menu bar popover: runtime status and quick actions only.
struct MenuView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var scrolls = true
    var forcesHover = false

    @State private var listHeight: CGFloat = Theme.Metrics.maximumListHeight

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.separator)

            if state.needsSetup {
                setupWall
            } else if state.projects.isEmpty {
                EmptyStateView(
                    symbol: "folder.badge.plus",
                    message: "No projects yet",
                    hint: "Add one from the Localfox window"
                )
            } else {
                list
            }

            Divider().overlay(Theme.separator)
            footer
        }
        .frame(width: Theme.Metrics.popoverWidth)
        .background(Theme.background)
        // Not preferredColorScheme, which is a scene preference and no-ops
        // under ImageRenderer, so a snapshot would come out light.
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(.menuBarFox)
                .renderingMode(.template)
                .resizable()
                .frame(width: 19, height: 19)
                .foregroundStyle(Theme.accent)

            Text("Localfox")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.primaryText)

            if state.runningCount > 0 {
                Text("\(state.runningCount)")
                    .font(.lfCount)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.pill))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Localfox has no unprivileged fallback, so an unapproved helper blocks the
    /// list rather than quietly serving on a different port.
    private var setupWall: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 24))
                .foregroundStyle(Theme.accent)
            Text("Finish setting up local HTTPS")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text(setupReason)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            ActionButton(title: "Open Setup", isPrimary: true) {
                WindowPresenter.showDashboard(openWindow)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 20)
    }

    private var setupReason: String {
        if !state.helper.canServe {
            return "Localfox needs its helper approved before it can serve ports 80 and 443."
        }
        return "Localfox needs its certificate authority trusted before HTTPS will work."
    }

    private var list: some View {
        MeasuredScrollView(height: $listHeight, maximum: Theme.Metrics.maximumListHeight, scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 10) {
                if let error = state.lastError {
                    ErrorBanner(message: error) { state.clearError() }
                }
                ForEach(state.projects) { project in
                    ProjectSection(project: project, forcesHover: forcesHover)
                }
            }
            .padding(10)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            FooterButton(symbol: "macwindow", title: "Localfox") {
                WindowPresenter.showDashboard(openWindow)
            }
            Spacer(minLength: 0)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct FooterButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(isHovering ? Theme.primaryText : Theme.secondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A project heading and its services.
struct ProjectSection: View {
    let project: Project
    var forcesHover = false

    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                Circle()
                    .fill(anyRunning ? Theme.success : Theme.tertiaryText)
                    .frame(width: 7, height: 7)
                Text(project.name)
                    .font(.lfProject)
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize()
                Text(project.displayPath)
                    .font(.lfSubtitle)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .fill(Theme.card)
            )

            ForEach(project.services) { service in
                ServiceRow(service: service, forcesHover: forcesHover)
            }
            .padding(.leading, 7)
        }
    }

    private var anyRunning: Bool {
        project.services.contains { state.status(of: $0).isRunning }
    }
}

struct ServiceRow: View {
    let service: Service
    var forcesHover = false

    @Environment(AppState.self) private var state
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name)
                    .font(.lfName)
                    .foregroundStyle(Theme.primaryText)
                Text(service.domain.value)
                    .font(.lfSubtitle)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)
            // Reserved even at rest, so revealing the actions never
            // re-truncates the text or shifts the row under the pointer.
            .padding(.trailing, Theme.Metrics.rowActionsWidth)

            Spacer(minLength: 0)

            StatusPill(text: status.label, tint: status.tint)
                .frame(minWidth: Theme.Metrics.portPillWidth, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .overlay(alignment: .trailing) {
            if isHovering || forcesHover {
                HStack(spacing: 1) {
                    if state.url(for: service) != nil {
                        IconButton(symbol: "globe", help: "Open in browser") {
                            if let url = state.url(for: service) { NSWorkspace.shared.open(url) }
                        }
                    }
                    IconButton(symbol: "folder", help: "Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([service.directory])
                    }
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.cardHover)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Theme.border, lineWidth: 1)
                        )
                )
                .padding(.trailing, Theme.Metrics.portPillWidth + 14)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.rowRadius, style: .continuous)
                .fill(isHovering ? Theme.cardHover : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }

    private var status: ServiceStatus { state.status(of: service) }
}
