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

        let context: DirectoryContext
        do {
            context = try DirectoryContext(url: url)
        } catch {
            fail("could not read \(url.path): \(error.localizedDescription)",
                 hint: "check the directory is readable")
        }

        let snapshot = context.snapshot
        let manager = PackageManagerDetector().resolve(in: url)
        let detection = DetectionEngine().detect(context.detectionContext())

        print(snapshot.name)
        print("  root      \(snapshot.root.path)  (\(snapshot.rootKind))")
        if let version = snapshot.version { print("  version   \(version)") }

        print("")
        print("Detected:")
        if detection.type == .unknown {
            print("  nothing recognised")
        } else {
            print("  \(detection.type.displayName)  (confidence \(Int(detection.confidence * 100))%)")
            for item in detection.evidence where item.matched {
                print("    - \(item.description)")
            }
        }
        print("  \(manager.packageManager.displayName)  (\(manager.reason))")

        let script = CommandBuilder.preferredScript(
            in: snapshot.scripts, framework: detection.type
        )
        print("")
        if let script, let body = snapshot.scripts[script] {
            print("Command:  \(CommandBuilder.devCommand(manager.packageManager, script: script))")
            print("            \(script) = \(body)")
        } else {
            print("Command:  no dev script in package.json, set one by hand")
        }

        if let port = detection.type.defaultPorts.first {
            print("Expected port: \(port)  (a hint, the real port is discovered at runtime)")
        }

        if let domain = LocalDomain("\(LocalDomain.slug(snapshot.name)).localhost") {
            print("Domain:   \(domain)")
        }
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
