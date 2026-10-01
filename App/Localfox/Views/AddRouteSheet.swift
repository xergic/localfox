import AppKit
import LocalfoxKit
import SwiftUI

struct AddRouteSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var scrolls = true
    @State private var name: String
    @State private var domain: String
    @State private var port: String
    @State private var directory: URL?
    @State private var domainWasEdited = false

    /// The prefill exists for the snapshot, which has no keyboard to type with.
    init(scrolls: Bool = true, name: String = "", domain: String = "", port: String = "") {
        self.scrolls = scrolls
        _name = State(initialValue: name)
        _domain = State(initialValue: domain)
        _port = State(initialValue: port)
    }

    private var parsedPort: Int? { Int(port.trimmingCharacters(in: .whitespaces)) }

    private var suggestedDomain: String {
        let slug = LocalDomain.slug(name)
        return slug.isEmpty ? "" : "\(slug).localhost"
    }

    static func portError(for text: String) -> String? {
        guard !text.isEmpty else { return nil }
        guard let port = Int(text.trimmingCharacters(in: .whitespaces)), Service.isRoutablePort(port) else {
            return "Use a port from 1 to 65535, other than 80 and 443"
        }
        return nil
    }

    private var portError: String? { Self.portError(for: port) }

    private var domainError: String? {
        guard !domain.isEmpty else { return nil }
        guard let value = LocalDomain(domain) else { return "Must be a valid .localhost name" }
        if let owner = state.domainOwner(of: value, excluding: []) { return "Already used by \(owner.name)" }
        return nil
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && LocalDomain(domain) != nil && domainError == nil
            && parsedPort != nil && portError == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.separator)
            Scrollable(scrolls: scrolls) {
                VStack(alignment: .leading, spacing: 14) {
                    DetailCard(title: "Route", symbol: "arrow.left.arrow.right") {
                        VStack(alignment: .leading, spacing: 8) {
                            LabelledField(label: "Name", text: $name)
                            LabelledField(label: "Domain", text: $domain, monospaced: true, error: domainError)
                            LabelledField(label: "Port", text: $port, monospaced: true, error: portError)
                            Text(
                                "Docker, an SSH forward or a server you started yourself. "
                                    + "Localfox routes the domain while 127.0.0.1:<port> accepts connections."
                            )
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            CardDivider()
                            folderRow
                        }
                    }
                }
                .padding(16)
            }
            Divider().overlay(Theme.separator)
            footer
        }
        .frame(width: 620, height: 560)
        .background(Theme.background)
        .themedSurface(state.appearance.colorScheme)
        .onChange(of: name) {
            if !domainWasEdited { domain = suggestedDomain }
        }
        .onChange(of: domain) {
            if domain != suggestedDomain { domainWasEdited = true }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.card)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.accentText)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("Route a port")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text("Give a port Localfox does not start a .localhost domain")
                    .font(.lfSubtitle)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            IconButton(symbol: "xmark", help: "Close") { dismiss() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var folderRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Text(directory?.path ?? "None")
                    .font(.lfSubtitle)
                    .foregroundStyle(directory == nil ? Theme.tertiaryText : Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            ActionButton(title: "Choose…") { chooseDirectory() }
            if directory != nil {
                ActionButton(title: "Clear") { directory = nil }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            ActionButton(title: "Cancel") { dismiss() }
            ActionButton(title: "Add Route", symbol: "plus", isPrimary: true) { save() }
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directory = url
    }

    private func save() {
        guard let value = LocalDomain(domain), let parsedPort,
              let route = Service.portRoute(name: name.trimmingCharacters(in: .whitespaces),
                                            domain: value, port: parsedPort, directory: directory)
        else { return }
        state.add(Project(name: route.name, directory: directory, services: [route]))
        dismiss()
    }
}
