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
        let directory: URL
        let framework: ServiceType
        let evidence: [String]
        let expectedPort: Int?
        let isApex: Bool
    }

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
            footer
        }
        .frame(width: 620, height: 560)
        .background(Theme.background)
        .themedSurface(state.appearance.colorScheme)
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.card)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.accentText)
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
            IconButton(symbol: "xmark", help: "Close") { dismiss() }
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
                DetailCard(title: "PROJECT", symbol: "shippingbox") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabelledField(label: "Name", text: $projectName)
                        CardDivider()
                        LabeledRow(
                            label: "Package manager",
                            value: "\(scan.packageManager.packageManager.displayName)  (\(scan.packageManager.reason))"
                        )
                        if scan.isWorkspace {
                            CardDivider()
                            LabeledRow(label: "Workspace", value: "yes, \(candidates.count) runnable packages")
                        }
                    }
                }

                if candidates.isEmpty {
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
        candidates = result.candidates.map {
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
        isScanning = false
    }

    private var selected: [EditableService] { candidates.filter(\.isSelected) }

    private var canSave: Bool {
        guard scan != nil, !projectName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !selected.isEmpty else { return false }
        return selected.allSatisfy { LocalDomain($0.domain) != nil && clash(for: $0) == nil }
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
        guard let scan else { return }
        let services = selected.compactMap { candidate -> Service? in
            guard let domain = LocalDomain(candidate.domain) else { return nil }
            return Service(
                name: candidate.name,
                directory: candidate.directory,
                framework: candidate.framework,
                command: candidate.command,
                domain: domain,
                expectedPort: candidate.expectedPort,
                portFlagStyle: candidate.framework.portFlagStyle
            )
        }
        state.add(Project(name: projectName, directory: scan.root, services: services))
        dismiss()
    }
}

/// One candidate, with every detected value editable.
private struct ServiceEditor: View {
    @Binding var candidate: AddProjectSheet.EditableService
    let clash: String?

    var body: some View {
        DetailCard(
            title: candidate.isApex ? "SERVICE  ·  MAIN" : "SERVICE",
            symbol: candidate.isSelected ? "checkmark.circle.fill" : "circle"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Toggle("", isOn: $candidate.isSelected)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    TextField("", text: $candidate.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Spacer(minLength: 0)
                    StatusPill(text: candidate.framework.displayName)
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
