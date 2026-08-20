import Foundation

public enum PackageManager: String, Codable, Sendable, CaseIterable {
    case pnpm
    case bun
    case yarn
    case npm

    static let lockfileNames = ["pnpm-lock.yaml", "bun.lock", "bun.lockb", "yarn.lock", "package-lock.json"]
}

public struct PackageManagerResolution: Hashable, Sendable {
    public let packageManager: PackageManager
    public let reason: String

    public init(packageManager: PackageManager, reason: String) {
        self.packageManager = packageManager
        self.reason = reason
    }
}

public struct PackageManagerDetector: Sendable {
    private let fileSystem: any FileSystemReading

    public init(fileSystem: any FileSystemReading = RealFileSystem()) {
        self.fileSystem = fileSystem
    }

    public func resolve(in directory: URL) -> PackageManagerResolution {
        let ancestors = ancestors(of: directory)
        for ancestor in ancestors {
            if let field = packageManagerField(in: ancestor),
               let manager = PackageManager(rawValue: field.split(separator: "@", maxSplits: 1).first.map(String.init) ?? "") {
                return PackageManagerResolution(packageManager: manager, reason: "packageManager: \(field)")
            }
        }

        for ancestor in ancestors {
            guard let entries = try? fileSystem.contentsOfDirectory(at: ancestor) else { continue }
            for lockfile in PackageManager.lockfileNames where entries.contains(lockfile) {
                return PackageManagerResolution(packageManager: manager(for: lockfile), reason: lockfile)
            }
        }
        return PackageManagerResolution(packageManager: .npm, reason: "default")
    }

    public func detect(in directory: URL) -> PackageManagerResolution {
        resolve(in: directory)
    }

    private func packageManagerField(in directory: URL) -> String? {
        guard let data = try? fileSystem.data(at: directory.appendingPathComponent("package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["packageManager"] as? String
    }

    private func ancestors(of directory: URL) -> [URL] {
        var result: [URL] = []
        var current = directory.standardizedFileURL
        while true {
            result.append(current)
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return result }
            current = parent
        }
    }

    private func manager(for lockfile: String) -> PackageManager {
        switch lockfile {
        case "pnpm-lock.yaml": .pnpm
        case "bun.lock", "bun.lockb": .bun
        case "yarn.lock": .yarn
        default: .npm
        }
    }
}
