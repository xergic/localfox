import Foundation
import Testing

@testable import LocalfoxKit

@Suite("finding images a user could pick")
struct ProjectAssetScannerTests {
    @Test("images are found across the searched directories")
    func findsImagesAcrossDirectories() {
        let tree = TempTree()
        defer { tree.cleanUp() }
        tree.write("x", at: "public/favicon.svg")
        tree.write("x", at: "assets/brand.png")
        tree.write("x", at: "logo.png")

        let found = ProjectAssetScanner().assets(root: tree.root, serviceDirectory: tree.root)
        #expect(Set(found.map(\.relativePath)) == ["public/favicon.svg", "assets/brand.png", "logo.png"])
    }

    @Test("non-images are ignored")
    func ignoresNonImages() {
        let tree = TempTree()
        defer { tree.cleanUp() }
        tree.write("x", at: "public/index.html")
        tree.write("x", at: "public/app.js")

        #expect(ProjectAssetScanner().assets(root: tree.root, serviceDirectory: tree.root).isEmpty)
    }

    /// The picker opens on a click, so walking a dependency tree would be felt.
    @Test("node_modules is never scanned")
    func skipsExcludedDirectories() {
        let tree = TempTree()
        defer { tree.cleanUp() }
        tree.write("x", at: "node_modules/react/logo.png")
        tree.write("x", at: "public/favicon.svg")

        let found = ProjectAssetScanner().assets(root: tree.root, serviceDirectory: tree.root)
        #expect(found.map(\.relativePath) == ["public/favicon.svg"])
    }

    @Test("a favicon outranks an arbitrary screenshot")
    func ranksFaviconFirst() {
        let tree = TempTree()
        defer { tree.cleanUp() }
        tree.write("x", at: "public/screenshot.png")
        tree.write("x", at: "public/favicon.svg")

        let found = ProjectAssetScanner().assets(root: tree.root, serviceDirectory: tree.root)
        #expect(found.first?.relativePath == "public/favicon.svg")
    }

    /// Sized variants are the common case, so the ranking matches on the stem.
    @Test("a sized icon variant still reads as an icon")
    func ranksSizedIconVariant() {
        let tree = TempTree()
        defer { tree.cleanUp() }
        tree.write("x", at: "public/banner.png")
        tree.write("x", at: "public/icon-192.png")

        let found = ProjectAssetScanner().assets(root: tree.root, serviceDirectory: tree.root)
        #expect(found.first?.relativePath == "public/icon-192.png")
    }

    @Test("an empty file is not offered")
    func skipsEmptyFiles() {
        let tree = TempTree()
        defer { tree.cleanUp() }
        tree.write("", at: "public/favicon.svg")

        #expect(ProjectAssetScanner().assets(root: tree.root, serviceDirectory: tree.root).isEmpty)
    }
}
