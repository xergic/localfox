import Foundation

/// Builds the command that starts a dev server.
public enum CommandBuilder {
    /// The command Localfox suggests, run from the service's own directory.
    ///
    /// Directory-scoped rather than `pnpm --filter web dev`, because filter
    /// syntax differs across package-manager majors and across whether the
    /// script is declared at the root, while a plain script name works
    /// everywhere. Running from the package directory also keeps per-directory
    /// version managers such as `mise` and `.nvmrc` resolving correctly.
    public static func devCommand(_ manager: PackageManager, script: String) -> String {
        switch manager {
        // pnpm and yarn run a script without the `run` verb.
        case .pnpm: "pnpm \(script)"
        case .yarn: "yarn \(script)"
        case .bun: "bun run \(script)"
        case .npm: "npm run \(script)"
        }
    }

    /// The workspace-filter form, offered as an alternative because the spec
    /// shows it. Run from the repository root rather than the package directory.
    public static func filteredCommand(
        _ manager: PackageManager,
        package: String,
        script: String
    ) -> String {
        switch manager {
        case .pnpm: "pnpm --filter \(package) \(script)"
        case .yarn: "yarn workspace \(package) \(script)"
        case .bun: "bun run --filter \(package) \(script)"
        case .npm: "npm run \(script) --workspace \(package)"
        }
    }

    /// Appends a fixed port to a command in the form the framework accepts.
    ///
    /// Returns the command unchanged plus an environment overlay when the
    /// framework takes its port that way. Vite, Astro and SvelteKit ignore
    /// `PORT` entirely, so passing it there fails silently and the proxy ends up
    /// pointing at whatever port the server actually chose.
    public static func pinningPort(
        _ port: Int,
        in command: String,
        style: PortFlagStyle
    ) -> (command: String, environment: [String: String]) {
        switch style {
        case .dashP:
            (command + " -p \(port)", [:])
        case .doubleDashPort:
            (command + " --port \(port)", [:])
        case .environmentPORT:
            (command, ["PORT": String(port)])
        case .environmentNamed:
            (command, ["NUXT_PORT": String(port), "PORT": String(port)])
        case .none:
            (command, ["PORT": String(port)])
        }
    }

    /// Picks the script to run, preferring the framework's own convention and
    /// falling back through the names people actually use.
    public static func preferredScript(
        in scripts: [String: String],
        framework: ServiceType
    ) -> String? {
        var candidates: [String] = []
        if let preferred = framework.defaultDevScript { candidates.append(preferred) }
        candidates.append(contentsOf: ["dev", "develop", "start:dev", "serve", "start"])

        for name in candidates where scripts[name] != nil {
            return name
        }
        return nil
    }
}

public extension PackageManager {
    /// What to call it in the interface.
    var displayName: String {
        switch self {
        case .pnpm: "pnpm"
        case .bun: "bun"
        case .yarn: "yarn"
        case .npm: "npm"
        }
    }
}
