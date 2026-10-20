import LocalfoxKit
import SwiftUI

/// The menu bar popover: runtime status and quick actions only.
struct MenuView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var scrolls = true
    var forcesHover = false

    @State private var listHeight: CGFloat = Theme.Metrics.maximumListHeight
    @State private var isRefreshing = false
    @State private var query = ""
    /// Moved by the arrow keys. Nil until one is pressed, so a fresh query
    /// highlights its first match rather than whatever was picked before.
    @State private var keyboardSelectionID: UUID?

    var body: some View {
        let visible = state.projects.matching(query) { state.status(of: $0).port }
        let ordered = visible.flatMap(\.services)
        let selectedID = selection(in: ordered)?.id
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
                searchField
                if visible.isEmpty {
                    EmptyStateView(symbol: "magnifyingglass", message: "No services match \u{201C}\(query)\u{201D}", hint: nil)
                } else {
                    list(visible, selectedID: selectedID)
                }
            }

            Divider().overlay(Theme.separator)
            footer
        }
        .frame(width: Theme.Metrics.popoverWidth)
        .background(Theme.background)
        .themedSurface(state.appearance.colorScheme)
        // On the root rather than the field, so the keys still work after a
        // click lands on a row and the field loses focus.
        .onKeyPress { press in handle(press, in: ordered) }
        .onAppear { Task { await state.refreshLastResponses() } }
        .onDisappear { query = "" }
        .onChange(of: query) { keyboardSelectionID = nil }
    }

    private var searchField: some View {
        SearchField(
            text: $query,
            prompt: "Search services, domains, ports",
            focusesOnAppear: true,
            isLive: scrolls
        )
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private func handle(_ press: KeyPress, in ordered: [Service]) -> KeyPress.Result {
        switch press.key {
        case .downArrow:
            return moveSelection(by: 1, in: ordered)
        case .upArrow:
            return moveSelection(by: -1, in: ordered)
        case .return:
            guard let service = selection(in: ordered) else { return .ignored }
            if let url = state.url(for: service) {
                NSWorkspace.shared.open(url)
            } else if !state.status(of: service).isActive {
                Task { await state.start(service) }
            }
            return .handled
        case .delete where press.modifiers.contains(.command):
            guard let service = selection(in: ordered), state.status(of: service).isActive else { return .ignored }
            Task { await state.stop(service) }
            return .handled
        default:
            return .ignored
        }
    }

    /// The row Return and Cmd-Delete act on. A typed query always has one, so
    /// "api, Return" opens it without touching the arrows.
    private func selection(in ordered: [Service]) -> Service? {
        if let keyboardSelectionID, let match = ordered.first(where: { $0.id == keyboardSelectionID }) {
            return match
        }
        return query.isEmpty ? nil : ordered.first
    }

    private func moveSelection(by step: Int, in ordered: [Service]) -> KeyPress.Result {
        guard !ordered.isEmpty else { return .ignored }
        let current = selection(in: ordered).flatMap { selected in ordered.firstIndex { $0.id == selected.id } }
        let next = current.map { ($0 + step + ordered.count) % ordered.count } ?? (step > 0 ? 0 : ordered.count - 1)
        keyboardSelectionID = ordered[next].id
        return .handled
    }

    private var header: some View {
        AppHeader(subtitle: "Local HTTPS domains", stacksSummary: true) {
            if !state.needsSetup { ServiceSummary() }
        } trailing: {
            // The helper is approved in System Settings, outside this process,
            // and nothing else re-reads it while only the popover is open.
            IconButton(
                symbol: "arrow.trianglehead.2.clockwise",
                help: "Check setup again",
                symbolSize: Theme.Metrics.headerSymbolSize,
                frameSize: Theme.Metrics.headerButtonSize,
                filled: true,
                spins: isRefreshing
            ) {
                guard !isRefreshing else { return }
                isRefreshing = true
                Task {
                    await state.refreshSetup()
                    isRefreshing = false
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// Localfox has no unprivileged fallback, so an unapproved helper blocks the
    /// list rather than quietly serving on a different port.
    private var setupWall: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 24))
                .foregroundStyle(Theme.accentText)
                .padding(.bottom, 2)
            Text("Finish setting up local HTTPS")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text(setupReason)
                .font(.lfDetail)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ActionButton(title: "Open Setup", symbol: "arrow.up.forward.app", isPrimary: true) {
                WindowPresenter.showDashboard(openWindow)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 28)
    }

    private var setupReason: String {
        if !state.helper.canServe {
            return "Localfox needs its helper approved before it can serve ports 80 and 443."
        }
        return "Localfox needs its certificate authority trusted before HTTPS will work."
    }

    private func list(_ projects: [Project], selectedID: UUID?) -> some View {
        ScrollViewReader { proxy in
            MeasuredScrollView(height: $listHeight, maximum: Theme.Metrics.maximumListHeight, scrolls: scrolls) {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = state.lastError {
                        ErrorBanner(message: error) { state.clearError() }
                    }
                    ForEach(projects) { project in
                        ProjectSection(project: project, forcesHover: forcesHover, keyboardSelectionID: selectedID)
                    }
                }
                .padding(12)
            }
            .onChange(of: selectedID) {
                guard let selectedID else { return }
                proxy.scrollTo(selectedID)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            FooterButton(symbol: "macwindow", title: "Localfox") {
                WindowPresenter.showDashboard(openWindow)
            }
            FooterButton(symbol: "slider.horizontal.3", title: "Settings…") {
                // Requested before the window has laid out, which is why the flag
                // lives on `AppState` rather than in the dashboard's own state.
                WindowPresenter.showDashboard(openWindow)
                state.presentsPreferences = true
            }
            Spacer(minLength: 0)
            Text(AppInfo.versionLabel)
                .font(.lfVersion)
                .foregroundStyle(Theme.tertiaryText)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct FooterButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 12))
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
    /// Dashboard only, for a second reason: a sheet presented from the popover
    /// attaches to a window that closes when it resigns key, which loses the
    /// edit mid-typing.
    var showsEdit = false
    /// The popover's arrow-key selection, drawn like a selected row.
    var keyboardSelectionID: UUID?

    @Environment(AppState.self) private var state
    @State private var isConfirmingRemove = false
    @State private var isEditing = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                ServiceIconView(
                    type: project.services.first?.framework ?? .unknown,
                    projectIconPath: state.iconPath(for: project),
                    isPortRoute: project.services.allSatisfy { $0.kind == .portRoute },
                    size: Theme.Metrics.projectIcon
                )
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(anyRunning ? Theme.success : Theme.tertiaryText)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(Theme.background, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
                Text(project.name)
                    .font(.lfProject)
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize()
                // Hidden rather than squeezed while the actions are up. Reserving
                // room for four buttons leaves a 300pt sidebar rendering
                // `~/Work/Wishfox/wishfox-api` as `…i`, and the path is worth
                // more at rest than under the pointer.
                if let displayPath = project.displayPath {
                    Text(displayPath)
                        .font(.lfSubtitle)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(displayPath)
                        .opacity(showsActions ? 0 : 1)
                }
                Spacer(minLength: 0)
            }
            // Bare on the background, because a card heading above cards would
            // read as one more row.
            .padding(4)
            .overlay(alignment: .trailing) {
                if showsActions { headerActions }
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }

            ForEach(project.services) { service in
                ServiceRow(
                    service: service,
                    forcesHover: forcesHover,
                    selection: selection,
                    showsHoverActions: showsHoverActions,
                    isKeyboardSelected: service.id == keyboardSelectionID
                )
            }
        }
        .sheet(isPresented: $isEditing) {
            EditProjectSheet(project: project).environment(state)
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

    private var headerActions: some View {
        HStack(spacing: 1) {
            if anyActive {
                IconButton(symbol: "stop.fill", tint: Theme.danger, help: "Stop all") {
                    Task { await state.stopAll(project) }
                }
            } else {
                IconButton(symbol: "play.fill", tint: Theme.success, help: "Start all") {
                    Task { await state.startAll(project) }
                }
            }
            if let directory = project.directory {
                IconButton(symbol: "folder", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }
            }
            if showsEdit {
                IconButton(symbol: "pencil", help: "Edit project") { isEditing = true }
            }
            if showsRemove {
                IconButton(symbol: "trash", help: "Remove project") { isConfirmingRemove = true }
            }
        }
        .padding(.trailing, Theme.Metrics.rowPaddingH)
    }

    private var showsActions: Bool { isHovering || forcesHover }

    private var anyRunning: Bool {
        project.services.contains { state.status(of: $0).isRunning }
    }

    private var anyActive: Bool {
        project.services.contains { state.status(of: $0).isActive }
    }
}
