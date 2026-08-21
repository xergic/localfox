import Foundation
import Testing

@testable import LocalfoxKit

@Suite("resolving a project's own icon")
struct IconResolverTests {
    @Test("search paths are checked in order, so a favicon beats a logo")
    func prefersEarlierSearchPath() {
        let tree = TempTree()
        defer { tree.cleanUp() }
        tree.write("x", at: "public/favicon.svg")
        tree.write("x", at: "public/logo.png")

        let path = IconResolver().projectIconPath(root: tree.root, serviceDirectory: tree.root)
        #expect(path == tree.root.appendingPathComponent("public/favicon.svg").path)
    }

    /// Every new Vite project ships this file, so it names the framework rather
    /// than the user's project.
    @Test("a framework's stock logo never wins")
    func skipsGenericIcons() {
        let tree = TempTree()
        defer { tree.cleanUp() }
        tree.write("x", at: "public/vite.svg")

        #expect(IconResolver().projectIconPath(root: tree.root, serviceDirectory: tree.root) == nil)
    }

    @Test("an Expo config names its icon, which beats guessing")
    func prefersDeclaredExpoIcon() {
        let tree = TempTree()
        defer { tree.cleanUp() }
        tree.write(#"{"expo":{"icon":"./assets/brand.png"}}"#, at: "app.json")
        tree.write("x", at: "assets/brand.png")
        tree.write("x", at: "public/favicon.svg")

        let path = IconResolver().projectIconPath(root: tree.root, serviceDirectory: tree.root)
        #expect(path == tree.root.appendingPathComponent("assets/brand.png").path)
    }

    @Test("the service directory is searched before the project root")
    func prefersServiceDirectory() {
        let tree = TempTree()
        defer { tree.cleanUp() }
        let service = tree.makeDirectory("apps/web")
        tree.write("x", at: "apps/web/public/favicon.svg")
        tree.write("x", at: "public/favicon.svg")

        let path = IconResolver().projectIconPath(root: tree.root, serviceDirectory: service)
        #expect(path == service.appendingPathComponent("public/favicon.svg").path)
    }

    @Test("a project with no images resolves to the framework asset")
    func fallsBackToFramework() {
        let tree = TempTree()
        defer { tree.cleanUp() }
        let snapshot = makeSnapshot(root: tree.root, name: "demo")
        #expect(IconResolver().resolve(project: snapshot, type: .nuxt) == .framework(.nuxt))
    }

    @Test("an unknown framework with no images falls all the way back to a symbol")
    func fallsBackToSymbol() {
        let tree = TempTree()
        defer { tree.cleanUp() }
        let snapshot = makeSnapshot(root: tree.root, name: "demo")
        #expect(IconResolver().resolve(project: snapshot, type: .unknown) == .symbol(ServiceType.unknown.fallbackSymbol))
    }
}
