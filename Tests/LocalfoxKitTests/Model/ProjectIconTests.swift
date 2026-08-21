import Foundation
import Testing

@testable import LocalfoxKit

@Suite("where a project's icon is stored")
struct ProjectIconTests {
    private let project = Project(
        name: "Wishfox",
        directory: URL(fileURLWithPath: "/Users/me/wishfox")
    )

    @Test("a file inside the project is stored relative and resolves back")
    func storesInsideFileRelative() {
        let picked = URL(fileURLWithPath: "/Users/me/wishfox/public/favicon.svg")
        var edited = project
        edited.iconPath = project.iconPathValue(for: picked)

        #expect(edited.iconPath == "public/favicon.svg")
        #expect(edited.iconURL?.standardizedFileURL == picked)
    }

    @Test("a file outside the project is stored absolute and resolves unchanged")
    func storesOutsideFileAbsolute() {
        let picked = URL(fileURLWithPath: "/Users/me/Pictures/mark.png")
        var edited = project
        edited.iconPath = project.iconPathValue(for: picked)

        #expect(edited.iconPath == "/Users/me/Pictures/mark.png")
        #expect(edited.iconURL?.standardizedFileURL == picked)
    }

    /// A sibling directory that merely shares a prefix is outside the project.
    @Test("a lookalike sibling path is not treated as inside")
    func rejectsPrefixLookalike() {
        let picked = URL(fileURLWithPath: "/Users/me/wishfox-api/public/favicon.svg")
        #expect(project.iconPathValue(for: picked) == "/Users/me/wishfox-api/public/favicon.svg")
    }

    @Test("a project on automatic has no icon URL")
    func automaticHasNoURL() {
        #expect(project.iconURL == nil)
    }
}
