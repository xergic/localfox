import Foundation

/// The detector table.
///
/// Every row sets `requiredGroup: nil`, unlike Portfox's catalogue. Portfox
/// identifies a service from a running process and defaults to requiring argv
/// evidence, which can never match a directory that has not been started yet.
///
/// Weights: a dependency alone clears the threshold, a config file alone does
/// not, and a package script only ever corroborates. That ordering is what makes
/// a scaffolded project with a stray config file stay undetected rather than
/// claiming a framework it does not use.
public enum DetectorCatalog {
    public static let all: [any ServiceDetector] = [
        RuleBasedDetector(
            type: .nextJS,
            threshold: 70,
            signals: [
                .dependency("next", 75),
                .configFile("next.config", 65),
                frameworkScript("next", 15)
            ],
            requiredGroup: nil
        ),
        RuleBasedDetector(
            type: .nuxt,
            threshold: 70,
            signals: [
                .dependency("nuxt", 75),
                .configFile("nuxt.config", 65),
                frameworkScript("nuxt", 15)
            ],
            requiredGroup: nil
        ),
        RuleBasedDetector(
            type: .astro,
            threshold: 70,
            signals: [
                .dependency("astro", 75),
                .configFile("astro.config", 65),
                frameworkScript("astro", 15)
            ],
            requiredGroup: nil
        ),
        RuleBasedDetector(
            type: .svelteKit,
            threshold: 70,
            signals: [
                .dependency("@sveltejs/kit", 75),
                .configFile("svelte.config", 65),
                frameworkScript("svelte-kit", 15)
            ],
            requiredGroup: nil
        ),
        RuleBasedDetector(
            type: .vite,
            threshold: 70,
            signals: [
                .dependency("vite", 75),
                .configFile("vite.config", 65),
                frameworkScript("vite", 15),
                .veto("Nuxt owns its Vite dev server") { context in
                    context.project?.hasDependency("nuxt") == true || context.project?.hasFile(prefix: "nuxt.config") == true
                },
                .veto("Astro owns its Vite dev server") { context in
                    context.project?.hasDependency("astro") == true || context.project?.hasFile(prefix: "astro.config") == true
                },
                .veto("SvelteKit owns its Vite dev server") { context in
                    context.project?.hasDependency("@sveltejs/kit") == true || context.project?.hasFile(prefix: "svelte.config") == true
                },
                .veto("Remix and React Router own their Vite dev server") { context in
                    context.project?.isRemixFramework == true
                }
            ],
            requiredGroup: nil
        ),
        RuleBasedDetector(
            type: .node,
            threshold: 10,
            signals: [
                .custom("package.json has a development script", 10) { context in
                    guard let scripts = context.project?.scripts else { return false }
                    return scripts.keys.contains { $0 == "dev" || $0.contains("dev") }
                }
            ],
            requiredGroup: nil
        )
    ]

    private static func frameworkScript(_ binary: String, _ weight: Int) -> Signal {
        .custom("a package script invokes \(binary)", weight) { context in
            context.project?.scripts.values.contains { $0.lowercased().containsToken(binary) } ?? false
        }
    }
}
