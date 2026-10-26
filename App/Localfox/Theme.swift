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
    /// Rows sit straight on this, so it is the row colour as well as the window's.
    static let background = dynamic(dark: srgb(0.110, 0.110, 0.118), light: srgb(1, 1, 1))
    /// One step up from `background`: a contained element such as a detail card.
    static let card = dynamic(dark: srgb(0.165, 0.165, 0.176), light: srgb(0.957, 0.957, 0.965))
    static let cardHover = dynamic(dark: srgb(0.180, 0.180, 0.192), light: srgb(0.929, 0.929, 0.941))
    static let separator = dynamic(dark: srgb(1, 1, 1, 0.07), light: srgb(0, 0, 0, 0.08))
    static let border = dynamic(dark: srgb(1, 1, 1, 0.10), light: srgb(0, 0, 0, 0.12))

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

    static let pill = dynamic(dark: srgb(0.165, 0.165, 0.176), light: srgb(0.941, 0.941, 0.953))

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

    /// Opaque, the accent mixed into `background`, so a selected row needs no
    /// second layer under it.
    static let selectedRow = dynamic(dark: srgb(0.177, 0.150, 0.209), light: srgb(0.960, 0.933, 0.985))

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
        /// Bordered controls: action buttons and the segmented picker.
        static let controlRadius: CGFloat = 8
        static let controlHeightSmall: CGFloat = 24
        static let badgeRadius: CGFloat = 3
        static let rowPaddingH: CGFloat = 12
        /// The hover and selection fill of a flat row.
        static let rowRadius: CGFloat = 6
        static let searchHeight: CGFloat = 26
        /// A flat list row. Narrower than `rowPaddingH`, so the row's text lines
        /// up with the header while its hover fill still has room to show.
        static let listRowPaddingH: CGFloat = 8
        static let listRowPaddingV: CGFloat = 8
        static let compactRowPaddingV: CGFloat = 6
        /// The list's own inset from the window edge, so the fill clears it.
        static let listInset: CGFloat = 6
        /// Where a row's text starts. Headers, search and footers line up on it.
        static let contentInset: CGFloat = listInset + listRowPaddingH
        static let groupHeaderInsets = EdgeInsets(top: 6, leading: listRowPaddingH, bottom: 4, trailing: listRowPaddingH)
        /// Hover actions sit a little outside the text edge, so their glyphs and
        /// not their hit areas line up with the path they cover.
        static let headerActionsInset: CGFloat = listRowPaddingH - 4
        /// Inside a detail card, a little roomier than a row.
        static let cardPaddingH: CGFloat = 12
        static let cardPaddingV: CGFloat = 10
        /// The dashboard's top bar and sidebar footer.
        static let barPaddingH: CGFloat = 14
        static let barPaddingV: CGFloat = 11
        static let detailPadding: CGFloat = 20
        static let detailIcon: CGFloat = 28
        static let serviceIcon: CGFloat = 16
        static let serviceIconCompact: CGFloat = 14
        /// Beside a service name on the bottom line of a project-first cell.
        static let serviceIconSmall: CGFloat = 13
        static let statusPillWidth: CGFloat = 38
        /// The least of a project path a long project name may leave, so the
        /// last folder still reads as "…/wishfox-api".
        static let pathMinWidth: CGFloat = 96
        static let projectIcon: CGFloat = 16

        /// The icon buttons beside the app name in the popover.
        static let headerButtonSize: CGFloat = 22
        static let headerSymbolSize: CGFloat = 12
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

    static let lfName = Font.system(size: 12.5, weight: .semibold)
    static let lfSubtitle = Font.mono(11)
    static let lfPort = Font.mono(12, .medium)
    /// Every version number, Localfox's own included.
    static let lfVersion = Font.mono(11)
    static let lfSection = Font.system(size: 10.5, weight: .semibold)
    /// Proportional secondary text: subtitles and summary labels.
    static let lfDetail = Font.system(size: 12)
    static let lfDetailStrong = Font.system(size: 12, weight: .semibold)
    static let lfBadge = Font.system(size: 9, weight: .bold)
    static let lfCaption = Font.system(size: 11)
}

extension View {
    /// Every surface root wears this, and it is the only thing driving the
    /// palette: the tokens resolve against `\.colorScheme`. `preferredColorScheme`
    /// would be the obvious choice and is not usable, because it is a scene
    /// preference and no-ops under `ImageRenderer`.
    func themedSurface(_ scheme: ColorScheme) -> some View {
        environment(\.colorScheme, scheme)
    }

    /// Every group and section title: small, uppercase, tracked out.
    func groupLabelStyle() -> some View {
        font(.lfSection)
            .textCase(.uppercase)
            .tracking(0.7)
            .foregroundStyle(Theme.secondaryText)
    }
}
