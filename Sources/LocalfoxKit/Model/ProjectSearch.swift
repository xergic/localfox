import Foundation

extension Array where Element == Project {
    /// Projects narrowed to the services whose name, domain, framework, command or
    /// port contains `query`, case-insensitively, or whose port falls inside a
    /// range such as `3000-3999`. A project whose own name matches keeps every
    /// service. Projects left with nothing are dropped.
    ///
    /// The port is passed in because it is runtime state the store does not hold.
    public func matching(_ query: String, port: (Service) -> Int? = { _ in nil }) -> [Project] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return self }
        func contains(_ text: String?) -> Bool { text?.range(of: needle, options: .caseInsensitive) != nil }

        if let range = Self.portRange(needle) {
            return compactMap { project in
                var narrowed = project
                narrowed.services = project.services.filter { port($0).map(range.contains) ?? false }
                return narrowed.services.isEmpty ? nil : narrowed
            }
        }

        return compactMap { project in
            if contains(project.name) { return project }
            var narrowed = project
            narrowed.services = project.services.filter { service in
                contains(service.name) || contains(service.domain.value) || contains(service.framework.displayName)
                    || contains(service.command) || contains(port(service).map(String.init))
            }
            return narrowed.services.isEmpty ? nil : narrowed
        }
    }

    private static func portRange(_ needle: String) -> ClosedRange<Int>? {
        let bounds = needle.split(separator: "-", omittingEmptySubsequences: false)
            .map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard bounds.count == 2, let lower = bounds[0], let upper = bounds[1], lower <= upper else { return nil }
        return lower...upper
    }
}
