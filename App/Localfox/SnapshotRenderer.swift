import AppKit
import SwiftUI

/// Renders a surface to a PNG and exits, so the design can be reviewed without
/// Screen Recording permission and without hand-driving the menu bar.
///
/// Usage: `Localfox --snapshot out.png [--hover]`, `--snapshot-dashboard out.png`.
@MainActor
enum SnapshotRenderer {
    enum Surface: String, CaseIterable {
        case popover = "--snapshot"
        case dashboard = "--snapshot-dashboard"
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
                .environment(\.colorScheme, .dark)
        case .dashboard:
            DashboardContent(scrolls: false)
                .environment(state)
                .frame(width: Theme.Metrics.dashboardWidth, height: Theme.Metrics.dashboardHeight)
                .background(Theme.background)
                .environment(\.colorScheme, .dark)
        }
    }
}
