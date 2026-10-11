import Foundation

/// The network boundary `LiveSensorDataSource` talks to. Kept separate from `URLSession`
/// so tests can substitute a scripted transport (canned snapshot bytes, canned SSE lines,
/// simulated disconnects) instead of hitting real sockets, while
/// `URLSessionSensorAPITransport` is the only thing that actually knows about `URLSession`.
nonisolated protocol SensorAPITransport: Sendable {
    /// Performs one `GET` and returns the raw response body.
    func fetchSnapshotData(from url: URL) async throws -> Data

    /// Opens a single SSE connection and yields the response body line by line (no
    /// trailing newline per element) -- **empty lines included**: an event ends with one, and
    /// `SSELineParser` dispatches there. Cancelling the stream's consuming task, or the
    /// `Task` this is awaited from, tears down the underlying connection — callers don't
    /// need to manage the HTTP request's lifetime themselves.
    func openEventStream(from url: URL) -> AsyncThrowingStream<String, Error>
}

// The limits and the splitter are here, next to the transport that reads with them, and not in
// SSELineParser.swift: this file is also part of the Watch app (for its snapshot `GET`), and that
// target does not have the parser.

/// What an event stream may hold at most, in bytes: one line, and the data of one event.
///
/// The hub puts a whole snapshot on one `data:` line. Its own capacity limits (64 modules, 16
/// Power Bases, 64 removal jobs, 64 list-removal records, 64 Bases out of the list) keep a
/// snapshot near 100 KB at the very most; a household's is a few KB. 1 MiB leaves that an order
/// of magnitude of room and still bounds what a connection can make this app keep: a line or an
/// event beyond it is not a snapshot of this hub, and is dropped (see `SSELineSplitter` and
/// `SSELineParser`). The periodic `GET` does not come through here.
nonisolated enum SSEStreamLimits {
    static let maxLineBytes = 1 << 20
    static let maxEventDataBytes = 1 << 20
}

/// Splits the bytes of an event stream into its lines -- **every** line, the empty ones too.
///
/// An event ends with an empty line, so a splitter that leaves empty lines out (as
/// `URLSession.AsyncBytes.lines` does) delivers no event at all: `SSELineParser` dispatches at the
/// empty line and nowhere else. This type is what `URLSessionSensorAPITransport` reads the
/// connection with instead.
///
/// - A line ends at LF, at CR LF, or at a lone CR (the three endings of the event stream
///   format). It is handed on **at the CR**, without waiting for the byte after it: a CR LF that
///   arrives in two pieces is still one ending (the LF right after a CR is swallowed), and an
///   event whose last byte so far is a CR is not held back until more data comes.
/// - Bytes are kept until the line ends and decoded then, so a UTF-8 sequence split between two
///   pieces of the connection's data is decoded whole.
/// - A UTF-8 byte order mark at the very start of the stream is not part of the first line.
/// - Bytes after the last line ending are an unfinished line: when the connection ends they are
///   not a line (`unfinishedByteCount` says how many there were) -- an event that was not
///   finished is not dispatched.
/// - A line longer than `maxLineBytes` is dropped whole: its bytes are not kept while it runs,
///   and nothing is handed on for it (`droppedLineCount`). The event it belonged to arrives
///   without that line -- for this app's events, without data, and so is not dispatched.
///
/// One value per connection: nothing of one connection's bytes can reach the next.
nonisolated struct SSELineSplitter: Sendable {
    let maxLineBytes: Int
    /// Lines that were dropped because they were longer than `maxLineBytes`.
    private(set) var droppedLineCount = 0

    private var line: [UInt8] = []
    /// The last byte was a CR that ended a line: an LF right after it belongs to that ending.
    private var swallowsLineFeed = false
    /// The line under way is already longer than the limit: its bytes are not kept.
    private var isDroppingLine = false
    private var isFirstLine = true

    /// A buffer that grew for one long line is given back rather than kept for the short ones.
    private static let retainedCapacity = 16 * 1024

    init(maxLineBytes: Int = SSEStreamLimits.maxLineBytes) {
        self.maxLineBytes = max(1, maxLineBytes)
    }

    /// Bytes of a line that has not ended yet.
    var unfinishedByteCount: Int { line.count }

    /// Takes the next byte of the stream. Returns a line when this byte ends one.
    mutating func consume(_ byte: UInt8) -> String? {
        switch byte {
        case 0x0A: // LF
            if swallowsLineFeed {
                swallowsLineFeed = false
                return nil
            }
            return endLine()
        case 0x0D: // CR
            swallowsLineFeed = true
            return endLine()
        default:
            swallowsLineFeed = false
            if isDroppingLine { return nil }
            if line.count >= maxLineBytes {
                isDroppingLine = true
                releaseLine()
                return nil
            }
            line.append(byte)
            return nil
        }
    }

    private mutating func endLine() -> String? {
        defer {
            isFirstLine = false
            releaseLine()
        }
        if isDroppingLine {
            isDroppingLine = false
            droppedLineCount += 1
            return nil
        }
        if isFirstLine, line.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: line.dropFirst(3), as: UTF8.self)
        }
        return String(decoding: line, as: UTF8.self)
    }

    private mutating func releaseLine() {
        if line.capacity > Self.retainedCapacity {
            line = []
        } else {
            line.removeAll(keepingCapacity: true)
        }
    }
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
                    // Not `bytes.lines`: that sequence leaves empty lines out, and with them the
                    // end of every event. One splitter per connection; what is left in it when
                    // the connection ends is an unfinished line and goes nowhere.
                    var splitter = SSELineSplitter()
                    for try await byte in bytes {
                        guard let line = splitter.consume(byte) else { continue }
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
