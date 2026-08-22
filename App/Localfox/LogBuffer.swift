import Foundation

/// The last N lines of a process's output.
///
/// Bounded rather than a growing string: a webpack build can emit megabytes
/// in a minute and the interface only ever shows the tail.
struct LogBuffer: Sendable {
    private(set) var lines: [String] = []
    private let limit: Int

    init(limit: Int = 2_000) { self.limit = limit }

    mutating func append(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line)
            guard !trimmed.isEmpty || !lines.isEmpty else { continue }
            lines.append(trimmed)
        }
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }

    var text: String { lines.joined(separator: "\n") }
}
