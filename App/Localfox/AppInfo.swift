import Foundation

enum AppInfo {
    static let name = "Localfox"
    static let summary = "Runs your dev servers on stable HTTPS domains."
    static let author = "Ondra Kandera"
    static let repositoryURL = URL(string: "https://github.com/xergic/localfox")!

    static let versionLabel = "v\(version)"
    static let fullVersionLabel = "Version \(version) (\(build))"

    /// `$(MARKETING_VERSION)`, which the release workflow overrides from the git tag.
    private static let version = string(for: "CFBundleShortVersionString")
    private static let build = string(for: "CFBundleVersion")

    private static func string(for key: String) -> String {
        Bundle.main.infoDictionary?[key] as? String ?? "—"
    }
}
