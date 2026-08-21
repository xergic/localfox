import AppKit
import LocalfoxKit
import ServiceManagement
import SwiftUI

/// Renders a surface to a PNG and exits, so the design can be reviewed without
/// Screen Recording permission and without hand-driving the menu bar.
///
/// Usage: `Localfox --snapshot out.png [--hover] [--light]`, `--snapshot-dashboard out.png`
/// or `--snapshot-prefs out.png`.
@MainActor
enum SnapshotRenderer {
    enum Surface: String, CaseIterable {
        case popover = "--snapshot"
        case dashboard = "--snapshot-dashboard"
        case preferences = "--snapshot-prefs"
    }

    /// Drives the app's own runtime headlessly and prints what happened.
    ///
    /// `localfox-run` exercises the same spawner and port discovery, but not the
    /// wiring from `AppState` through `ServiceRuntime`, which is where the app
    /// actually differs. Same precedent as the snapshot flags.
    static func runVerification(state: AppState) async {
        await state.load()
        // The runtime is built once the shell probe finishes.
        for _ in 0..<60 where state.shellEnvironment == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard let project = state.projects.first else {
            print("no projects configured")
            exit(1)
        }
        print("project \(project.name), \(project.services.count) service(s)")

        for service in project.services {
            print("starting \(service.name): \(service.command)")
            await state.start(service)
        }

        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(250))
            if project.services.allSatisfy({ !state.status(of: $0).isTransitioning }) { break }
        }

        var failed = false
        for service in project.services {
            let status = state.status(of: service)
            print("  \(service.name): \(status.label)  ->  https://\(service.domain.value)")
            if case let .failed(failure) = status {
                failed = true
                print("    \(failure.reason)")
                print("    \(failure.output.suffix(400))")
            }
        }

        print("stopping everything")
        await state.stopEverything()
        for service in project.services {
            print("  \(service.name): \(state.status(of: service).label)")
        }
        exit(failed ? 1 : 0)
    }

    /// Drives helper registration headlessly, so the approval flow can be
    /// exercised without clicking through the interface.
    static func runHelperInstall(state: AppState) async {
        print("bundle: \(Bundle.main.bundleURL.path)")
        // Raw, because the wrapped message hides the code that says why.
        let service = SMAppService.daemon(plistName: HelperIdentity.plistName)
        print("status: \(service.status.rawValue)")
        do {
            try service.register()
            print("register(): OK")
        } catch let error as NSError {
            print("register() failed  domain=\(error.domain) code=\(error.code)")
            print("  \(error.localizedDescription)")
        }
        await state.refreshSetup()
        print("before: \(state.helper)")

        await state.installHelper()
        print("after:  \(state.helper)")
        if let error = state.helperClient.lastError {
            print("error:  \(error)")
        }

        switch state.helper {
        case .requiresApproval:
            print("")
            print("Registered. Approve Localfox in System Settings > General >")
            print("Login Items & Extensions, then run --verify-helper.")
        case .ready:
            print("Helper is running.")
        default:
            print("Registration did not reach an approvable state.")
        }
        exit(0)
    }

    /// Pushes one route through the root daemon and reports what came back.
    static func runProxyVerify(state: AppState) async {
        await state.refreshSetup()
        print("helper: \(state.helper)")
        guard state.helper.canServe else {
            print("helper is not ready, cannot test the proxy")
            exit(1)
        }

        guard let domain = LocalDomain("wishfox.localhost"),
              let route = ProxyRoute(id: "verify1", domain: domain, port: 3041) else {
            print("could not build a route")
            exit(1)
        }

        do {
            print("pushing \(route.domain) -> 127.0.0.1:\(route.port)")
            try await state.helperClient.setRoutes([route])
            print("setRoutes: OK")
        } catch {
            print("setRoutes failed: \(error.localizedDescription)")
            let log = (try? await state.helperClient.caddyLog(lines: 30)) ?? ""
            if !log.isEmpty { print("caddy log:\n\(log)") }
            exit(1)
        }

        await state.refreshSetup()
        print("helper: \(state.helper)")
        print("trust:  \(state.trust)")
        if let identity = state.trust.identity {
            print("CA:     \(identity.commonName)")
            print("        \(identity.fingerprint)")
        }
        exit(0)
    }

    /// Reports what the helper says once it is approved.
    static func runHelperVerify(state: AppState) async {
        await state.refreshSetup()
        print("helper: \(state.helper)")
        print("trust:  \(state.trust)")
        if let error = state.helperClient.lastError {
            print("error:  \(error)")
        }
        exit(state.helper.canServe ? 0 : 1)
    }

    /// Removes the daemon registration again.
    static func runHelperUninstall(state: AppState) async {
        await state.helperClient.uninstall()
        await state.refreshSetup()
        print("after uninstall: \(state.helper)")
        exit(0)
    }

    struct Request {
        let surface: Surface
        let path: String
    }

    static var request: Request? {
        let arguments = CommandLine.arguments
        for surface in Surface.allCases {
            guard let index = arguments.firstIndex(of: surface.rawValue),
                  index + 1 < arguments.count else { continue }
            return Request(surface: surface, path: arguments[index + 1])
        }
        return nil
    }

    /// Any snapshot flag at all, so the presenter knows not to open a real window.
    static var requestedPath: String? { request?.path }

    static func run(_ request: Request, state: AppState) async {
        if CommandLine.arguments.contains("--light") { state.appearance.force(.light) }
        await state.load()

        let renderer = ImageRenderer(content: content(for: request.surface, state: state))
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("could not render \(request.surface.rawValue)\n".utf8))
            exit(1)
        }

        do {
            try png.write(to: URL(fileURLWithPath: request.path))
            print(request.path)
        } catch {
            FileHandle.standardError.write(Data("could not write \(request.path): \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }

    /// `ImageRenderer` lays out in one pass and never draws scroll content, so
    /// every scrollable surface carries a `scrolls` escape hatch that this path
    /// turns off. `forcesHover` reveals actions that only exist under a pointer.
    @ViewBuilder
    private static func content(for surface: Surface, state: AppState) -> some View {
        switch surface {
        case .popover:
            MenuView(scrolls: false, forcesHover: CommandLine.arguments.contains("--hover"))
                .environment(state)
        case .dashboard:
            DashboardContent(scrolls: false)
                .environment(state)
                .frame(width: Theme.Metrics.dashboardWidth, height: Theme.Metrics.dashboardHeight)
                .background(Theme.background)
                .themedSurface(state.appearance.colorScheme)
        case .preferences:
            PreferencesSheet(scrolls: false)
                .environment(state)
        }
    }
}
