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
    /// Bound only by the dashboard. The popover has nowhere to show a detail
    /// pane, so it leaves this nil and rows stay unselectable.
    var selection: Binding<UUID?>?
    var showsHoverActions = true
    /// Dashboard only. The popover is a launcher, and a destructive action one
    /// mis-click from Start all does not belong in a window that dismisses itself.
    var showsRemove = false

    @Environment(AppState.self) private var state
    @State private var isConfirmingRemove = false

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

                if anyRunning {
                    IconButton(symbol: "stop.fill", tint: Theme.danger, help: "Stop all") {
                        Task { await state.stopAll(project) }
                    }
                } else {
                    IconButton(symbol: "play.fill", tint: Theme.success, help: "Start all") {
                        Task { await state.startAll(project) }
                    }
                }
                IconButton(symbol: "folder", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([project.directory])
                }
                if showsRemove {
                    IconButton(symbol: "trash", help: "Remove project") {
                        isConfirmingRemove = true
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .fill(Theme.card)
            )

            ForEach(project.services) { service in
                ServiceRow(
                    service: service,
                    forcesHover: forcesHover,
                    selection: selection,
                    showsHoverActions: showsHoverActions
                )
            }
            .padding(.leading, 7)
        }
        .alert("Remove \(project.name)?", isPresented: $isConfirmingRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let selected = selection?.wrappedValue, project.service(id: selected) != nil {
                    selection?.wrappedValue = nil
                }
                Task { await state.remove(projectID: project.id) }
            }
        } message: {
            Text("Localfox forgets this project and its services. Nothing on disk changes.")
        }
    }

    private var anyRunning: Bool {
        project.services.contains { state.status(of: $0).isRunning }
    }
}

struct ServiceRow: View {
    let service: Service
    var forcesHover = false
    var selection: Binding<UUID?>?
    /// The dashboard sidebar shows its actions in the detail pane instead, which
    /// buys back the reserved width. Without that, `api.wishfox.localhost` does
    /// not fit in three hundred points and truncates to `api.wishfox.local…`,
    /// hiding the one thing the row exists to show.
    var showsHoverActions = true

    @Environment(AppState.self) private var state
    @State private var isHovering = false

    private var isSelected: Bool { selection?.wrappedValue == service.id }
    private var showsActions: Bool { showsHoverActions && (isHovering || forcesHover) }

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
                    // Tail, not middle. The subdomain is what distinguishes
                    // api.wishfox.localhost from admin.wishfox.localhost, and
                    // middle truncation ate exactly that: "wishfo…calhost".
                    .truncationMode(.tail)
                    .help(service.domain.value)
            }
            .layoutPriority(1)
            // Reserved even at rest, so revealing the actions never
            // re-truncates the text or shifts the row under the pointer.
            .padding(.trailing, reservedActionWidth)

            Spacer(minLength: 0)

            StatusPill(text: status.label, tint: status.tint)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .overlay(alignment: .trailing) {
            if showsActions {
                HStack(spacing: 1) {
                    if status.isRunning {
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
                .fill(isHovering || isSelected ? Theme.cardHover : .clear)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metrics.rowRadius, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 1.5)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { selection?.wrappedValue = service.id }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .contextMenu { menu }
        .opacity(status.isTransitioning ? 0.5 : 1)
    }

    @ViewBuilder
    private var menu: some View {
        if status.isRunning {
            Button("Stop") { Task { await state.stop(service) } }
            Button("Restart") { Task { await state.restart(service) } }
        } else {
            Button("Start") { Task { await state.start(service) } }
        }
        Divider()
        if let url = state.url(for: service) {
            Button("Open in Browser") { NSWorkspace.shared.open(url) }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([service.directory])
        }
        Button("Open in Terminal") {
            // `open -a` rather than AppleScript, which would need the automation
            // entitlement and a TCC prompt for a one-line action.
            NSWorkspace.shared.open(
                [service.directory],
                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
        Divider()
        Text(service.command)
    }

    private var status: ServiceStatus { state.status(of: service) }

    /// A running service shows three actions, a stopped one shows two. Reserving
    /// the larger width always would cost the domain twenty points of a
    /// three-hundred point sidebar for nothing.
    private var reservedActionWidth: CGFloat {
        guard showsHoverActions else { return 0 }
        return status.isRunning ? Theme.Metrics.rowActionsWidth : Theme.Metrics.rowActionsWidth - 20
    }
}
