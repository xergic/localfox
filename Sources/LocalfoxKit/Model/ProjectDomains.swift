import Foundation

/// The `<project>.localhost` / `<dir>.<project>.localhost` naming rule.
///
/// Extracted from `ProjectScanner` because renaming a project has to reproduce
/// exactly what the scan would have produced, and a second copy of the rule
/// would drift from the first the day either one changes.
public enum ProjectDomains {
    /// Hosts for a whole project, in the order the members were given.
    ///
    /// `apexIndex` is the member that gets the bare `<project>.localhost`.
    public static func hosts(
        directoryNames: [String],
        projectSlug: String,
        apexIndex: Int?
    ) -> [String] {
        var taken: Set<String> = []
        return directoryNames.indices.map { index in
            let slug = LocalDomain.slug(directoryNames[index])
            var host = index == apexIndex ? "\(projectSlug).localhost" : "\(slug).\(projectSlug).localhost"

            // A monorepo can hold two packages whose directories slug the same
            // way, and two services on one domain make routing order-dependent.
            var suffix = 2
            while taken.contains(host) {
                host = "\(slug)-\(suffix).\(projectSlug).localhost"
                suffix += 1
            }
            taken.insert(host)
            return host
        }
    }
}
