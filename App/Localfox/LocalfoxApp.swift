import AppKit
import LocalfoxKit
import SwiftUI

@main
struct LocalfoxApp: App {
    @State private var state = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(state)
                .task {
                    AppDelegate.state = state
                    await state.load()
                }
        } label: {
            MenuBarLabel(runningCount: state.runningCount)
        }
        // `.window` is what makes this a custom-drawn popover rather than an
        // NSMenu, which cannot host arbitrary SwiftUI.
        .menuBarExtraStyle(.window)

        // A single Window, not a WindowGroup: there is only ever one dashboard.
        Window("Localfox", id: WindowPresenter.dashboardSceneID) {
            DashboardView()
                .environment(state)
                .frame(minWidth: 900, minHeight: 620)
                .task { await state.load() }
        }
        .defaultSize(width: Theme.Metrics.dashboardWidth, height: Theme.Metrics.dashboardHeight)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        .commands {
            // The app is LSUIElement so this menu is never drawn. It still
            // matters, because NSApplication.sendEvent offers every key-down to
            // the main menu whether or not it is visible, and without these
            // items Cmd+C, Cmd+V, Cmd+A and Cmd+Z do nothing in a text field.
            TextEditingCommands()
            CommandGroup(replacing: .appTermination) {
                Button("Quit Localfox") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            CommandGroup(after: .windowSize) {
                Button("Close") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the dashboard must not quit a menu bar app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if arguments.contains("--verify-runtime") {
            Task { @MainActor in
                await SnapshotRenderer.runVerification(state: AppState())
            }
            return
        }
        if arguments.contains("--install-helper") {
            Task { @MainActor in
                await SnapshotRenderer.runHelperInstall(state: AppState())
            }
            return
        }
        if arguments.contains("--verify-proxy") {
            Task { @MainActor in
                await SnapshotRenderer.runProxyVerify(state: AppState())
            }
            return
        }
        if arguments.contains("--verify-helper") {
            Task { @MainActor in
                await SnapshotRenderer.runHelperVerify(state: AppState())
            }
            return
        }
        if arguments.contains("--uninstall-helper") {
            Task { @MainActor in
                await SnapshotRenderer.runHelperUninstall(state: AppState())
            }
            return
        }
        Telemetry.setEnabled(Preferences().sharesUsageData)
        guard let request = SnapshotRenderer.request else { return }
        // Rendered offscreen and then exits, so no window is ever shown.
        Task { @MainActor in
            await SnapshotRenderer.run(request, state: AppState())
        }
    }

    /// A dev server must never outlive Localfox. Quitting is deferred until the
    /// process groups are gone, because `NSApplication` would otherwise exit
    /// while the children are still being signalled.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = AppDelegate.state, !isTerminating else { return .terminateNow }
        isTerminating = true
        Task { @MainActor in
            await state.stopEverything()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private var isTerminating = false
    /// Set by the scene, because the delegate is created before the state is.
    @MainActor static var state: AppState?
}

private struct MenuBarLabel: View {
    let runningCount: Int

    /// Sized here rather than with `.frame`, which SwiftUI ignores on a
    /// MenuBarExtra label.
    private static let glyph: NSImage = {
        let image = NSImage(
            systemSymbolName: "server.rack",
            accessibilityDescription: "Localfox"
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: Self.glyph)
            if runningCount > 0 {
                Text(String(runningCount))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
        }
    }
}
