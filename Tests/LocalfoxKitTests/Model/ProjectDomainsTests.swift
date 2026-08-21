import Foundation
import Testing

@testable import LocalfoxKit

@Suite("naming a project's domains")
struct ProjectDomainsTests {
    @Test("the apex member gets the bare project domain")
    func apexTakesTheBareDomain() {
        let hosts = ProjectDomains.hosts(
            directoryNames: ["api", "web"],
            projectSlug: "wishfox",
            apexIndex: 1
        )
        #expect(hosts == ["api.wishfox.localhost", "wishfox.localhost"])
    }

    /// Two services on one domain would make routing order-dependent.
    @Test("directories that slug the same way get a numeric suffix")
    func collidingDirectoriesGetASuffix() {
        let hosts = ProjectDomains.hosts(
            directoryNames: ["my-api", "my_api", "my api"],
            projectSlug: "wishfox",
            apexIndex: nil
        )
        #expect(hosts == [
            "my-api.wishfox.localhost",
            "my-api-2.wishfox.localhost",
            "my-api-3.wishfox.localhost"
        ])
    }

    /// This is what a rename has to reproduce: the same rule, a new slug.
    @Test("re-slugging moves the apex and every subdomain together")
    func reslugMovesEveryDomain() {
        let names = ["web", "api"]
        #expect(
            ProjectDomains.hosts(directoryNames: names, projectSlug: "wishfox", apexIndex: 0)
                == ["wishfox.localhost", "api.wishfox.localhost"]
        )
        #expect(
            ProjectDomains.hosts(directoryNames: names, projectSlug: "kanban", apexIndex: 0)
                == ["kanban.localhost", "api.kanban.localhost"]
        )
    }

    @Test("a project with no apex gives every member a subdomain")
    func noApexMeansAllSubdomains() {
        let hosts = ProjectDomains.hosts(
            directoryNames: ["web"],
            projectSlug: "wishfox",
            apexIndex: nil
        )
        #expect(hosts == ["web.wishfox.localhost"])
    }
}
