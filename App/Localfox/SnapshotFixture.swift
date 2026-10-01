#if DEBUG
import Foundation
import LocalfoxKit

/// The populated machine `--demo` renders: an approved helper, a trusted root,
/// and one service in each state the popover draws differently. The dashboard
/// opens on the shared one, the service with the most to show.
@MainActor
enum SnapshotFixture {
    static func state() -> (state: AppState, selection: UUID) {
        let state = AppState(helperClient: HelperClient(fixture: .ready(version: "fixture", caddyRunning: true)))
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects")

        let web = service("web", .nuxt, "wishfox.localhost", home.appendingPathComponent("wishfox/web"))
        let api = service("api", .nestJS, "api.wishfox.localhost", home.appendingPathComponent("wishfox/api"))
        let admin = service("admin", .vite, "admin.wishfox.localhost", home.appendingPathComponent("wishfox/admin"))
        let site = service("site", .astro, "portfox.localhost", home.appendingPathComponent("portfox-site"))
        let docs = service("docs", .svelteKit, "docs.portfox.localhost", home.appendingPathComponent("portfox-docs"))

        let projects = [
            Project(name: "wishfox", directory: home.appendingPathComponent("wishfox"), services: [web, api, admin]),
            Project(name: "portfox-site", directory: home.appendingPathComponent("portfox-site"), services: [site, docs]),
        ]
        let failure = ServiceStatus.Failure(reason: .exited(code: 1), output: "")

        state.adoptFixture(
            projects,
            statuses: [
                web.id: .running(pid: 4242, port: 3000),
                api.id: .running(pid: 4243, port: 3041),
                site.id: .running(pid: 4244, port: 4321),
                docs.id: .failed(failure),
            ],
            tunnels: [api.id: .live(URL(string: "https://example.trycloudflare.com")!)],
            logs: [api.id: apiLog]
        )
        return (state, api.id)
    }

    private static let apiLog = """
        > api@0.4.2 dev
        > nest start --watch

        [Nest] 4243  - LOG [NestFactory] Starting Nest application...
        [Nest] 4243  - LOG [InstanceLoader] AppModule dependencies initialized
        [Nest] 4243  - LOG [RoutesResolver] WishlistController {/wishlists}
        [Nest] 4243  - LOG [NestApplication] Nest application successfully started
        """

    private static func service(_ name: String, _ framework: ServiceType, _ domain: String, _ directory: URL) -> Service {
        Service(name: name, directory: directory, framework: framework, command: "pnpm dev", domain: LocalDomain(domain)!)
    }
}
#endif
