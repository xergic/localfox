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
          help                 This text

        Commands land as their milestones do; `env`, `run` and `up` are not built yet.
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

    static func fail(_ message: String, hint: String) -> Never {
        FileHandle.standardError.write(Data("localfox-run: \(message)\n  \(hint)\n".utf8))
        exit(1)
    }
}

await CLI.run()
