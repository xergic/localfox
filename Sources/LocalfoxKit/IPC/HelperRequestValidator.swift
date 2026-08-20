import Foundation

/// Pure validation for values that cross the privileged helper boundary.
public enum HelperRequestValidator {
    public static let maximumLogLines = 1_000

    public static func isValidFingerprint(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    public static func isValidRouteID(_ value: String) -> Bool {
        ProxyRoute.isValidID(value)
    }

    public static func clampLogLines(_ lines: Int) -> Int {
        min(max(lines, 0), maximumLogLines)
    }
}
