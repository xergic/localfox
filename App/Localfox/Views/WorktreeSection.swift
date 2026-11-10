import LocalfoxKit
import SwiftUI

/// A worktree's sub-heading under its project, and its rows while open.
///
/// Closed by default, so a repository an agent has left a dozen worktrees in
/// costs one quiet line each until something runs in one.
struct WorktreeSection: View {
    let checkout: WorktreeCheckout
    var forcesHover = false
    var selection: Binding<UUID?>?
    var showsHoverActions = true
    var keyboardSelectionID: UUID?
    /// A search is showing what matched, which a closed heading would hide.
    var forcesOpen = false

    @Environment(AppState.self) private var state
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            heading
            if isOpen {
                RowList(checkout.services) { service in
                    ServiceRow(
                        service: service,
                        forcesHover: forcesHover,
                        selection: selection,
                        showsHoverActions: showsHoverActions,
                        isKeyboardSelected: service.id == keyboardSelectionID
                    )
                }
            }
        }
    }

    private var heading: some View {
        HStack(spacing: 6) {
            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 10)
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
            Text(checkout.label)
                .font(.lfSubtitle)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(checkout.directory.path)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, Theme.Metrics.listRowPaddingH)
        .padding(.vertical, 3)
        .overlay(alignment: .trailing) {
            if isHovering || forcesHover { actions }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .onHover { isHovering = $0 }
    }

    private var actions: some View {
        HStack(spacing: 1) {
            if anyActive {
                IconButton(symbol: "stop.fill", tint: Theme.danger, help: "Stop all in this worktree") {
                    Task { await state.stopAll(checkout.services) }
                }
            } else {
                IconButton(symbol: "play.fill", tint: Theme.success, help: "Start all in this worktree") {
                    Task { await state.startAll(checkout.services) }
                }
            }
            IconButton(symbol: "folder", help: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([checkout.directory])
            }
        }
        .padding(.leading, 6)
        .background(Theme.background)
        .padding(.trailing, Theme.Metrics.headerActionsInset)
    }

    private var isOpen: Bool { forcesOpen || state.showsRows(of: checkout) }

    private var anyActive: Bool {
        checkout.services.contains { state.status(of: $0).isActive }
    }

    private func toggle() {
        guard !forcesOpen else { return }
        state.worktrees.expanded.formSymmetricDifference([checkout.id])
    }
}
