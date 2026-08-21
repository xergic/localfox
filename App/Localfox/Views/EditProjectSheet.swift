import AppKit
import LocalfoxKit
import SwiftUI

/// Renames a project, re-domains its services and picks its icon.
///
/// Everything the sheet changes is visible in the sheet before it is saved,
/// including the domains a rename suggests.
struct EditProjectSheet: View {
    let project: Project

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var projectName: String
    @State private var rows: [EditableService]
    @State private var iconPath: String?
    @State private var assets: [ProjectAsset] = []
    @State private var isPickingIcon = false
    @State private var pendingRestarts: [Service] = []
    @State private var isConfirmingRestart = false

    init(project: Project) {
        self.project = project
        _projectName = State(initialValue: project.name)
        _iconPath = State(initialValue: project.iconURL?.path)
        _rows = State(initialValue: project.services.map(EditableService.init))
    }

    /// A service the user is still editing. Separate from `Service` so a
    /// half-typed domain never has to be a valid `LocalDomain`.
    struct EditableService: Identifiable {
        let id: UUID
        var name: String
        var command: String
        var domain: String
        let directory: URL
        let framework: ServiceType
        /// What the domain was when the sheet opened. A rename only moves a row
        /// still sitting on its generated name, and this is how that is judged.
        let originalDomain: String

        init(_ service: Service) {
            id = service.id
            name = service.name
            command = service.command
            domain = service.domain.value
            directory = service.directory
            framework = service.framework
            originalDomain = service.domain.value
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.separator)
            Scrollable {
                VStack(spacing: 10) {
                    projectCard
                    ForEach($rows) { $row in
                        ServiceEditor(row: $row, clash: clash(for: row))
                    }
                }
                .padding(14)
            }
            Divider().overlay(Theme.separator)
            footer
        }
        .frame(width: 620, height: 560)
        .background(Theme.background)
        .themedSurface(state.appearance.colorScheme)
        .alert("Restart to use the new domain?", isPresented: $isConfirmingRestart) {
            Button("Not Now", role: .cancel) { dismiss() }
            Button("Restart") {
                let services = pendingRestarts
                Task {
                    await state.restartForNewDomain(services)
                    dismiss()
                }
            }
        } message: {
            Text(restartMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { presentIconPicker() } label: {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.card)
                    .frame(width: 36, height: 36)
                    .overlay(
                        ServiceIconView(
                            type: project.services.first?.framework ?? .unknown,
                            projectIconPath: iconPath ?? state.detectedIcons[project.id],
                            size: 22
                        )
                    )
            }
            .buttonStyle(.plain)
            .help("Change icon")
            .popover(isPresented: $isPickingIcon, arrowEdge: .bottom) {
                IconPickerView(
                    projectName: projectName,
                    projectDirectory: project.directory,
                    assets: assets,
                    currentPath: iconPath
                ) { picked in
                    iconPath = picked
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Edit project")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text(project.displayPath)
                    .font(.lfSubtitle)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            IconButton(symbol: "xmark", help: "Close") { dismiss() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var projectCard: some View {
        DetailCard(title: "PROJECT", symbol: "shippingbox") {
            VStack(alignment: .leading, spacing: 8) {
                LabelledField(label: "Name", text: $projectName)
                    .onChange(of: projectName) { old, new in suggestDomains(from: old, to: new) }
                CardDivider()
                LabeledRow(label: "Directory", value: project.displayPath)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            ActionButton(title: "Cancel") { dismiss() }
            ActionButton(title: "Save Changes", symbol: "checkmark", isPrimary: true) { save() }
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Renaming

    /// Suggests, never forces. A domain the user typed is theirs, and a rename
    /// silently rewriting it is the one thing this must not do, so only a row
    /// still sitting on the name the scan generated is moved.
    private func suggestDomains(from old: String, to new: String) {
        let oldSlug = LocalDomain.slug(old)
        let newSlug = LocalDomain.slug(new)
        guard oldSlug != newSlug, !newSlug.isEmpty else { return }

        let names = rows.map(\.directory.lastPathComponent)
        let apexIndex = rows.firstIndex { $0.originalDomain == "\(LocalDomain.slug(project.name)).localhost" }
        let generated = ProjectDomains.hosts(directoryNames: names, projectSlug: oldSlug, apexIndex: apexIndex)
        let suggested = ProjectDomains.hosts(directoryNames: names, projectSlug: newSlug, apexIndex: apexIndex)

        for index in rows.indices where rows[index].domain == generated[index] {
            rows[index].domain = suggested[index]
        }
    }

    // MARK: - Validation

    private var editedIDs: Set<UUID> { Set(rows.map(\.id)) }

    private var canSave: Bool {
        guard !projectName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return rows.allSatisfy {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
                && LocalDomain($0.domain) != nil
                && clash(for: $0) == nil
        }
    }

    private func clash(for row: EditableService) -> String? {
        guard let domain = LocalDomain(row.domain) else { return nil }
        if let existing = state.domainOwner(of: domain, excluding: editedIDs) {
            return "Already used by \(existing.name)"
        }
        let duplicates = rows.filter { $0.domain.lowercased() == row.domain.lowercased() }
        return duplicates.count > 1 ? "Used twice in this project" : nil
    }

    // MARK: - Saving

    private func save() {
        var edited = project
        edited.name = projectName.trimmingCharacters(in: .whitespaces)
        edited.iconPath = iconPath.map { edited.iconPathValue(for: URL(fileURLWithPath: $0)) }
        edited.services = project.services.map { service in
            guard let row = rows.first(where: { $0.id == service.id }),
                  let domain = LocalDomain(row.domain) else { return service }
            var updated = service
            updated.name = row.name.trimmingCharacters(in: .whitespaces)
            updated.command = row.command
            updated.domain = domain
            return updated
        }

        Task {
            let moved = await state.apply(edited)
            guard !moved.isEmpty else {
                dismiss()
                return
            }
            pendingRestarts = moved
            isConfirmingRestart = true
        }
    }

    private var restartMessage: String {
        let names = pendingRestarts.map(\.name).joined(separator: ", ")
        return "\(names) \(pendingRestarts.count == 1 ? "is" : "are") still running on the old domain. "
            + "Localfox passes the domain to a service when it starts, so it needs a restart to use the new one."
    }

    /// Scanned on click rather than on redraw, because this sheet redraws on
    /// every keystroke in the name field.
    private func presentIconPicker() {
        assets = state.projectAssets(for: project)
        isPickingIcon = true
    }
}

/// One service, with every editable value.
private struct ServiceEditor: View {
    @Binding var row: EditProjectSheet.EditableService
    let clash: String?

    var body: some View {
        DetailCard(title: "SERVICE", symbol: "square.stack.3d.up") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ServiceIconView(type: row.framework, size: Theme.Metrics.serviceIconSmall)
                    TextField("", text: $row.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Spacer(minLength: 0)
                    StatusPill(text: row.framework.displayName)
                }
                CardDivider()
                LabelledField(label: "Command", text: $row.command, monospaced: true)
                LabelledField(label: "Domain", text: $row.domain, monospaced: true, error: fieldError)
            }
        }
    }

    private var fieldError: String? {
        if let clash { return clash }
        guard !row.domain.isEmpty else { return nil }
        return LocalDomain(row.domain) == nil ? "Must be a valid .localhost name" : nil
    }
}
