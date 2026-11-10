import CryptoKit
import Foundation

/// A project's services, re-rooted onto one of its git worktrees.
///
/// Derived on every discovery and never saved. A worktree that is removed
/// simply stops being derived.
public struct WorktreeCheckout: Identifiable, Hashable, Sendable {
    public let projectID: UUID
    public let directory: URL
    public let label: String
    public var services: [Service]

    public init(projectID: UUID, directory: URL, label: String, services: [Service]) {
        self.projectID = projectID
        self.directory = directory
        self.label = label
        self.services = services
    }

    public var id: String { directory.path }

    public func service(id: UUID) -> Service? {
        services.first { $0.id == id }
    }

    /// Narrowed the way `[Project].matching` narrows a project, with the label
    /// standing in for the project name. nil when nothing is left.
    public func matching(_ query: String, port: (Service) -> Int? = { _ in nil }) -> WorktreeCheckout? {
        let stand = Project(id: projectID, name: label, directory: directory, services: services)
        guard let narrowed = [stand].matching(query, port: port).first else { return nil }
        var copy = self
        copy.services = narrowed.services
        return copy
    }
}

public enum WorktreeServices {
    /// Flat, `<project>-<branch>.localhost` and `<dir>.<project>-<branch>.localhost`.
    /// Nested under the project's own domain, a cookie set for `wishfox.localhost`
    /// would reach every worktree, and a branch named `api` would take
    /// `api.wishfox.localhost` from the project's own API.
    ///
    /// `projectPath` is the project directory relative to the repository root,
    /// empty when the project is the root. A worktree whose domains collide with
    /// `taken` moves to `-2`, `-3` and so on, so routing never depends on order.
    public static func checkout(
        of project: Project,
        in worktree: GitWorktree,
        projectPath: String,
        taken: Set<LocalDomain>,
        directoryExists: (URL) -> Bool
    ) -> WorktreeCheckout? {
        guard let projectDirectory = project.directory else { return nil }
        let root = projectPath.isEmpty
            ? worktree.directory
            : worktree.directory.appendingPathComponent(projectPath, isDirectory: true)
        guard directoryExists(root) else { return nil }

        let sources: [(service: Service, directory: URL)] = project.services.compactMap { service in
            guard service.kind == .command, let directory = service.directory else { return nil }
            return (service, directory)
        }
        let projectSlug = LocalDomain.slug(project.name)
        let apexIndex = sources.firstIndex { $0.service.domain.value == "\(projectSlug).localhost" }
            ?? (sources.count == 1 ? 0 : nil)
        let rebased = sources.map { source in
            relativePath(of: source.directory, under: projectDirectory).map { path in
                path.isEmpty ? root : root.appendingPathComponent(path, isDirectory: true)
            }
        }
        let kept = sources.indices.filter { rebased[$0].map(directoryExists) == true }
        guard !kept.isEmpty else { return nil }
        let base = combinedSlug(project: projectSlug, branch: LocalDomain.slug(worktree.label))

        for attempt in 1...9 {
            let slug = attempt == 1 ? base : suffixed(base, attempt)
            let hosts = ProjectDomains.hosts(
                directoryNames: sources.map(\.directory.lastPathComponent),
                projectSlug: slug,
                apexIndex: apexIndex
            ).map(LocalDomain.init)
            let domains = kept.compactMap { hosts[$0] }
            guard domains.count == kept.count, taken.isDisjoint(with: domains) else { continue }

            let replacements = Dictionary(
                kept.map { (sources[$0].service.domain.value, hosts[$0]?.value ?? "") },
                uniquingKeysWith: { first, _ in first }
            )
            let services = kept.compactMap { index -> Service? in
                guard let directory = rebased[index], let domain = hosts[index] else { return nil }
                let parent = sources[index].service
                return Service(
                    id: serviceID(parent: parent.id, worktree: worktree.directory),
                    name: parent.name,
                    directory: directory,
                    framework: parent.framework,
                    command: parent.command,
                    domain: domain,
                    // A fixed port copied from the main checkout would clash with it.
                    portMode: .auto,
                    expectedPort: parent.expectedPort,
                    portFlagStyle: parent.portFlagStyle,
                    environment: parent.environment.mapValues { rewrite($0, replacing: replacements) },
                    kind: .command
                )
            }
            return WorktreeCheckout(
                projectID: project.id, directory: worktree.directory, label: worktree.label, services: services
            )
        }
        return nil
    }

    /// Stable across discoveries, because status, the runtime and the proxy all
    /// key by service id. A random id would orphan a running server the next time
    /// the popover opened.
    public static func serviceID(parent: UUID, worktree: URL) -> UUID {
        let name = "\(parent.uuidString)\n\(worktree.standardizedFileURL.path)"
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        // RFC 9562 version 8 and variant bits, so the value is a well-formed UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }

    /// `path` relative to `base`, empty when they are the same, nil when `path`
    /// lies outside it.
    public static func relativePath(of path: URL, under base: URL) -> String? {
        let path = path.standardizedFileURL.path
        let base = base.standardizedFileURL.path
        if path == base { return "" }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    /// The project keeps up to 20 characters however long the branch is, so two
    /// long branches of different projects still read as different projects.
    static func combinedSlug(project: String, branch: String) -> String {
        let branch = branch.isEmpty ? "worktree" : branch
        guard !project.isEmpty else { return trimmed(branch.prefix(labelLimit)) }
        let room = labelLimit - 1
        let projectPart = trimmed(project.prefix(max(room - branch.count, min(project.count, 20))))
        let branchPart = trimmed(branch.prefix(room - projectPart.count))
        return branchPart.isEmpty ? projectPart : "\(projectPart)-\(branchPart)"
    }

    private static let labelLimit = 63

    private static func suffixed(_ base: String, _ attempt: Int) -> String {
        let suffix = "-\(attempt)"
        return trimmed(base.prefix(labelLimit - suffix.count)) + suffix
    }

    private static func trimmed(_ text: Substring) -> String {
        var text = text
        while text.hasSuffix("-") { text = text.dropLast() }
        return String(text)
    }

    /// Replaces whole hosts only. `wishfox.localhost` inside `api.wishfox.localhost`
    /// or `mywishfox.localhost` is a different host and stays as it is.
    static func rewrite(_ value: String, replacing domains: [String: String]) -> String {
        let source = Array(value.utf8)
        let ordered = domains
            .sorted { $0.key.utf8.count > $1.key.utf8.count }
            .map { (Array($0.key.utf8), Array($0.value.utf8)) }
        var output: [UInt8] = []
        output.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            let startsHost = index == 0 || !isHostByte(source[index - 1], allowsDot: true)
            if startsHost, let (from, to) = ordered.first(where: { matches($0.0, in: source, at: index) }) {
                output += to
                index += from.count
            } else {
                output.append(source[index])
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func matches(_ needle: [UInt8], in source: [UInt8], at index: Int) -> Bool {
        let end = index + needle.count
        guard end <= source.count else { return false }
        for offset in needle.indices where lowercased(source[index + offset]) != needle[offset] { return false }
        return end == source.count || !isHostByte(source[end], allowsDot: false)
    }

    private static func isHostByte(_ byte: UInt8, allowsDot: Bool) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"):
            true
        case UInt8(ascii: "."):
            allowsDot
        default:
            false
        }
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }
}
