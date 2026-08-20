import Foundation

/// A service Localfox proposes after scanning a directory.
///
/// Everything here is a suggestion the user can edit before it is saved, which
/// is what spec section 7 means by "all detected values must be editable".
public struct CandidateService: Identifiable, Sendable {
    public let id = UUID()
    public var name: String
    public var directory: URL
    public var framework: ServiceType
    public var confidence: Double
    /// Rendered verbatim under "Detected:", so the user can see why.
    public var evidence: [String]
    public var script: String?
    public var command: String
    public var domain: LocalDomain
    public var expectedPort: Int?
    /// Whether this one is ticked when the sheet opens.
    public var isSelected: Bool
    /// The bare `<project>.localhost` rather than a subdomain.
    public var isApex: Bool

    public func service() -> Service {
        Service(
            name: name,
            directory: directory,
            framework: framework,
            command: command,
            domain: domain,
            expectedPort: expectedPort,
            portFlagStyle: framework.portFlagStyle
        )
    }
}

public struct ProjectScan: Sendable {
    public var name: String
    public var root: URL
    public var packageManager: PackageManagerResolution
    public var isWorkspace: Bool
    public var candidates: [CandidateService]
    public var warnings: [String]

    public func project() -> Project {
        Project(
            name: name,
            directory: root,
            services: candidates.filter(\.isSelected).map { $0.service() }
        )
    }
}

/// Turns a directory the user picked into something Localfox can run.
public struct ProjectScanner: Sendable {
    private let fileSystem: any FileSystemReading
    private let engine: DetectionEngine

    public init(
        fileSystem: any FileSystemReading = RealFileSystem(),
        engine: DetectionEngine = DetectionEngine()
    ) {
        self.fileSystem = fileSystem
        self.engine = engine
    }

    /// Names that say nothing about the service, so a subdomain built from them
    /// would collide across projects.
    private static let genericDirectoryNames: Set<String> = [
        "app", "src", "source", "packages", "apps"
    ]

    /// Members that usually want a subdomain, ticked by default alongside the apex.
    private static let interestingNames: Set<String> = [
        "api", "admin", "backend", "server", "docs", "dashboard", "studio"
    ]

    public func scan(directory: URL) throws -> ProjectScan {
        let root = directory.standardizedFileURL
        let context = try DirectoryContext(url: root, fileSystem: fileSystem)
        let manager = PackageManagerDetector(fileSystem: fileSystem).resolve(in: root)

        let members = workspaceMembers(of: context, root: root)
        let isWorkspace = !members.isEmpty
        let projectName = context.snapshot.name
        let projectSlug = LocalDomain.slug(projectName)

        var warnings: [String] = []
        var candidates: [CandidateService] = []

        let directories = isWorkspace ? members : [root]
        for memberDirectory in directories {
            guard let candidate = candidate(
                at: memberDirectory,
                root: root,
                projectSlug: projectSlug,
                manager: manager.packageManager
            ) else { continue }
            candidates.append(candidate)
        }

        if candidates.isEmpty {
            warnings.append(
                isWorkspace
                    ? "No workspace package has a development script."
                    : "No development script in package.json. Set the command by hand."
            )
        }

        candidates = assignDomains(candidates, projectSlug: projectSlug)
        return ProjectScan(
            name: projectName,
            root: root,
            packageManager: manager,
            isWorkspace: isWorkspace,
            candidates: candidates,
            warnings: warnings
        )
    }

    // MARK: - Members

    /// Expands the workspace globs one level, which covers `apps/*` and
    /// `packages/*`. A member with no development script is dropped, because
    /// otherwise a monorepo offers fourteen services and only three are runnable.
    private func workspaceMembers(of context: DirectoryContext, root: URL) -> [URL] {
        let patterns = context.workspaceGlobs
        guard !patterns.isEmpty else { return [] }

        var found: [URL] = []
        for pattern in patterns {
            let parts = pattern.split(separator: "/", omittingEmptySubsequences: true)
            guard let last = parts.last else { continue }

            if last == "*" {
                let parent = parts.dropLast().reduce(root) { $0.appendingPathComponent(String($1)) }
                let names = (try? fileSystem.contentsOfDirectory(at: parent)) ?? []
                for name in names.sorted() where !name.hasPrefix(".") {
                    let candidate = parent.appendingPathComponent(name, isDirectory: true)
                    if fileSystem.isDirectory(candidate) { found.append(candidate) }
                }
            } else {
                let candidate = parts.reduce(root) { $0.appendingPathComponent(String($1)) }
                if fileSystem.isDirectory(candidate) { found.append(candidate) }
            }
        }
        return found
    }

    private func candidate(
        at directory: URL,
        root: URL,
        projectSlug: String,
        manager: PackageManager
    ) -> CandidateService? {
        guard let context = try? DirectoryContext(url: directory, fileSystem: fileSystem) else {
            return nil
        }
        let detection = engine.detect(context.detectionContext())
        guard let script = CommandBuilder.preferredScript(
            in: context.scripts, framework: detection.type
        ) else { return nil }

        let basename = directory.lastPathComponent
        return CandidateService(
            name: Self.displayName(basename),
            directory: directory,
            framework: detection.type,
            confidence: detection.confidence,
            evidence: detection.evidence.filter(\.matched).map(\.description),
            script: script,
            command: CommandBuilder.devCommand(manager, script: script),
            // Replaced by assignDomains once the apex is known.
            domain: LocalDomain("\(projectSlug).localhost") ?? LocalDomain("localfox.localhost")!,
            expectedPort: detection.type.defaultPorts.first,
            isSelected: false,
            isApex: false
        )
    }

    // MARK: - Domains

    /// Picks one member for the bare `<project>.localhost` and gives everyone
    /// else `<slug>.<project>.localhost`.
    private func assignDomains(
        _ candidates: [CandidateService],
        projectSlug: String
    ) -> [CandidateService] {
        guard !candidates.isEmpty else { return candidates }

        var scored = candidates
        let apexIndex = scored.indices.max { left, right in
            apexScore(scored[left], projectSlug: projectSlug)
                < apexScore(scored[right], projectSlug: projectSlug)
        }

        var taken: Set<String> = []
        for index in scored.indices {
            let isApex = index == apexIndex
            let slug = LocalDomain.slug(scored[index].directory.lastPathComponent)
            var host = isApex ? "\(projectSlug).localhost" : "\(slug).\(projectSlug).localhost"

            // A monorepo can hold two packages whose directories slug the same
            // way, and two services on one domain make routing order-dependent.
            var suffix = 2
            while taken.contains(host) {
                host = "\(slug)-\(suffix).\(projectSlug).localhost"
                suffix += 1
            }
            taken.insert(host)

            scored[index].isApex = isApex
            scored[index].domain = LocalDomain(host) ?? scored[index].domain
            scored[index].isSelected = isApex
                || Self.interestingNames.contains(scored[index].directory.lastPathComponent.lowercased())
        }
        return scored
    }

    private func apexScore(_ candidate: CandidateService, projectSlug: String) -> Int {
        var score = 0
        let name = candidate.directory.lastPathComponent.lowercased()
        if name == "web" || candidate.directory.path.contains("/apps/web") { score += 50 }
        if LocalDomain.slug(name) == projectSlug { score += 40 }
        switch candidate.framework {
        case .nextJS, .nuxt, .svelteKit, .astro: score += 20
        default: break
        }
        if Self.interestingNames.contains(name) { score -= 30 }
        return score
    }

    static func displayName(_ raw: String) -> String {
        if raw.lowercased() == "api" { return "API" }
        guard let first = raw.first else { return raw }
        return first.uppercased() + raw.dropFirst()
    }
}
