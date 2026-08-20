import Foundation

/// The on-disk configuration document.
///
/// Versioned from the first release. A store that starts unversioned can never
/// be migrated without guessing, and this file outlives every build that wrote it.
public struct StoreDocument: Codable, Sendable, Equatable {
    public static let currentVersion = 1

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
    private var hasLoaded = false

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
            hasLoaded = true
            return document.projects
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.unreadable(path: url.path, underlying: error.localizedDescription)
        }

        do {
            document = try JSONDecoder().decode(StoreDocument.self, from: data)
        } catch {
            throw StoreError.malformed(path: url.path, underlying: error.localizedDescription)
        }

        // Refuse rather than silently dropping fields a newer build wrote. The
        // failure mode this prevents is an older Localfox opening the file,
        // saving, and destroying configuration it never understood.
        guard document.version <= StoreDocument.currentVersion else {
            throw StoreError.fromTheFuture(
                path: url.path,
                found: document.version,
                supported: StoreDocument.currentVersion
            )
        }

        hasLoaded = true
        return document.projects
    }

    public func projects() -> [Project] { document.projects }

    public func save(_ projects: [Project]) throws {
        try Self.assertDomainsAreUnique(in: projects)
        document.projects = projects
        document.version = StoreDocument.currentVersion
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
