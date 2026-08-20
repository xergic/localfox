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
        case "run":
            await runService(arguments)
        case "caddy-config":
            caddyConfig(arguments)
        case "up":
            await up(arguments)
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
          run <dir> -- <cmd>   Start a dev command and report the port it binds
          caddy-config <h:p>…  Print the proxy config for host:port pairs
          up <h:p>…            Start the proxy for host:port pairs on 8080/8443
          help                 This text
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

    static func runService(_ arguments: [String]) async {
        guard let separator = arguments.firstIndex(of: "--"),
              separator > 0, separator + 1 < arguments.count else {
            fail("run needs a directory and a command",
                 hint: "localfox-run run ~/Projects/wishfox -- pnpm dev")
        }
        let directory = URL(
            fileURLWithPath: (arguments[0] as NSString).expandingTildeInPath
        ).standardizedFileURL
        let command = arguments[(separator + 1)...].joined(separator: " ")

        let resolver = ShellEnvironmentResolver()
        let shellEnvironment = (try? await resolver.resolve())
            ?? ShellEnvironmentResolver.fallback()

        var environment = shellEnvironment.variables
        environment["PATH"] = shellEnvironment.path
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        environment["LOCALFOX_HOST"] = "dev.localhost"

        let request = SpawnRequest.devCommand(
            command, in: directory, shell: shellEnvironment.shell, environment: environment
        )

        let process: SpawnedProcess
        do {
            process = try ProcessSpawner.spawn(request)
        } catch {
            fail("could not start: \(error.localizedDescription)", hint: "check the command")
        }

        print("spawned pid \(process.pid), process group \(process.processGroup)")
        streamOutput(process)

        // Ctrl-C must tear down the tree, not orphan it.
        let teardown = installTeardown(group: process.processGroup, label: "service")
        defer { teardown.forEach { $0.cancel() } }

        do {
            let listener = try await PortDiscovery().waitForPort(
                group: process.processGroup,
                expected: nil,
                confirm: { await PortDiscovery.confirmHTTP($0, host: "dev.localhost") }
            )
            print("discovered \(listener.family) port \(listener.port), confirmed HTTP")
            if listener.bindsAllInterfaces {
                print("warning: bound to all interfaces, so it is already reachable from your LAN")
            }
            print("would proxy https://dev.localhost -> 127.0.0.1:\(listener.port)")
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        }

        print("running. press ctrl-c to stop.")
        while true { try? await Task.sleep(for: .seconds(3600)) }
    }

    /// Drains both pipes so a chatty dev server never blocks on a full buffer.
    static func streamOutput(_ process: SpawnedProcess) {
        for (handle, prefix) in [(process.standardOutput, "out"), (process.standardError, "err")] {
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    print("  [\(prefix)] \(line)")
                }
            }
        }
    }

    /// Prints the config Localfox would hand the proxy, for
    /// `localfox-run caddy-config wishfox.localhost:3000 api.wishfox.localhost:4000`.
    static func caddyConfig(_ arguments: [String]) {
        let layout = CaddyLayout.development()
        let builder = CaddyConfigBuilder(options: .init(
            httpPort: 8080,
            httpsPort: 8443,
            storageRoot: layout.storageRoot.path,
            logPath: layout.logFile.path,
            adminSocketPath: layout.adminSocket.path,
            caID: "localfox",
            caName: "Localfox Local Authority"
        ))
        do {
            FileHandle.standardOutput.write(try builder.build(routes: parseRoutes(arguments)))
            print("")
        } catch {
            fail("could not build the config: \(error)", hint: "this is a bug, please report it")
        }
    }

    /// Runs the proxy unprivileged on 8080/8443 so the whole path is testable
    /// without the root helper. The app has no such fallback.
    static func up(_ arguments: [String]) async {
        let routes = parseRoutes(arguments)
        let layout = CaddyLayout.development()
        let options = CaddyConfigBuilder.Options(
            httpPort: 8080,
            httpsPort: 8443,
            storageRoot: layout.storageRoot.path,
            logPath: layout.logFile.path,
            adminSocketPath: layout.adminSocket.path,
            caID: "localfox",
            caName: "Localfox Local Authority"
        )

        let config: Data
        do {
            config = try CaddyConfigBuilder(options: options).build(routes: routes)
        } catch {
            fail("could not build the config: \(error)", hint: "this is a bug")
        }

        let supervisor = CaddySupervisor(layout: layout)
        let caddy: SpawnedProcess
        do {
            caddy = try await supervisor.start(configJSON: config, httpPort: 8080, httpsPort: 8443)
        } catch {
            fail(error.localizedDescription, hint: "caddy binary: \(layout.binary.path)")
        }

        print("caddy running, pid \(caddy.pid)")
        print("admin socket \(layout.adminSocket.path)")
        for route in routes {
            print("  https://\(route.domain.value):8443 -> 127.0.0.1:\(route.port)")
        }

        let teardown = installTeardown(group: caddy.processGroup, label: "caddy")
        defer { teardown.forEach { $0.cancel() } }

        print("press ctrl-c to stop.")
        while true { try? await Task.sleep(for: .seconds(3600)) }
    }

    static func parseRoutes(_ arguments: [String]) -> [ProxyRoute] {
        var routes: [ProxyRoute] = []
        for (index, pair) in arguments.enumerated() {
            let parts = pair.split(separator: ":")
            guard parts.count == 2, let port = Int(parts[1]),
                  let domain = LocalDomain(String(parts[0])),
                  let route = ProxyRoute(id: "svc\(index)", domain: domain, port: port) else {
                fail("could not read \"\(pair)\"", hint: "use host.localhost:3000")
            }
            routes.append(route)
        }
        guard !routes.isEmpty else {
            fail("needs at least one host:port", hint: "localfox-run up wishfox.localhost:3000")
        }
        return routes
    }

    /// Tears the child down on either signal.
    ///
    /// SIGTERM matters as much as SIGINT: `pkill`, a `make` interrupt and a
    /// logout all send TERM, and without a handler the CLI dies while Caddy or
    /// the dev server keeps holding its ports.
    static func installTeardown(group: pid_t, label: String) -> [DispatchSourceSignal] {
        // A dedicated queue, not `.main`. Under a Swift concurrency top-level
        // await the main queue is not drained the way a run loop would drain it,
        // so a source attached to it never fires and the child is orphaned.
        let queue = DispatchQueue(label: "net.kandera.localfox.signals")
        return [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler {
                // Synchronous, because `exit` must not race an unfinished Task.
                _ = kill(-group, SIGTERM)
                usleep(400_000)
                if ProcessSpawner.isAlive(group) { _ = kill(-group, SIGKILL) }
                print("\n\(label) stopped")
                fflush(stdout)
                exit(0)
            }
            source.resume()
            return source
        }
    }

    static func fail(_ message: String, hint: String) -> Never {
        FileHandle.standardError.write(Data("localfox-run: \(message)\n  \(hint)\n".utf8))
        exit(1)
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
await CLI.run()
