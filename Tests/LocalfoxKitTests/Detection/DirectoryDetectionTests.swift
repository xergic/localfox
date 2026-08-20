import Foundation
import Testing
@testable import LocalfoxKit

@Suite("detecting cold project directories")
struct DirectoryDetectionTests {
    @Test("each supported framework is detected from its manifest and config", arguments: [
        (ServiceType.nextJS, "next", "next.config.ts", "next dev"),
        (.vite, "vite", "vite.config.ts", "vite"),
        (.nuxt, "nuxt", "nuxt.config.ts", "nuxt dev"),
        (.astro, "astro", "astro.config.mjs", "astro dev"),
        (.svelteKit, "@sveltejs/kit", "svelte.config.js", "vite dev")
    ])
    func detectsFramework(type: ServiceType, dependency: String, config: String, script: String) throws {
        let context = try directoryContext(dependencies: [dependency], files: [
            config: "", "package.json": packageJSON(dependencies: [dependency], script: script)
        ])

        #expect(DetectionEngine().detect(context.detectionContext()).type == type)
    }

    @Test("a SvelteKit project is never also reported as Vite")
    func svelteKitVetoesVite() throws {
        try expectExclusiveFramework(.svelteKit, dependency: "@sveltejs/kit", config: "svelte.config.js")
    }

    @Test("an Astro project is never also reported as Vite")
    func astroVetoesVite() throws {
        try expectExclusiveFramework(.astro, dependency: "astro", config: "astro.config.mjs")
    }

    @Test("a Nuxt project is never also reported as Vite")
    func nuxtVetoesVite() throws {
        try expectExclusiveFramework(.nuxt, dependency: "nuxt", config: "nuxt.config.ts")
    }

    @Test("a bare development script falls back to Node")
    func devScriptFallsBackToNode() throws {
        let context = try directoryContext(dependencies: [], files: [
            "package.json": packageJSON(dependencies: [], script: "node server.js")
        ])

        #expect(DetectionEngine().detect(context.detectionContext()).type == .node)
    }

    @Test("an empty directory detects nothing")
    func emptyDirectoryDetectsNothing() throws {
        let fileSystem = InMemoryFileSystem(["/fixture/": ""])
        let context = try DirectoryContext(url: URL(fileURLWithPath: "/fixture", isDirectory: true), fileSystem: fileSystem)

        #expect(DetectionEngine().detect(context.detectionContext()).type == .unknown)
    }

    @Test("catalogue order does not affect the winner")
    func catalogueOrderDoesNotMatter() throws {
        let context = try directoryContext(dependencies: ["astro", "vite"], files: [
            "astro.config.mjs": "", "vite.config.ts": "", "package.json": packageJSON(dependencies: ["astro", "vite"], script: "astro dev")
        ])
        let detectionContext = context.detectionContext()
        let forward = DetectionEngine(detectors: DetectorCatalog.all).detect(detectionContext)
        let reversed = DetectionEngine(detectors: Array(DetectorCatalog.all.reversed())).detect(detectionContext)

        #expect(forward == reversed)
    }

    private func expectExclusiveFramework(_ type: ServiceType, dependency: String, config: String) throws {
        let context = try directoryContext(dependencies: [dependency, "vite"], files: [
            config: "", "vite.config.ts": "", "package.json": packageJSON(dependencies: [dependency, "vite"], script: "vite dev")
        ])
        let matches = DetectionEngine().allMatches(context.detectionContext())

        #expect(matches.first?.type == type)
        #expect(!matches.contains { $0.type == .vite })
    }

    private func directoryContext(dependencies: [String], files: [String: String]) throws -> DirectoryContext {
        let root = "/fixture"
        let tree = Dictionary(uniqueKeysWithValues: files.map { name, contents in ("\(root)/\(name)", contents) })
        return try DirectoryContext(url: URL(fileURLWithPath: root, isDirectory: true), fileSystem: InMemoryFileSystem(tree))
    }

    private func packageJSON(dependencies: [String], script: String) -> String {
        let entries = dependencies.map { "\"\($0)\": \"latest\"" }.joined(separator: ", ")
        return "{ \"name\": \"fixture\", \"scripts\": { \"dev\": \"\(script)\" }, \"devDependencies\": { \(entries) } }"
    }
}
