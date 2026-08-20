import Foundation

/// A validated `*.localhost` domain.
///
/// Validation lives here rather than at the XPC boundary because the helper must
/// be able to reject a host without trusting anything the app computed. Every
/// label is checked, so `evil.com#.localhost` and `../x.localhost` cannot survive
/// a round trip into a Caddy config.
public struct LocalDomain: Hashable, Codable, Sendable, CustomStringConvertible {
    public static let suffix = "localhost"

    public let value: String

    public var description: String { value }

    public init?(_ raw: String) {
        let lowered = raw.lowercased()
        guard let normalised = Self.normalise(lowered) else { return nil }
        value = normalised
    }

    private static func normalise(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= 253 else { return nil }

        let labels = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.last == Self.suffix[...] else { return nil }

        for label in labels.dropLast() {
            guard Self.isValidLabel(label) else { return nil }
        }
        return raw
    }

    /// RFC 1123: 1-63 characters, ASCII alphanumeric and hyphen, no leading or
    /// trailing hyphen. Deliberately not IDNA-aware; a non-ASCII host would have
    /// to be punycoded by the caller before it gets here.
    private static func isValidLabel(_ label: Substring) -> Bool {
        guard (1...63).contains(label.count) else { return false }
        guard label.first != "-", label.last != "-" else { return false }
        return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Turns an arbitrary project or directory name into a usable label.
    public static func slug(_ raw: String) -> String {
        var out = ""
        var lastWasHyphen = true

        for character in raw.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                out.append(character)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(63))
    }
}
