import Foundation

public protocol FileSystemReading: Sendable {
    func exists(_ url: URL) -> Bool
    func isDirectory(_ url: URL) -> Bool
    func contentsOfDirectory(at url: URL) throws -> [String]
    func data(at url: URL) throws -> Data
}

public struct RealFileSystem: FileSystemReading {
    public init() {}

    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func contentsOfDirectory(at url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path)
    }

    public func data(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}

/// A small filesystem whose paths are represented by their UTF-8 contents.
public struct InMemoryFileSystem: FileSystemReading {
    private let files: [String: Data]
    private let directories: Set<String>

    public init(_ tree: [String: String]) {
        files = Dictionary(uniqueKeysWithValues: tree.map { path, contents in
            (Self.normalized(path), Data(contents.utf8))
        })
        directories = Set(tree.keys.flatMap { path in
            let normalized = Self.normalized(path)
            var ancestors: [String] = []
            var current = path.hasSuffix("/") ? normalized : URL(fileURLWithPath: normalized).deletingLastPathComponent().path
            while true {
                ancestors.append(current)
                let parent = URL(fileURLWithPath: current).deletingLastPathComponent().path
                guard parent != current else { return ancestors }
                current = parent
            }
        })
    }

    public func exists(_ url: URL) -> Bool {
        let path = Self.normalized(url.path)
        return files[path] != nil || directories.contains(path)
    }

    public func isDirectory(_ url: URL) -> Bool {
        let path = Self.normalized(url.path)
        return directories.contains(path)
    }

    public func contentsOfDirectory(at url: URL) throws -> [String] {
        let path = Self.normalized(url.path)
        guard isDirectory(url) else { throw CocoaError(.fileNoSuchFile) }
        let prefix = path == "/" ? "/" : path + "/"
        return Set(files.keys.compactMap { filePath in
            guard filePath.hasPrefix(prefix) else { return nil }
            let remainder = filePath.dropFirst(prefix.count)
            return remainder.split(separator: "/", maxSplits: 1).first.map(String.init)
        }).sorted()
    }

    public func data(at url: URL) throws -> Data {
        guard let data = files[Self.normalized(url.path)] else { throw CocoaError(.fileNoSuchFile) }
        return data
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

enum ManifestFileSystem {
    @TaskLocal static var current: any FileSystemReading = RealFileSystem()
}

/// Immutable directory facts shared by all cold-start detectors.
public struct DirectoryContext: Sendable {
    public let url: URL
    public let snapshot: ProjectSnapshot
    public let entries: Set<String>
    public let lockfiles: Set<String>
    public let scripts: [String: String]
    public let packageManagerField: String?

    public init(url: URL, fileSystem: any FileSystemReading = RealFileSystem()) throws {
        guard fileSystem.isDirectory(url) else { throw CocoaError(.fileNoSuchFile) }
        self.url = url.standardizedFileURL
        entries = Set(try fileSystem.contentsOfDirectory(at: url))
        lockfiles = Set(PackageManager.lockfileNames.filter(entries.contains))
        snapshot = ProjectResolver(fileSystem: fileSystem).resolve(serviceDirectory: url)
            ?? ProjectSnapshot(root: url, serviceDirectory: url, name: url.lastPathComponent, files: entries, rootFiles: entries)
        scripts = snapshot.scripts
        packageManagerField = Self.packageManagerField(at: url, fileSystem: fileSystem)
    }

    public func detectionContext() -> DetectionContext {
        DetectionContext(
            process: ProcessSnapshot(pid: 0, parentPID: 0, uid: 0),
            project: snapshot,
            ports: []
        )
    }

    private static func packageManagerField(at url: URL, fileSystem: any FileSystemReading) -> String? {
        guard let data = try? fileSystem.data(at: url.appendingPathComponent("package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["packageManager"] as? String
    }
}
