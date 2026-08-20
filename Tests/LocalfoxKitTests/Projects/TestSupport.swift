import Foundation
@testable import LocalfoxKit

/// Builds and tears down real directory trees for project-resolution tests, so
/// the resolver and manifest reader are exercised against actual filesystem
/// calls rather than mocks.
struct TempTree {
    let root: URL

    init() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("portfox-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func makeDirectory(_ path: String) -> URL {
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ contents: String, at path: String) {
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

func makeSnapshot(
    root: URL,
    name: String,
    iconPath: String? = nil,
    rootKind: ProjectSnapshot.RootKind = .directory
) -> ProjectSnapshot {
    ProjectSnapshot(root: root, serviceDirectory: root, name: name, rootKind: rootKind, iconPath: iconPath)
}
