import Foundation
import Network

/// A minimal HTTP/1.1 client for Caddy's Unix-socket admin API.
public actor CaddyAdminClient {
    public enum Error: Swift.Error, Sendable {
        case invalidPath(String)
        case connectionFailed(String)
        case malformedResponse
        case unsuccessfulResponse(status: Int, body: Data)
    }

    private let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func load(config: Data) async throws {
        _ = try await request(method: "POST", path: "/load", body: config)
    }

    public func patch(path: String, body: Data) async throws {
        _ = try await request(method: "PATCH", path: path, body: body)
    }

    public func rootCA(id: String) async throws -> Data {
        try await request(method: "GET", path: "/pki/ca/\(id)")
    }

    public func config() async throws -> Data {
        try await request(method: "GET", path: "/config/")
    }

    private func request(method: String, path: String, body: Data = Data()) async throws -> Data {
        guard path.hasPrefix("/") else { throw Error.invalidPath(path) }

        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        defer { connection.cancel() }
        try await start(connection)

        let request = makeRequest(method: method, path: path, body: body)
        try await send(request, over: connection)
        let response = try await receiveResponse(from: connection)
        guard (200...299).contains(response.status) else {
            throw Error.unsuccessfulResponse(status: response.status, body: response.body)
        }
        return response.body
    }

    private func makeRequest(method: String, path: String, body: Data) -> Data {
        let headers = [
            "\(method) \(path) HTTP/1.1",
            "Host: localhost",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        return Data(headers.utf8) + body
    }

    private func start(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case let .failed(networkError):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: Error.connectionFailed(networkError.debugDescription))
                case let .waiting(networkError):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: Error.connectionFailed(networkError.debugDescription))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
    }

    private func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            connection.send(content: data, completion: .contentProcessed { networkError in
                if let networkError {
                    continuation.resume(throwing: Error.connectionFailed(networkError.debugDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveResponse(from connection: NWConnection) async throws -> HTTPResponse {
        var data = Data()
        var expectedBodyLength: Int?

        while true {
            let chunk = try await receive(from: connection)
            data.append(chunk.data)

            if expectedBodyLength == nil, let parsedHeaders = parseHeaders(in: data) {
                expectedBodyLength = parsedHeaders.contentLength
            }
            if let expectedBodyLength, let parsedHeaders = parseHeaders(in: data),
               data.count >= parsedHeaders.bodyStart + expectedBodyLength {
                return try parseResponse(data)
            }
            if chunk.complete {
                return try parseResponse(data)
            }
        }
    }

    private func receive(from connection: NWConnection) async throws -> ReceivedChunk {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, networkError in
                if let networkError {
                    continuation.resume(throwing: Error.connectionFailed(networkError.debugDescription))
                } else {
                    continuation.resume(returning: ReceivedChunk(data: data ?? Data(), complete: complete))
                }
            }
        }
    }

    private func parseHeaders(in data: Data) -> ParsedHeaders? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let headerText = String(data: data[..<range.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        let contentLength = lines.dropFirst().compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].caseInsensitiveCompare("Content-Length") == .orderedSame else {
                return nil
            }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first
        return ParsedHeaders(bodyStart: range.upperBound, contentLength: contentLength)
    }

    private func parseResponse(_ data: Data) throws -> HTTPResponse {
        guard let headers = parseHeaders(in: data),
              let headerText = String(data: data[..<(headers.bodyStart - 4)], encoding: .utf8),
              let statusLine = headerText.components(separatedBy: "\r\n").first
        else { throw Error.malformedResponse }

        let statusParts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"), let status = Int(statusParts[1]) else {
            throw Error.malformedResponse
        }
        let bodyEnd = headers.contentLength.map { min(headers.bodyStart + $0, data.count) } ?? data.count
        return HTTPResponse(status: status, body: Data(data[headers.bodyStart..<bodyEnd]))
    }
}

private struct ReceivedChunk: Sendable {
    let data: Data
    let complete: Bool
}

private struct ParsedHeaders: Sendable {
    let bodyStart: Int
    let contentLength: Int?
}

private struct HTTPResponse: Sendable {
    let status: Int
    let body: Data
}
