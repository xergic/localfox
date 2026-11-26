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
    @State private var isSaving = false
    @State private var saveError: String?

    init(project: Project) {
        self.project = project
        _projectName = State(initialValue: project.name)
        _iconPath = State(initialValue: project.iconURL?.path)
        _rows = State(initialValue: project.services.map(EditableService.init))
    }

    /// A token that is already saved is shown as this and never as itself.
    ///
    /// Reading a stored credential back into a text field only to write it
    /// straight back puts it in the view hierarchy for no gain. A row that still
    /// holds the placeholder is a row the user did not touch, which is how `save`
    /// knows to leave the Keychain alone.
    nonisolated static let tokenPlaceholder = "••••••••"

    /// The SSH block of the edit sheet, still as typed.
    ///
    /// Strings rather than an `SSHTunnelTarget` because a half-filled form is
    /// the normal state of one, and a model that can only hold valid values has
    /// nowhere to put "the user is still typing the port".
    struct SSHFields: Equatable {
        var host = ""
        var user = ""
        var sshPort = ""
        var remotePort = ""
        var keyPath = ""
        var publicURL = ""

        /// Everything a share needs, or nil while these fields do not describe
        /// one yet. One definition, so the validator and the save agree on what
        /// counts as configured.
        var target: SSHTunnelTarget? {
            let host = host.trimmingCharacters(in: .whitespaces)
            let user = user.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, !user.isEmpty,
                  let remote = Int(remotePort.trimmingCharacters(in: .whitespaces)),
                  (1...65_535).contains(remote)
            else { return nil }

            let trimmedSSHPort = sshPort.trimmingCharacters(in: .whitespaces)
            let port = trimmedSSHPort.isEmpty ? 22 : Int(trimmedSSHPort)
            guard let port, (1...65_535).contains(port) else { return nil }

            let address = publicURL.trimmingCharacters(in: .whitespaces)
            let resolved = address.isEmpty
                ? SSHTunnelTarget.defaultPublicURL(host: host, remotePort: remote)
                : URL(string: address.contains("://") ? address : "http://\(address)")
            guard let resolved, let hostname = resolved.host, !hostname.isEmpty,
                  ["http", "https"].contains(resolved.scheme?.lowercased()),
                  resolved.user == nil, resolved.password == nil else { return nil }

            let key = keyPath.trimmingCharacters(in: .whitespaces)
            return SSHTunnelTarget(
                host: host,
                user: user,
                sshPort: port,
                remotePort: remote,
                keyPath: key.isEmpty ? nil : key,
                publicURL: resolved
            )
        }

        /// True once the user has started filling this block in.
        var isTouched: Bool {
            [host, user, sshPort, remotePort, keyPath, publicURL].contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }

        init(_ target: SSHTunnelTarget? = nil) {
            guard let target else { return }
            host = target.host
            user = target.user
            sshPort = target.sshPort == 22 ? "" : String(target.sshPort)
            remotePort = String(target.remotePort)
            keyPath = target.keyPath ?? ""
            publicURL = target.publicURL.absoluteString
        }
    }

    /// A service the user is still editing. Separate from `Service` so a
    /// half-typed domain never has to be a valid `LocalDomain`.
    struct EditableService: Identifiable {
        let id: UUID
        var name: String
        var command: String
        var domain: String
        let directory: URL?
        let framework: ServiceType
        let kind: ServiceKind
        var port: String
        let isNew: Bool
        /// The public hostname of a named Cloudflare tunnel, or blank for none.
        var namedHostname = ""
        var namedToken = ""
        /// The SSH reverse tunnel, blank for none.
        var ssh = SSHFields()
        var hasLaunchTarget: Bool {
            kind == .portRoute ? Service.routablePort(from: port) != nil : !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var sharingError: String? {
            let hostname = namedHostname.trimmingCharacters(in: .whitespacesAndNewlines)
            let token = namedToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if hostname.isEmpty {
                if !token.isEmpty, token != EditProjectSheet.tokenPlaceholder { return "Enter the hostname for this token" }
            } else {
                guard TunnelTargets.url(from: hostname) != nil else { return "Enter a public HTTPS hostname" }
                guard Service.routablePort(from: port) != nil else { return "Enter a fixed port for this tunnel" }
                guard !token.isEmpty else { return "Enter the tunnel token" }
            }
            return nil
        }

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
            kind = service.kind
            port = service.portMode.fixedValue.map(String.init) ?? ""
            isNew = false
            originalDomain = service.domain.value
        }

        private init(newRouteID id: UUID) {
            self.id = id
            name = ""
            command = ""
            domain = ""
            directory = nil
            framework = .unknown
            kind = .portRoute
            port = ""
            isNew = true
            originalDomain = ""
        }

        static func newRoute() -> EditableService { EditableService(newRouteID: UUID()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.separator)
            Scrollable {
                VStack(spacing: 10) {
                    projectCard
                    ForEach($rows) { $row in
                        ServiceEditor(row: $row, clash: clash(for: row)) {
                            rows.removeAll { $0.id == row.id }
                        }
                    }
                    HStack {
                        ActionButton(title: "Add Port Route", symbol: "plus") { rows.append(.newRoute()) }
                        Spacer(minLength: 0)
                    }
                }
                .padding(14)
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
        .onAppear(perform: loadTunnelTargets)
        .alert("Restart to apply the changes?", isPresented: $isConfirmingRestart) {
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
                            isPortRoute: project.services.allSatisfy { $0.kind == .portRoute },
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
                Text(project.displayPath ?? "")
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

    private var projectCard: some View {
        DetailCard(title: "Project") {
            VStack(alignment: .leading, spacing: 8) {
                LabelledField(label: "Name", text: $projectName)
                    .onChange(of: projectName) { old, new in suggestDomains(from: old, to: new) }
                CardDivider()
                LabeledRow(label: "Directory", value: project.displayPath ?? "None")
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

    /// Reads what is already configured, without ever reading the token itself.
    private func loadTunnelTargets() {
        for index in rows.indices {
            let id = rows[index].id
            if let hostname = state.tunnelTargets.hostname(for: id) {
                rows[index].namedHostname = hostname.host ?? hostname.absoluteString
                rows[index].namedToken = state.tunnelTargets.isConfigured(id)
                    ? Self.tokenPlaceholder
                    : ""
            }
            rows[index].ssh = SSHFields(state.tunnelTargets.ssh(for: id))
        }
    }

    // MARK: - Renaming

    /// Suggests, never forces. A domain the user typed is theirs, and a rename
    /// silently rewriting it is the one thing this must not do, so only a row
    /// still sitting on the name the scan generated is moved.
    private func suggestDomains(from old: String, to new: String) {
        let oldSlug = LocalDomain.slug(old)
        let newSlug = LocalDomain.slug(new)
        guard oldSlug != newSlug, !newSlug.isEmpty else { return }

        let commandIndices = rows.indices.filter { rows[$0].kind == .command }
        let names = commandIndices.map { rows[$0].directory?.lastPathComponent ?? rows[$0].name }
        let apexIndex = commandIndices.firstIndex {
            rows[$0].originalDomain == "\(LocalDomain.slug(project.name)).localhost"
        }
        let generated = ProjectDomains.hosts(directoryNames: names, projectSlug: oldSlug, apexIndex: apexIndex)
        let suggested = ProjectDomains.hosts(directoryNames: names, projectSlug: newSlug, apexIndex: apexIndex)

        for (position, index) in commandIndices.enumerated() where rows[index].domain == generated[position] {
            rows[index].domain = suggested[position]
        }
    }

    // MARK: - Validation

    private var editedIDs: Set<UUID> { Set(project.services.map(\.id)).union(rows.map(\.id)) }

    private var canSave: Bool {
        guard !projectName.trimmingCharacters(in: .whitespaces).isEmpty, !rows.isEmpty else { return false }
        return rows.allSatisfy {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
                && LocalDomain($0.domain) != nil
                && clash(for: $0) == nil
                && AddRouteSheet.portError(for: $0.port) == nil
                && $0.hasLaunchTarget
                && $0.sharingError == nil
                && (!$0.ssh.isTouched || $0.ssh.target != nil)
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
        guard canSave, !isSaving else { return }
        var edited = project
        edited.name = projectName.trimmingCharacters(in: .whitespaces)
        edited.iconPath = iconPath.map { edited.iconPathValue(for: URL(fileURLWithPath: $0)) }
        let existing = Dictionary(uniqueKeysWithValues: project.services.map { ($0.id, $0) })
        edited.services = rows.compactMap { row in
            guard let domain = LocalDomain(row.domain) else { return nil }
            let name = row.name.trimmingCharacters(in: .whitespaces)
            let port = Service.routablePort(from: row.port)
            if row.isNew {
                guard let port else { return nil }
                return Service.portRoute(name: name, domain: domain, port: port, directory: project.directory)
            }
            guard var updated = existing[row.id] else { return nil }
            updated.name = name
            updated.command = row.command
            updated.domain = domain
            updated.portMode = port.map(PortMode.fixed) ?? .auto
            return updated
        }

        isSaving = true
        let changes = rows.compactMap(tunnelChange)
        Task {
            defer { isSaving = false }
            do {
                let moved = try await state.apply(edited, replacing: project, sharingChanges: changes)
                if moved.isEmpty {
                    dismiss()
                } else {
                    pendingRestarts = moved
                    isConfirmingRestart = true
                }
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    /// Keep an unchanged masked credential out of both the view and the save.
    private func tunnelChange(for row: EditableService) -> TunnelTargets.Change? {
        guard row.kind == .command else { return nil }
        let previous = state.tunnelTargets.hostname(for: row.id)
        let hostname = TunnelTargets.url(from: row.namedHostname)
        let token: String?
        if hostname == nil {
            token = previous == nil ? nil : ""
        } else {
            token = row.namedToken == Self.tokenPlaceholder ? nil : row.namedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let ssh = row.ssh.target
        guard token != nil || hostname != previous || ssh != state.tunnelTargets.ssh(for: row.id) else { return nil }
        return .init(id: row.id, hostname: hostname, token: token, ssh: ssh)
    }

    private var restartMessage: String {
        let names = pendingRestarts.map(\.name).joined(separator: ", ")
        return "Restart \(names) to use the updated domain or port."
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
    let onRemove: () -> Void

    private var isRoute: Bool { row.kind == .portRoute }

    var body: some View {
        DetailCard(
            title: isRoute ? "Route" : "Service",
            symbol: isRoute ? "arrow.left.arrow.right" : "square.stack.3d.up"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ServiceIconView(type: row.framework, isPortRoute: isRoute, size: Theme.Metrics.serviceIconSmall)
                    TextField("", text: $row.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Spacer(minLength: 0)
                    if isRoute {
                        IconButton(symbol: "trash", help: "Remove route", action: onRemove)
                    } else {
                        TintedBadge(text: row.framework.displayName, tint: Theme.secondaryText)
                    }
                }
                CardDivider()
                if isRoute {
                    LabelledField(
                        label: "Port",
                        text: $row.port,
                        monospaced: true,
                        error: AddRouteSheet.portError(for: row.port)
                    )
                } else {
                    LabelledField(label: "Command", text: $row.command, monospaced: true)
                    LabelledField(
                        label: "Fixed port (blank for Auto)", text: $row.port, monospaced: true,
                        error: AddRouteSheet.portError(for: row.port)
                    )
                }
                LabelledField(label: "Domain", text: $row.domain, monospaced: true, error: fieldError)
                if !isRoute {
                    CardDivider()
                    sharing
                }
            }
        }
    }

    /// The named tunnel, which is configuration rather than a project fact: the
    /// hostname lives in preferences and the token in the Keychain, so neither
    /// travels with a copied project.
    @ViewBuilder
    private var sharing: some View {
        Text("Public sharing")
            .font(.lfDetailStrong)
            .foregroundStyle(Theme.secondaryText)
        LabelledField(
            label: "Cloudflare hostname",
            text: $row.namedHostname,
            monospaced: true,
            error: row.sharingError
        )
        LabelledField(label: "Tunnel token", text: $row.namedToken, isSecure: true)
        Text(hint)
            .font(.system(size: 10))
            .foregroundStyle(Theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        CardDivider()
        ssh
    }

    /// A reverse forward to a machine the user already owns. Works under Auto,
    /// unlike a named tunnel, because the local port is filled in at share time.
    @ViewBuilder
    private var ssh: some View {
        HStack(spacing: 8) {
            LabelledField(label: "SSH host", text: $row.ssh.host, monospaced: true)
            LabelledField(label: "User", text: $row.ssh.user, monospaced: true)
        }
        HStack(spacing: 8) {
            LabelledField(label: "SSH port", text: $row.ssh.sshPort, monospaced: true)
            LabelledField(
                label: "Remote port",
                text: $row.ssh.remotePort,
                monospaced: true,
                error: sshError
            )
        }
        LabelledField(label: "Identity file", text: $row.ssh.keyPath, monospaced: true)
        LabelledField(label: "Public address", text: $row.ssh.publicURL, monospaced: true)
        Text("""
        The remote sshd needs `GatewayPorts yes`, or the forward only listens on \
        the server's own loopback. Leave the address blank for \
        http://host:remote-port, and fill it in if you terminate TLS there.
        """)
        .font(.system(size: 10))
        .foregroundStyle(Theme.tertiaryText)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Says nothing until the row is a half-filled target, because a blank block
    /// is the normal state for most services.
    private var sshError: String? {
        guard row.ssh.isTouched, row.ssh.target == nil else { return nil }
        return "Enter the host, user, valid ports and an HTTP or HTTPS public address"
    }

    private var hint: String {
        return """
        Create the tunnel in Cloudflare Zero Trust, point its public hostname \
        at http://localhost:<port>, then paste the tunnel token here. Leave \
        the hostname blank to remove it.
        """
    }

    private var fieldError: String? {
        if let clash { return clash }
        guard !row.domain.isEmpty else { return nil }
        return LocalDomain(row.domain) == nil ? "Must be a valid .localhost name" : nil
    }
}
