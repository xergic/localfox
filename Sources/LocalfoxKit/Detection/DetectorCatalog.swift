import Foundation

/// The detector table.
///
/// Placeholder. The cold-directory catalogue lands with the detection track;
/// Portfox's rows all default to `requiredGroup: "command"` and therefore cannot
/// fire against a directory that has no running process yet.
public enum DetectorCatalog {
    public static let all: [any ServiceDetector] = []

    public static let standardThreshold = 90
}
