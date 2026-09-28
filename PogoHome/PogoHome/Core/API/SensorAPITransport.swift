import Foundation

/// The network boundary `LiveSensorDataSource` talks to. Kept separate from `URLSession`
/// so tests can substitute a scripted transport (canned snapshot bytes, canned SSE lines,
/// simulated disconnects) instead of hitting real sockets, while
/// `URLSessionSensorAPITransport` is the only thing that actually knows about `URLSession`.
nonisolated protocol SensorAPITransport: Sendable {
    /// Performs one `GET` and returns the raw response body.
    func fetchSnapshotData(from url: URL) async throws -> Data

    /// Opens a single SSE connection and yields the response body line by line (no
    /// trailing newline per element). Cancelling the stream's consuming task, or the
    /// `Task` this is awaited from, tears down the underlying connection — callers don't
    /// need to manage the HTTP request's lifetime themselves.
    func openEventStream(from url: URL) -> AsyncThrowingStream<String, Error>
}

/// The real, `URLSession`-backed transport used outside of tests.
nonisolated struct URLSessionSensorAPITransport: SensorAPITransport {
    private let session: URLSession

    /// Defaults to a dedicated ephemeral session (no disk/URL cache at all) rather than
    /// `.shared`, so nothing outside this type's own explicit per-request cache policy can
    /// ever cause a snapshot GET to be answered from a stale cached response. Tests keep
    /// injecting their own `URLSession` (backed by a stub `URLProtocol`), which this leaves
    /// untouched.
    init(session: URLSession = Self.makeDefaultSession()) {
        self.session = session
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }

    func fetchSnapshotData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Every snapshot fetch must reflect the server's current state, especially right
        // after a Linux registry restart — a cached 200 here would silently resurrect a
        // stale module list. Belt-and-braces against any cache between here and the
        // server (the session itself is also configured with no cache at all, above).
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, expectingContentTypePrefix: "application/json")
        return data
    }

    func openEventStream(from url: URL) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.timeoutInterval = 3600
                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.validate(response, expectingContentTypePrefix: "text/event-stream")
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Checks the status code, and — when the response does declare a `Content-Type` —
    /// that it's the expected one. A response with no `Content-Type` header at all is
    /// allowed through rather than rejected: this only needs to catch a clearly wrong
    /// response (an HTML error page substituting for JSON/SSE), not police a header the
    /// server might reasonably omit.
    private static func validate(_ response: URLResponse, expectingContentTypePrefix expected: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PogoAPIError.transport(String(localized: "응답이 HTTP 응답이 아닙니다", comment: "Network error detail"))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PogoAPIError.transport("HTTP \(http.statusCode)")
        }
        if let contentType = http.value(forHTTPHeaderField: "Content-Type"), !contentType.isEmpty {
            guard contentType.lowercased().hasPrefix(expected) else {
                throw PogoAPIError.transport(String(localized: "예상하지 못한 Content-Type: \(contentType)", comment: "Network error detail; Content-Type is an HTTP header name"))
            }
        }
    }
}
