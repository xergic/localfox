import Foundation
import Testing

@testable import LocalfoxKit

@Suite("deriving a worktree's services")
struct WorktreeServicesTests {
    private let root = URL(fileURLWithPath: "/repo/wishfox")
    private let worktreePath = URL(fileURLWithPath: "/repo/wishfox/.claude/worktrees/fix-cart")

    private func service(_ dir: String?, domain: String, kind: ServiceKind = .command, port: PortMode = .auto) -> Service {
        Service(
            name: dir ?? "web",
            directory: dir.map { $0.isEmpty ? root : root.appendingPathComponent($0) },
            framework: .nextJS,
            command: "pnpm dev",
            domain: LocalDomain(domain)!,
            portMode: port,
            expectedPort: 3000,
            portFlagStyle: .dashP,
            kind: kind
        )
    }

    private func monorepo() -> Project {
        Project(name: "Wishfox", directory: root, services: [
            service("apps/web", domain: "wishfox.localhost", port: .fixed(3000)),
            service("apps/api", domain: "api.wishfox.localhost"),
            service(nil, domain: "db.wishfox.localhost", kind: .portRoute, port: .fixed(5432))
        ])
    }

    private func derive(
        _ project: Project,
        branch: String? = "fix-cart",
        directory: URL? = nil,
        projectPath: String = "",
        taken: Set<LocalDomain> = [],
        missing: Set<String> = []
    ) -> WorktreeCheckout? {
        WorktreeServices.checkout(
            of: project,
            in: GitWorktree(directory: directory ?? worktreePath, branch: branch),
            projectPath: projectPath,
            taken: taken,
            directoryExists: { !missing.contains($0.path) }
        )
    }

    @Test("monorepo members get flat domains, with the apex on the bare combined slug")
    func flatMonorepoDomains() throws {
        let checkout = try #require(derive(monorepo()))
        #expect(checkout.services.map(\.domain.value) == [
            "wishfox-fix-cart.localhost",
            "api.wishfox-fix-cart.localhost"
        ])
        #expect(checkout.label == "fix-cart")
    }

    @Test("a single service is the apex even under a custom domain")
    func singleServiceIsApex() throws {
        let project = Project(name: "Wishfox", directory: root, services: [service("", domain: "shop.localhost")])
        let checkout = try #require(derive(project))
        #expect(checkout.services.map(\.domain.value) == ["wishfox-fix-cart.localhost"])
    }

    @Test("a slash in a branch becomes a hyphen")
    func slashInBranch() throws {
        let checkout = try #require(derive(monorepo(), branch: "fix/cart"))
        #expect(checkout.services.first?.domain.value == "wishfox-fix-cart.localhost")
        #expect(checkout.label == "fix/cart")
    }

    @Test("a detached worktree is named by its folder")
    func detachedUsesFolder() throws {
        let checkout = try #require(derive(monorepo(), branch: nil, directory: URL(fileURLWithPath: "/tmp/review-42")))
        #expect(checkout.services.first?.domain.value == "wishfox-review-42.localhost")
    }

    @Test("a long branch is cut to one 63 character label and the project stays readable")
    func longNames() throws {
        let branch = String(repeating: "very-long-branch-name-", count: 5)
        let checkout = try #require(derive(monorepo(), branch: branch))
        let apex = try #require(checkout.services.first?.domain.value)
        let label = try #require(apex.split(separator: ".").first)
        #expect(label.count <= 63)
        #expect(label.hasPrefix("wishfox-very-long"))
        #expect(!label.hasSuffix("-"))
        #expect(LocalDomain(apex) != nil)

        let longProject = String(repeating: "p", count: 80)
        #expect(WorktreeServices.combinedSlug(project: longProject, branch: "fix") == String(repeating: "p", count: 59) + "-fix")
        #expect(WorktreeServices.combinedSlug(project: "wishfox", branch: "") == "wishfox-worktree")
    }

    @Test("a collision moves the whole worktree to the next suffix")
    func collisionGetsSuffix() throws {
        let taken: Set<LocalDomain> = [LocalDomain("api.wishfox-fix-cart.localhost")!]
        let checkout = try #require(derive(monorepo(), taken: taken))
        #expect(checkout.services.map(\.domain.value) == [
            "wishfox-fix-cart-2.localhost",
            "api.wishfox-fix-cart-2.localhost"
        ])
    }

    @Test("directories are re-rooted onto the worktree")
    func rebasedDirectories() throws {
        let checkout = try #require(derive(monorepo()))
        #expect(checkout.services.map { $0.directory?.path } == [
            worktreePath.path + "/apps/web",
            worktreePath.path + "/apps/api"
        ])
    }

    @Test("a project below the repository root is re-rooted below the worktree root")
    func projectBelowRepositoryRoot() throws {
        let checkout = try #require(derive(monorepo(), projectPath: "frontend"))
        #expect(checkout.services.first?.directory?.path == worktreePath.path + "/frontend/apps/web")
    }

    @Test("a service whose directory is missing from the worktree is skipped")
    func missingDirectorySkipped() throws {
        let checkout = try #require(derive(monorepo(), missing: [worktreePath.path + "/apps/api"]))
        #expect(checkout.services.map(\.name) == ["apps/web"])
        #expect(derive(monorepo(), missing: [worktreePath.path + "/apps/api", worktreePath.path + "/apps/web"]) == nil)
    }

    @Test("port routes are not carried over, and every service runs on Auto")
    func portRoutesSkippedAndAutoForced() throws {
        let checkout = try #require(derive(monorepo()))
        #expect(checkout.services.allSatisfy { $0.kind == .command && $0.portMode == .auto })
        #expect(!checkout.services.contains { $0.domain.value.hasPrefix("db.") })
        #expect(checkout.services.first?.portFlagStyle == .dashP)
        #expect(checkout.services.first?.command == "pnpm dev")
    }

    @Test("ids are stable for one worktree and differ between worktrees")
    func stableIDs() throws {
        let project = monorepo()
        let first = try #require(derive(project))
        let again = try #require(derive(project))
        let other = try #require(derive(project, directory: URL(fileURLWithPath: "/tmp/other")))
        #expect(first.services.map(\.id) == again.services.map(\.id))
        #expect(Set(first.services.map(\.id)).isDisjoint(with: other.services.map(\.id)))
        #expect(Set(first.services.map(\.id)).isDisjoint(with: project.services.map(\.id)))
    }

    @Test("environment values pointing at the project's domains follow the worktree")
    func environmentRewrite() throws {
        var project = monorepo()
        project.services[0].environment = [
            "API_URL": "https://api.wishfox.localhost/v1",
            "SITE": "https://WISHFOX.localhost",
            "OTHER": "https://mywishfox.localhost",
            "UNRELATED": "postgres://localhost:5432"
        ]
        let checkout = try #require(derive(project))
        #expect(checkout.services[0].environment == [
            "API_URL": "https://api.wishfox-fix-cart.localhost/v1",
            "SITE": "https://wishfox-fix-cart.localhost",
            "OTHER": "https://mywishfox.localhost",
            "UNRELATED": "postgres://localhost:5432"
        ])
    }

    @Test("relative paths stay inside their base")
    func relativePaths() {
        #expect(WorktreeServices.relativePath(of: root, under: root) == "")
        #expect(WorktreeServices.relativePath(of: root.appendingPathComponent("a/b"), under: root) == "a/b")
        #expect(WorktreeServices.relativePath(of: URL(fileURLWithPath: "/repo/wishfox-api"), under: root) == nil)
    }

    @Test("search narrows a worktree by its label or its services")
    func matching() throws {
        let checkout = try #require(derive(monorepo()))
        #expect(checkout.matching("fix-cart")?.services.count == 2)
        #expect(checkout.matching("api.")?.services.map(\.name) == ["apps/api"])
        #expect(checkout.matching("nothing") == nil)
    }
}
