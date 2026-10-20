import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A public share URL as a QR code, so it is one camera away on a phone.
/// `*.localhost` never resolves off this Mac, which is why only a share gets one.
struct QRCodeView: View {
    let url: URL

    /// Built once, not on every redraw of the popover.
    @State private var code: NSImage?

    init(url: URL) {
        self.url = url
        _code = State(initialValue: Self.render(url))
    }

    var body: some View {
        VStack(spacing: 10) {
            if let code {
                Image(nsImage: code)
                    .interpolation(.none)
                    .padding(8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(url.absoluteString)
                .font(.lfSubtitle)
                .foregroundStyle(Theme.primaryText)
                .textSelection(.enabled)
            ActionButton(title: "Copy URL", symbol: "doc.on.doc") { Pasteboard.copy(url.absoluteString) }
        }
        .padding(14)
    }

    /// Scaled with nearest-neighbour sampling, because a smoothed QR code is a
    /// blurred one and phone cameras read blur badly.
    private static func render(_ url: URL, side: CGFloat = 168) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = side / output.extent.width
        let representation = NSCIImageRep(
            ciImage: output.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        )
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

enum Pasteboard {
    static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
