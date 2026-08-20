import Foundation
import LocalfoxKit

/// Headless driver for the same pipeline the app uses, so detection, spawning
/// and proxy configuration can be developed and verified without the GUI.
enum CLI {
    static func run() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            usage()
            exit(2)
        }
        arguments.removeFirst()

        switch command {
        case "detect":
            await detect(arguments)
        case "env":
            await environment(arguments)
        case "help", "--help", "-h":
            usage()
        default:
            fail("unknown command \"\(command)\"", hint: "run `localfox-run help` for the list")
        }
    }

    static func usage() {
        print("""
        localfox-run <command>

          detect <directory>   Scan a project and print what Localfox would configure
          env [--no-cache]     Print the environment resolved from your login shell
          help                 This text

        Commands land as their milestones do; `run` and `up` are not built yet.
        """)
    }

    static func detect(_ arguments: [String]) async {
        guard let path = arguments.first else {
            fail("detect needs a directory", hint: "localfox-run detect ~/Projects/wishfox")
        }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            fail("\(url.path) is not a directory", hint: "pass the root of a project")
        }

        guard let snapshot = ProjectResolver().resolve(serviceDirectory: url) else {
            fail("nothing that looks like a project at \(url.path)",
                 hint: "Localfox looks for package.json, pyproject.toml, Cargo.toml and friends")
        }

        print(snapshot.name)
        print("  root      \(snapshot.root.path)")
        print("  kind      \(snapshot.rootKind)")
        if let version = snapshot.version {
            print("  version   \(version)")
        }

        let scripts = snapshot.scripts.keys.sorted()
        if scripts.isEmpty {
            print("  scripts   none")
        } else {
            print("  scripts   \(scripts.joined(separator: ", "))")
        }

        let suggested = LocalDomain.slug(snapshot.name)
        if let domain = LocalDomain("\(suggested).localhost") {
            print("  domain    \(domain)")
        }

        print("")
        print("Framework detection lands with the detection track.")
    }

    static func environment(_ arguments: [String]) async {
        let resolver = ShellEnvironmentResolver()
        let fresh = arguments.contains("--no-cache")

        let started = ContinuousClock.now
        var source = "login shell"
        let environment: ShellEnvironment

        do {
            environment = fresh ? try await resolver.probe() : try await resolver.resolve()
        } catch {
            FileHandle.standardError.write(Data("warning: \(error.localizedDescription)\n".utf8))
            environment = ShellEnvironmentResolver.fallback()
            source = "built-in fallback"
        }
        let elapsed = ContinuousClock.now - started

        print("shell     \(environment.shell)")
        print("source    \(source), \(elapsed)")
        print("PATH")
        for entry in environment.pathEntries {
            print("  \(entry)")
        }

        let interesting = environment.variables
            .filter { $0.key.hasPrefix("NVM") || $0.key.hasPrefix("VOLTA")
                || $0.key.hasPrefix("PNPM") || $0.key.hasPrefix("BUN")
                || $0.key.hasPrefix("MISE") || $0.key.hasPrefix("ASDF")
                || $0.key == "NODE_OPTIONS" }
            .sorted { $0.key < $1.key }
        if !interesting.isEmpty {
            print("toolchain")
            for (key, value) in interesting { print("  \(key)=\(value)") }
        }
    }

    static func fail(_ message: String, hint: String) -> Never {
        FileHandle.standardError.write(Data("localfox-run: \(message)\n  \(hint)\n".utf8))
        exit(1)
    }
}

await CLI.run()
