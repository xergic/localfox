import AppKit
import LocalfoxKit
import SwiftUI

/// Picks a directory, shows what Localfox found, and lets every value be edited
/// before anything is saved.
struct AddProjectSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var scan: ProjectScan?
    @State private var candidates: [EditableService] = []
    @State private var projectName = ""
    @State private var scanError: String?
    @State private var isScanning = false

    /// A candidate the user is still editing. Separate from `CandidateService`
    /// so a half-typed domain never has to be a valid `LocalDomain`.
    struct EditableService: Identifiable {
        let id: UUID
        var isSelected: Bool
        var name: String
        var domain: String
        var command: String
        var port = ""
        let directory: URL
        let framework: ServiceType
        let evidence: [String]
        let expectedPort: Int?
        let isApex: Bool

        var service: Service? {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let domain = LocalDomain(domain) else { return nil }
            let fixed = Service.routablePort(from: port)
            guard port.isEmpty || fixed != nil else { return nil }
            return Service(
                id: id, name: name, directory: directory, framework: framework, command: command, domain: domain,
                portMode: fixed.map(PortMode.fixed) ?? .auto, expectedPort: expectedPort, portFlagStyle: framework.portFlagStyle
            )
        }
    }

    @State private var saveError: String?
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.separator)

            if let scan {
                body(for: scan)
            } else {
                picker
            }

            Divider().overlay(Theme.separator)
            if let saveError { ErrorBanner(message: saveError) }
            footer
        }
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .frame(width: 620, height: 560)
        .background(Theme.background)
        .themedSurface(state.appearance.colorScheme)
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.accent)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("Add a project")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text(scan?.root.path ?? "Choose a directory to scan")
                    .font(.lfSubtitle)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            IconButton(
                symbol: "xmark",
                help: "Close",
                frameSize: Theme.Metrics.headerButtonSize,
                filled: true
            ) { dismiss() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var picker: some View {
        VStack(spacing: 12) {
            Spacer()
            if isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                EmptyStateView(
                    symbol: "folder",
                    message: "Choose the folder your project lives in",
                    hint: "Localfox reads package.json and its lockfile. It never writes to your project."
                )
                ActionButton(title: "Choose Folder…", symbol: "folder", isPrimary: true) {
                    chooseDirectory()
                }
            }
            if let scanError {
                ErrorBanner(message: scanError)
                    .padding(.horizontal, 20)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func body(for scan: ProjectScan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DetailCard(title: "Project") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabelledField(label: "Name", text: $projectName)
                        CardDivider()
                        LabeledRow(
                            label: "Package manager",
                            value: "\(scan.packageManager.packageManager.displayName)  (\(scan.packageManager.reason))",
                            valueFont: .lfDetail
                        )
                        if scan.isWorkspace {
                            CardDivider()
                            LabeledRow(label: "Workspace", value: "Yes, \(scan.candidates.count) runnable packages", valueFont: .lfDetail)
                        }
                    }
                }

                if scan.candidates.isEmpty {
                    ErrorBanner(message: scan.warnings.first ?? "Nothing runnable was found here.")
                }

                ForEach($candidates) { $candidate in
                    ServiceEditor(candidate: $candidate, clash: clash(for: candidate))
                }
            }
            .padding(16)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if scan != nil {
                ActionButton(title: "Choose Another…") { chooseDirectory() }
            }
            Spacer(minLength: 0)
            ActionButton(title: "Cancel") { dismiss() }
            ActionButton(title: "Add Project", isPrimary: true) { save() }
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        scan = nil
        candidates = []
        isScanning = true
        scanError = nil
        // Detached, because this view is main actor isolated and an inherited
        // Task would read every manifest on the main thread, freezing the window
        // for as long as the directory takes to walk.
        Task.detached(priority: .userInitiated) {
            do {
                let result = try ProjectScanner().scan(directory: url)
                await MainActor.run { adopt(result) }
            } catch {
                await MainActor.run {
                    scanError = "Could not scan \(url.lastPathComponent). \(error.localizedDescription)"
                    isScanning = false
                }
            }
        }
    }

    private func adopt(_ result: ProjectScan) {
        scan = result
        projectName = result.name
        candidates = Self.drafts(for: result)
        isScanning = false
    }

    static func drafts(for result: ProjectScan) -> [EditableService] {
        if result.candidates.isEmpty {
            let slug = LocalDomain.slug(result.name)
            let host = LocalDomain("\(slug).localhost")?.value ?? "app.localhost"
            return [EditableService(
                id: UUID(), isSelected: true, name: result.name, domain: host,
                command: "", directory: result.root, framework: .unknown,
                evidence: [], expectedPort: nil, isApex: true
            )]
        }
        return result.candidates.map {
            EditableService(
                id: $0.id,
                isSelected: $0.isSelected,
                name: $0.name,
                domain: $0.domain.value,
                command: $0.command,
                directory: $0.directory,
                framework: $0.framework,
                evidence: $0.evidence,
                expectedPort: $0.expectedPort,
                isApex: $0.isApex
            )
        }
    }

    private var selected: [EditableService] { candidates.filter(\.isSelected) }

    private var canSave: Bool {
        guard scan != nil, !projectName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !selected.isEmpty else { return false }
        return selected.allSatisfy { $0.service != nil && clash(for: $0) == nil }
    }

    /// Names the service already using a domain, so the clash is shown against
    /// the field rather than surfacing later as a failed save.
    private func clash(for candidate: EditableService) -> String? {
        guard candidate.isSelected, let domain = LocalDomain(candidate.domain) else { return nil }
        if let existing = state.domainOwner(of: domain, excluding: []) {
            return "Already used by \(existing.name)"
        }
        let duplicates = selected.filter { $0.domain.lowercased() == candidate.domain.lowercased() }
        return duplicates.count > 1 ? "Used twice in this project" : nil
    }

    private func save() {
        guard canSave, let scan else { return }
        let services = selected.compactMap(\.service)
        let project = Project(name: projectName, directory: scan.root, services: services)
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await state.add(project)
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}

/// One candidate, with every detected value editable.
private struct ServiceEditor: View {
    @Binding var candidate: AddProjectSheet.EditableService
    let clash: String?

    var body: some View {
        DetailCard(
            title: candidate.isApex ? "Main service" : "Service",
            symbol: candidate.isSelected ? "checkmark.circle.fill" : "circle"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    PreferenceCheckbox(isOn: $candidate.isSelected)
                    TextField("", text: $candidate.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Spacer(minLength: 0)
                    TintedBadge(text: candidate.framework.displayName, tint: Theme.secondaryText)
                }

                if !candidate.evidence.isEmpty {
                    Text(candidate.evidence.map { "✓ \($0)" }.joined(separator: "\n"))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                CardDivider()
                LabelledField(label: "Command", text: $candidate.command, monospaced: true)
                LabelledField(
                    label: "Fixed port (blank for Auto)", text: $candidate.port, monospaced: true,
                    error: AddRouteSheet.portError(for: candidate.port)
                )
                LabelledField(
                    label: "Domain",
                    text: $candidate.domain,
                    monospaced: true,
                    error: fieldError
                )
            }
            .opacity(candidate.isSelected ? 1 : 0.5)
        }
    }

    private var fieldError: String? {
        if let clash { return clash }
        guard candidate.isSelected, !candidate.domain.isEmpty else { return nil }
        return LocalDomain(candidate.domain) == nil ? "Must be a valid .localhost name" : nil
    }
}
