import Foundation

/// A validated mapping from a local HTTPS domain to a loopback development port.
///
/// There is deliberately no upstream-host field: the privileged helper derives
/// every dial address from `port`, so an XPC client cannot express a non-local
/// destination.
public struct ProxyRoute: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let domain: LocalDomain
    public let port: Int

    public init?(id: String, domain: LocalDomain, port: Int) {
        guard Self.isValidID(id), Self.isValidPort(port) else { return nil }
        self.id = id
        self.domain = domain
        self.port = port
    }

    /// Creates a route with a compact, URL-safe identifier derived from a UUID.
    public static func make(domain: LocalDomain, port: Int, uuid: UUID = UUID()) -> ProxyRoute? {
        let id = uuid.uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        return ProxyRoute(id: String(id), domain: domain, port: port)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let decodedDomain = try container.decode(LocalDomain.self, forKey: .domain)
        let port = try container.decode(Int.self, forKey: .port)

        guard let domain = LocalDomain(decodedDomain.value) else {
            throw DecodingError.dataCorruptedError(
                forKey: .domain,
                in: container,
                debugDescription: "A route domain must be a valid *.localhost host."
            )
        }

        guard Self.isValidID(id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "A route id must match ^[A-Za-z0-9_-]{1,32}$."
            )
        }
        guard Self.isValidPort(port) else {
            throw DecodingError.dataCorruptedError(
                forKey: .port,
                in: container,
                debugDescription: "A route port must be between 1 and 65535."
            )
        }

        self.id = id
        self.domain = domain
        self.port = port
    }

    public static func isValidID(_ id: String) -> Bool {
        guard (1...32).contains(id.count) else { return false }
        return id.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
        }
    }

    public static func isValidPort(_ port: Int) -> Bool {
        (1...65_535).contains(port)
    }
}
