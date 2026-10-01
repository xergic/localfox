import Foundation

/// The on-disk configuration document.
///
/// Versioned from the first release. A store that starts unversioned can never
/// be migrated without guessing, and this file outlives every build that wrote it.
public struct StoreDocument: Codable, Sendable, Equatable {
    /// The highest version this build reads. 2 added ServiceKind and optional directories.
    /// A 1.x build reading a route would treat it as a command with an empty command line,
    /// so a file is written as 2 only when it holds one, and as 1 otherwise.
    public static let currentVersion = 2

    static func requiredVersion(for projects: [Project]) -> Int {
        let needsVersion2 = projects.contains { project in
            project.directory == nil
                || project.services.contains { $0.kind == .portRoute || $0.directory == nil }
        }
        return needsVersion2 ? 2 : 1
    }

    public var version: Int
    public var projects: [Project]

    public init(version: Int = StoreDocument.currentVersion, projects: [Project] = []) {
        self.version = version
        self.projects = projects
    }
}

public enum StoreError: Error, Equatable, Sendable, LocalizedError {
    case unreadable(path: String, underlying: String)
    case malformed(path: String, underlying: String)
    case fromTheFuture(path: String, found: Int, supported: Int)
    case unwritable(path: String, underlying: String)
    case duplicateDomain(String)
    case refusingToOverwrite(path: String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(path, underlying):
            "Could not read the Localfox configuration at \(path). \(underlying)"
        case let .malformed(path, underlying):
            "The Localfox configuration at \(path) is not valid. \(underlying)"
        case let .fromTheFuture(path, found, supported):
            """
            The Localfox configuration at \(path) was written by a newer version \
            (format \(found), this build understands \(supported)). Update Localfox \
            rather than letting it overwrite the file.
            """
        case let .unwritable(path, underlying):
            "Could not save the Localfox configuration to \(path). \(underlying)"
        case let .duplicateDomain(domain):
            "\(domain) is already used by another service. Every domain must be unique."
        case let .refusingToOverwrite(path):
            """
            Localfox could not read its configuration at \(path), so it will not save \
            over it. Fix or move the file, then relaunch Localfox.
            """
        }
    }
}

/// Reads and writes the project list.
///
/// An actor because the app saves on every edit while a background refresh can
/// be reading, and a torn write here loses the user's whole configuration.
public actor ProjectStore {
    public let url: URL

    private var document: StoreDocument
    /// Set when `load` threw. Saving after that would replace a file this build
    /// could not read with the empty list it fell back to, which is how a
    /// downgrade loses every project the newer build wrote.
    private var loadFailed = false

    public static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Localfox", isDirectory: true)
        return base.appendingPathComponent("projects.json")
    }

    public init(url: URL = ProjectStore.defaultURL()) {
        self.url = url
        document = StoreDocument()
    }

    public func load() throws -> [Project] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadFailed = false
            return document.projects
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            loadFailed = true
            throw StoreError.unreadable(path: url.path, underlying: error.localizedDescription)
        }

        do {
            document = try JSONDecoder().decode(StoreDocument.self, from: data)
        } catch {
            loadFailed = true
            throw StoreError.malformed(path: url.path, underlying: error.localizedDescription)
        }

        // Refuse rather than silently dropping fields a newer build wrote. The
        // failure mode this prevents is an older Localfox opening the file,
        // saving, and destroying configuration it never understood.
        guard document.version <= StoreDocument.currentVersion else {
            loadFailed = true
            throw StoreError.fromTheFuture(
                path: url.path,
                found: document.version,
                supported: StoreDocument.currentVersion
            )
        }

        loadFailed = false
        return document.projects
    }

    public func projects() -> [Project] { document.projects }

    public func save(_ projects: [Project]) throws {
        guard !loadFailed else { throw StoreError.refusingToOverwrite(path: url.path) }
        try Self.assertDomainsAreUnique(in: projects)
        document.projects = projects
        document.version = StoreDocument.requiredVersion(for: projects)
        try write()
    }

    /// Two services answering the same domain would make the proxy's behaviour
    /// depend on route ordering, so it is rejected at the point of saving
    /// rather than surfaced later as an inexplicable wrong page.
    public static func assertDomainsAreUnique(in projects: [Project]) throws {
        var seen: Set<String> = []
        for project in projects {
            for service in project.services {
                guard seen.insert(service.domain.value).inserted else {
                    throw StoreError.duplicateDomain(service.domain.value)
                }
            }
        }
    }

    private func write() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(document)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic, so a crash mid-write leaves the previous configuration
            // intact instead of a truncated file that fails to parse on launch.
            try data.write(to: url, options: .atomic)
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.unwritable(path: url.path, underlying: error.localizedDescription)
        }
    }
}
