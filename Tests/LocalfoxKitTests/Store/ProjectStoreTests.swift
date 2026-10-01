import Foundation
import Testing
@testable import LocalfoxKit

@Suite("persisting the project list")
struct ProjectStoreTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("localfox-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("projects.json")
    }

    private func service(_ name: String, domain: String) -> Service {
        Service(
            name: name,
            directory: URL(fileURLWithPath: "/Users/me/wishfox/apps/\(name.lowercased())"),
            framework: .nextJS,
            command: "pnpm dev",
            domain: LocalDomain(domain)!
        )
    }

    @Test("an absent file loads as an empty list rather than throwing")
    func absentFileIsEmpty() async throws {
        let store = ProjectStore(url: temporaryURL())
        #expect(try await store.load().isEmpty)
    }

    @Test("a saved list round-trips")
    func roundTrips() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let project = Project(
            name: "Wishfox",
            directory: URL(fileURLWithPath: "/Users/me/wishfox"),
            services: [service("Web", domain: "wishfox.localhost")]
        )
        try await ProjectStore(url: url).save([project])

        let reloaded = try await ProjectStore(url: url).load()
        #expect(reloaded == [project])
    }

    @Test("the written file records the format version")
    func writesVersion() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await ProjectStore(url: url).save([])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(json?["version"] as? Int == StoreDocument.currentVersion)
    }

    @Test("a project icon round-trips")
    func iconRoundTrips() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let project = Project(
            name: "Wishfox",
            directory: URL(fileURLWithPath: "/Users/me/wishfox"),
            services: [service("Web", domain: "wishfox.localhost")],
            iconPath: "public/favicon.svg"
        )
        try await ProjectStore(url: url).save([project])
        #expect(try await ProjectStore(url: url).load() == [project])
    }

    /// The store stays at version 1 only because a project on automatic writes
    /// exactly what it wrote before. A refactor to a hand-written `encode(to:)`
    /// that emitted `"iconPath": null` would silently break that, and every
    /// older build would start seeing a key it does not know.
    @Test("a project with no icon omits the key entirely")
    func omitsAbsentIcon() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let project = Project(
            name: "Wishfox",
            directory: URL(fileURLWithPath: "/Users/me/wishfox"),
            services: [service("Web", domain: "wishfox.localhost")]
        )
        try await ProjectStore(url: url).save([project])
        let written = String(data: try Data(contentsOf: url), encoding: .utf8)
        #expect(written?.contains("iconPath") == false)
    }

    @Test("a file written before icons existed still loads")
    func loadsDocumentWithoutIconKey() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let legacy = #"""
        {"version":1,"projects":[{
          "id":"686F0E2F-0F75-42A6-B72E-87CF0B01C289",
          "name":"Wishfox",
          "directory":"file:///Users/me/wishfox/",
          "services":[]
        }]}
        """#
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try await ProjectStore(url: url).load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.iconPath == nil)
    }

    /// The failure this prevents is an older build opening a newer file, saving,
    /// and destroying configuration it never understood.
    @Test("a file from a newer build is refused rather than overwritten")
    func refusesFutureVersions() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try #"{"version":99,"projects":[]}"#.write(to: url, atomically: true, encoding: .utf8)

        await #expect(throws: StoreError.self) {
            try await ProjectStore(url: url).load()
        }
    }

    @Test("a malformed file reports the path instead of a decoding trace")
    func malformedFileIsExplained() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "not json".write(to: url, atomically: true, encoding: .utf8)

        do {
            _ = try await ProjectStore(url: url).load()
            Issue.record("expected a malformed error")
        } catch let error as StoreError {
            #expect(error.errorDescription?.contains(url.path) == true)
        }
    }

    /// Two services on one domain would make the proxy depend on route order,
    /// which surfaces as an inexplicable wrong page rather than an error.
    @Test("two services cannot claim the same domain")
    func rejectsDuplicateDomains() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let projects = [
            Project(name: "A", directory: URL(fileURLWithPath: "/a"),
                    services: [service("Web", domain: "shared.localhost")]),
            Project(name: "B", directory: URL(fileURLWithPath: "/b"),
                    services: [service("API", domain: "shared.localhost")])
        ]

        await #expect(throws: StoreError.duplicateDomain("shared.localhost")) {
            try await ProjectStore(url: url).save(projects)
        }
    }

    @Test("a duplicate domain inside one project is caught too")
    func rejectsDuplicatesWithinAProject() async throws {
        let projects = [
            Project(name: "A", directory: URL(fileURLWithPath: "/a"), services: [
                service("Web", domain: "same.localhost"),
                service("API", domain: "same.localhost")
            ])
        ]
        #expect(throws: StoreError.self) {
            try ProjectStore.assertDomainsAreUnique(in: projects)
        }
    }

    @Test("a rejected save leaves the previous file untouched")
    func rejectedSaveDoesNotWrite() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let good = Project(name: "Wishfox", directory: URL(fileURLWithPath: "/w"),
                           services: [service("Web", domain: "wishfox.localhost")])
        let store = ProjectStore(url: url)
        try await store.save([good])

        let bad = Project(name: "Bad", directory: URL(fileURLWithPath: "/b"), services: [
            service("One", domain: "dup.localhost"),
            service("Two", domain: "dup.localhost")
        ])
        _ = try? await store.save([good, bad])

        #expect(try await ProjectStore(url: url).load() == [good])
    }

    @Test("a save after a failed load refuses rather than overwriting the file")
    func refusesToOverwriteUnreadable() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"version":99,"projects":[]}"#.utf8)
        try original.write(to: url)

        let store = ProjectStore(url: url)
        await #expect(throws: StoreError.self) { try await store.load() }
        await #expect(throws: StoreError.refusingToOverwrite(path: url.path)) { try await store.save([]) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("a standalone route with no directory round-trips")
    func routeRoundTrips() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let route = try #require(Service.portRoute(name: "Docker", domain: LocalDomain("docker.localhost")!, port: 8081, directory: nil))
        let project = Project(name: "Docker", directory: nil, services: [route])
        try await ProjectStore(url: url).save([project])
        #expect(try await ProjectStore(url: url).load() == [project])
    }
}
