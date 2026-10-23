import Foundation
import Testing

@testable import LocalfoxKit

@Suite("searching projects")
struct ProjectSearchTests {
    private let projects: [Project] = {
        let web = Service(
            name: "web", directory: nil, framework: .vite, command: "pnpm dev",
            domain: LocalDomain("wishfox.localhost")!
        )
        let api = Service(
            name: "api", directory: nil, framework: .vite, command: "bun run dev",
            domain: LocalDomain("api.wishfox.localhost")!
        )
        return [Project(name: "wishfox", directory: nil, services: [web, api])]
    }()

    @Test("a blank query keeps everything")
    func blankQuery() {
        #expect(projects.matching("  ") == projects)
    }

    @Test("a domain match keeps only that service")
    func domainMatch() {
        #expect(projects.matching("API.").first?.services.map(\.name) == ["api"])
    }

    @Test("a project name match keeps every service")
    func projectMatch() {
        #expect(projects.matching("wishfox").first?.services.count == 2)
    }

    @Test("a port range matches a running port inside it, ends included")
    func portRangeMatch() {
        let ports = { (service: Service) in service.name == "web" ? 5173 : nil }
        #expect(projects.matching("5000-5173", port: ports).first?.services.map(\.name) == ["web"])
        #expect(projects.matching("5000 - 6000", port: ports).first?.services.map(\.name) == ["web"])
        #expect(projects.matching("6000-5000", port: ports).isEmpty)
    }

    @Test("a port from the runtime matches")
    func portMatch() {
        let found = projects.matching("517") { $0.name == "web" ? 5173 : nil }
        #expect(found.first?.services.map(\.name) == ["web"])
    }

    @Test("no match drops the project")
    func noMatch() {
        #expect(projects.matching("django").isEmpty)
    }
}
