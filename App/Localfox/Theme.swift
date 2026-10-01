import AppKit
import SwiftUI

/// Two literal palettes rather than semantic system colours, because the design
/// is a specific dark grey and a specific off-white, not whatever the OS picks.
///
/// Every token is a dynamic `NSColor`, so it resolves against the `\.colorScheme`
/// of the surface being drawn. That is what makes a light appearance reach ~200
/// unchanged call sites, and it keeps working under `ImageRenderer`, where a
/// snapshot of the light appearance has to actually come out light.
enum Theme {
    static let background = dynamic(dark: srgb(0.055, 0.055, 0.063), light: srgb(0.965, 0.965, 0.973))
    static let card = dynamic(dark: srgb(0.106, 0.106, 0.118), light: srgb(1, 1, 1))
    static let cardHover = dynamic(dark: srgb(0.137, 0.137, 0.153), light: srgb(0.941, 0.941, 0.949))
    static let separator = dynamic(dark: srgb(1, 1, 1, 0.07), light: srgb(0, 0, 0, 0.08))
    static let border = dynamic(dark: srgb(1, 1, 1, 0.09), light: srgb(0, 0, 0, 0.12))

    static let primaryText = dynamic(dark: srgb(0.949, 0.949, 0.957), light: srgb(0.106, 0.106, 0.118))
    static let secondaryText = dynamic(dark: srgb(0.541, 0.541, 0.576), light: srgb(0.400, 0.400, 0.435))
    static let tertiaryText = dynamic(dark: srgb(0.396, 0.396, 0.427), light: srgb(0.557, 0.557, 0.588))

    /// Interactive chrome only: a primary button, a selected row, a chosen
    /// segment. The same purple as the app icon, so the accent is the brand.
    /// One value for both appearances, because a brand that changes shade with
    /// the theme stops being a brand.
    static let accent = Color(nsColor: accentBrand)
    /// The accent as text or a glyph rather than a fill. Brand purple on white is
    /// about 2.9:1, so light darkens it; dark keeps the brand value exactly.
    static let accentText = dynamic(dark: accentBrand, light: srgb(0.522, 0.278, 0.780))
    /// Ink for text sitting on an accent fill. Near-black in both appearances:
    /// black scores about 5.6:1 on the purple where white scores 3.4:1. Not
    /// `background`, which used to stand in for it and inverts in light.
    static let onAccent = Color(nsColor: ink)

    /// "This is healthy", never chrome. Deliberately a warmer, lighter green
    /// than the purple accent, because the two sit next to each other wherever the
    /// wall renders "ready" against "not ready yet".
    static let success = dynamic(dark: successDark, light: successLight)
    static let danger = dynamic(dark: srgb(0.937, 0.267, 0.267), light: srgb(0.784, 0.110, 0.110))
    /// A live public share, in the row badge and the summary dot alike.
    static let publicShare = pathDirectory

    static let pill = dynamic(dark: srgb(0.137, 0.137, 0.149), light: srgb(0.925, 0.925, 0.937))

    /// What a process is doing in a service's tree, matching `ProcessRole`.
    static let roleBoundary = dynamic(dark: srgb(0.694, 0.549, 0.973), light: srgb(0.486, 0.227, 0.929))
    static let roleWrapper = dynamic(dark: srgb(0.965, 0.694, 0.290), light: srgb(0.706, 0.325, 0.035))
    static let roleService = success

    /// Something the user has to fix before HTTPS works. Amber rather than the
    /// accent, so a blocker never reads as a control or a selection.
    static let warning = roleWrapper

    /// The listening process's row in the tree, a wash of `roleService` over the
    /// card. Alpha over near-black and alpha over white do not read the same: 6%
    /// separates the row in dark and is invisible in light, so light gets more.
    static let listenerRow = dynamic(
        dark: successDark.withAlphaComponent(0.06),
        light: successLight.withAlphaComponent(0.10)
    )
    static let listenerBorder = dynamic(
        dark: successDark.withAlphaComponent(0.45),
        light: successLight.withAlphaComponent(0.55)
    )

    /// Opaque, the accent mixed into `card`, so it can stand in for the card fill.
    static let selectedRow = dynamic(dark: srgb(0.173, 0.146, 0.209), light: srgb(0.960, 0.933, 0.985))
    static let selectedBorder = dynamic(
        dark: accentBrand.withAlphaComponent(0.55),
        light: accentBrand.withAlphaComponent(0.70)
    )

    /// Path values in the metadata card, so the executable and the working
    /// directory are told apart without reading their labels.
    static let pathExecutable = roleWrapper
    static let pathDirectory = dynamic(dark: srgb(0.376, 0.647, 0.980), light: srgb(0.146, 0.388, 0.922))

    private static let accentBrand = srgb(0.666, 0.440, 0.874)
    private static let ink = srgb(0.055, 0.055, 0.063)
    private static let successDark = srgb(0.133, 0.773, 0.369)
    private static let successLight = srgb(0.016, 0.471, 0.341)

    /// Resolved at draw time, never at read time, so a token can stay a
    /// `static let` and SwiftUI still repaints it when the appearance moves.
    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func srgb(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    enum Metrics {
        static let popoverWidth: CGFloat = 404
        static let maximumListHeight: CGFloat = 460
        static let cardRadius: CGFloat = 10
        /// Action buttons, pills and the filled header buttons.
        static let controlRadius: CGFloat = 8
        static let controlHeight: CGFloat = 28
        static let badgeRadius: CGFloat = 5
        static let rowPaddingH: CGFloat = 12
        static let rowPaddingV: CGFloat = 9
        /// Inside a detail card, a little roomier than a row.
        static let cardPaddingH: CGFloat = 14
        static let cardPaddingV: CGFloat = 12
        /// The dashboard's top bar and sidebar footer.
        static let barPaddingH: CGFloat = 16
        static let barPaddingV: CGFloat = 10
        static let detailPadding: CGFloat = 20
        static let detailIconTile: CGFloat = 46
        static let detailIcon: CGFloat = 32
        static let serviceIcon: CGFloat = 22
        /// Beside a service name on the bottom line of a project-first cell.
        static let serviceIconSmall: CGFloat = 13
        /// Fixed so four and five digit ports align, and so the hover actions can
        /// be positioned beside the pill without measuring it.
        static let portPillWidth: CGFloat = 66
        /// Space the hover actions occupy. Reserved even at rest, so revealing
        /// them never re-truncates the text or shifts the row under the pointer.
        static let rowActionsWidth: CGFloat = 72
        /// The project header carries a fourth button, so it reserves more than a
        /// service row. Raising the shared constant instead would cost every
        /// service row twenty points of text width for nothing.
        static let projectActionsWidth: CGFloat = 92
        static let projectIcon: CGFloat = 22

        /// The filled buttons beside the app name in the popover.
        static let headerButtonSize: CGFloat = 30
        static let headerSymbolSize: CGFloat = 13
        static let dashboardWidth: CGFloat = 1180
        static let dashboardHeight: CGFloat = 820
        static let sidebarWidth: CGFloat = 320
    }
}

extension Font {
    /// JetBrains Mono, bundled under the SIL Open Font License. Chosen over the
    /// system monospace for its wider, more even digits, which is most of what
    /// this UI shows. The NL cut has no ligatures, so a path never renders an
    /// arrow where it should show two characters.
    static func mono(_ size: CGFloat, _ weight: MonoWeight = .regular) -> Font {
        .custom(weight.postScriptName, size: size)
    }

    enum MonoWeight {
        case regular
        case medium
        case semibold

        var postScriptName: String {
            switch self {
            case .regular: "JetBrainsMonoNL-Regular"
            case .medium: "JetBrainsMonoNL-Medium"
            case .semibold: "JetBrainsMonoNL-SemiBold"
            }
        }
    }

    static let lfName = Font.system(size: 13, weight: .semibold)
    static let lfProject = Font.system(size: 13, weight: .bold)
    static let lfSubtitle = Font.mono(11)
    static let lfPort = Font.mono(12, .medium)
    /// Every version number, Localfox's own included.
    static let lfVersion = Font.mono(11)
    static let lfSection = Font.system(size: 10, weight: .semibold)
    /// Proportional secondary text: subtitles and summary labels.
    static let lfDetail = Font.system(size: 12)
    static let lfDetailStrong = Font.system(size: 12, weight: .semibold)
    static let lfBadge = Font.system(size: 11, weight: .medium)
}

extension View {
    /// Every surface root wears this, and it is the only thing driving the
    /// palette: the tokens resolve against `\.colorScheme`. `preferredColorScheme`
    /// would be the obvious choice and is not usable, because it is a scene
    /// preference and no-ops under `ImageRenderer`.
    func themedSurface(_ scheme: ColorScheme) -> some View {
        environment(\.colorScheme, scheme)
    }
}
