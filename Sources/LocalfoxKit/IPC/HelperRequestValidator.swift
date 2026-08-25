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

    /// The `Host` an access-log line must carry to be returned.
    ///
    /// Built through `LocalDomain`, so the value the helper matches on is a
    /// validated `*.localhost` name and nothing else. The trailing quote is
    /// deliberately absent: Caddy records the header verbatim and a browser
    /// includes the port whenever it is not the scheme's default, so
    /// `localfox-run up` on 8443 writes `wishfox.localhost:8443`.
    public static func accessLogMarker(host: String) -> String? {
        guard let domain = LocalDomain(host) else { return nil }
        return "\"host\":\"\(domain.value)"
    }
}
