import Foundation
import XCTest
@testable import PogoHome

// The event stream as it really arrives (1.3.4).
//
// Until 1.3.3 the app read `GET /api/v1/events` with `URLSession.AsyncBytes.lines`, which leaves
// empty lines out -- and an event ends with an empty line. `SSELineParser` dispatches at that line
// and nowhere else, so on a real connection no event was ever dispatched, and the `data:` lines of
// every event stayed in the parser for as long as the connection lived. Every earlier test of the
// event path fed the parser lines from a stand-in transport that did deliver the empty line.
//
// Here the bytes go through the real `URLSession`: a `URLProtocol` plays the server and hands the
// response body over piece by piece (synthetic HTTP: no socket, no hub). What is under test is
// the production path from those bytes on -- `URLSessionSensorAPITransport`, `SSELineSplitter`,
// `SSELineParser`, and further down `LiveSensorDataSource` and `AppModel`. The same against a
// real hub server is `PowerBaseRemovalLiveNetworkTests` / `HubEventStreamLiveNetworkTests`.

// MARK: - A server whose answer arrives in pieces

/// Answers requests to `http://sse-wire.test/<path>` from a plan the test wrote for that path
/// (a test that keeps a connection open uses a path of its own, so that a connection another
/// test gave up a moment ago is not counted with it):
/// the pieces of the body, one `didLoad` each with a pause between them, and whether the
/// connection ends after them or stays open for `send(_:to:)` / `finish(_:)`.
final class PiecewiseHTTP: URLProtocol, @unchecked Sendable {
    struct Plan: Sendable {
        var status = 200
        var contentType: String? = "text/event-stream"
        var pieces: [Data] = []
        /// `false`: the connection stays open after the pieces.
        var ends = true
        var pause: TimeInterval = 0.004
    }

    static let host = "sse-wire.test"
    static func url(_ path: String) -> URL { URL(string: "http://\(host)/\(path)")! }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var plans: [String: [Plan]] = [:]
    nonisolated(unsafe) private static var open: [String: [PiecewiseHTTP]] = [:]
    nonisolated(unsafe) private static var started: [String: Int] = [:]
    nonisolated(unsafe) private static var stopped: [String: Int] = [:]
    private static let queue = DispatchQueue(label: "PiecewiseHTTP")

    /// The answers to the requests for `path`, in order; the last one answers every later request.
    static func plan(_ path: String, _ answers: Plan...) {
        lock.withLock { plans[path] = answers }
    }

    static func reset() {
        lock.withLock {
            plans = [:]
            open = [:]
            started = [:]
            stopped = [:]
        }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PiecewiseHTTP.self]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    static func startedCount(_ path: String) -> Int { lock.withLock { started[path] ?? 0 } }
    static func stoppedCount(_ path: String) -> Int { lock.withLock { stopped[path] ?? 0 } }
    static func openCount(_ path: String) -> Int { lock.withLock { open[path]?.count ?? 0 } }

    /// One more piece on the newest open connection of `path`.
    static func send(_ piece: Data, to path: String) {
        let connection = lock.withLock { open[path]?.last }
        queue.async { connection?.client?.urlProtocol(connection!, didLoad: piece) }
    }

    static func send(_ text: String, to path: String) { send(Data(text.utf8), to: path) }

    /// The newest open connection of `path` ends (the server closes it).
    static func finish(_ path: String) {
        let connection = lock.withLock { open[path]?.popLast() }
        queue.async { connection?.client?.urlProtocolDidFinishLoading(connection!) }
    }

    private var path: String { String(request.url?.path.dropFirst() ?? "") }
    /// Guarded by `lock`: the client gave this connection up.
    private var isStopped = false

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = self.path
        let plan: Plan = Self.lock.withLock {
            Self.started[path, default: 0] += 1
            var answers = Self.plans[path] ?? []
            let next = answers.first ?? Plan(status: 404, contentType: "text/plain", pieces: [Data("no plan".utf8)])
            if answers.count > 1 { answers.removeFirst() }
            Self.plans[path] = answers
            return next
        }
        var headers: [String: String] = [:]
        if let type = plan.contentType { headers["Content-Type"] = type }
        let response = HTTPURLResponse(url: request.url!, statusCode: plan.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        Self.queue.async { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for piece in plan.pieces {
                client?.urlProtocol(self, didLoad: piece)
                if plan.pause > 0 { Thread.sleep(forTimeInterval: plan.pause) }
            }
            if plan.ends {
                client?.urlProtocolDidFinishLoading(self)
            } else {
                Self.lock.withLock {
                    if !isStopped { Self.open[path, default: []].append(self) }
                }
            }
        }
    }

    override func stopLoading() {
        let path = self.path
        Self.lock.withLock {
            isStopped = true
            Self.stopped[path, default: 0] += 1
            Self.open[path]?.removeAll { $0 === self }
        }
    }
}

extension PiecewiseHTTP.Plan {
    /// An event stream whose body is these pieces of text.
    static func stream(_ pieces: [String], ends: Bool = true) -> Self {
        Self(pieces: pieces.map { Data($0.utf8) }, ends: ends)
    }

    /// An event stream whose body is these bytes, cut at the given offsets.
    static func stream(_ body: Data, cutAt offsets: [Int], ends: Bool = true) -> Self {
        var pieces: [Data] = []
        var from = 0
        for offset in offsets.sorted() where offset > from && offset < body.count {
            pieces.append(body.subdata(in: from..<offset))
            from = offset
        }
        pieces.append(body.subdata(in: from..<body.count))
        return Self(pieces: pieces, ends: ends)
    }

    static func json(_ body: Data, ends: Bool = true) -> Self {
        Self(contentType: "application/json", pieces: ends ? [body] : [], ends: ends)
    }
}

/// What a connection delivered: the lines the transport handed on and the events the parser made
/// of them -- read the way `LiveSensorDataSource` reads (comments skipped before the parser).
struct ReceivedStream: Sendable {
    var lines: [String] = []
    var events: [SSEParsedEvent] = []
    var bufferedDataByteCount = 0
    var droppedEventCount = 0
}

/// Reads `stream` to its end, or until `count` events were dispatched, or for `seconds` at most.
func receive(_ stream: AsyncThrowingStream<String, Error>, events count: Int? = nil, within seconds: Double = 5) async -> ReceivedStream {
    let reader = Task { () -> ReceivedStream in
        var received = ReceivedStream()
        var parser = SSELineParser()
        do {
            for try await line in stream {
                received.lines.append(line)
                if !line.hasPrefix(":"), let event = parser.consume(line: line) {
                    received.events.append(event)
                }
                received.bufferedDataByteCount = parser.bufferedDataByteCount
                received.droppedEventCount = parser.droppedEventCount
                if let count, received.events.count >= count { break }
            }
        } catch {}
        return received
    }
    let limit = Task {
        try? await Task.sleep(for: .seconds(seconds))
        reader.cancel()
    }
    let received = await reader.value
    limit.cancel()
    return received
}

/// `json` with the two fields a hub ends every snapshot with (Linux bridge 0.5.0).
func numbered(_ json: Data, sequence: Int64, stream: String = String(repeating: "5a", count: 16)) -> Data {
    var text = String(decoding: json, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    precondition(text.hasSuffix("}"), "a JSON object")
    text.removeLast()
    return Data((text + ",\"snapshot_stream\":\"\(stream)\",\"snapshot_sequence\":\(sequence)}").utf8)
}

/// One `snapshot` event as the hub writes it.
func eventFrame(_ json: Data, newline: String = "\n") -> String {
    "event: snapshot\(newline)data: \(String(decoding: json, as: UTF8.self))\(newline)\(newline)"
}

// MARK: - The splitter

extension SSELineSplitter {
    /// A piece of the stream at once (the transport itself takes the connection's bytes one by
    /// one): the lines that end in it, in order.
    mutating func consume<Bytes: Sequence>(contentsOf bytes: Bytes) -> [String] where Bytes.Element == UInt8 {
        var lines: [String] = []
        for byte in bytes {
            if let line = consume(byte) { lines.append(line) }
        }
        return lines
    }
}

final class SSELineSplitterTests: XCTestCase {
    private func lines(of text: String, limit: Int = SSEStreamLimits.maxLineBytes) -> [String] {
        var splitter = SSELineSplitter(maxLineBytes: limit)
        return splitter.consume(contentsOf: Array(text.utf8))
    }

    func testEveryLineIsHandedOnAndTheEmptyOnesToo() {
        XCTAssertEqual(lines(of: "event: snapshot\ndata: {}\n\n"), ["event: snapshot", "data: {}", ""])
        XCTAssertEqual(lines(of: "\n\n: heartbeat\n\n"), ["", "", ": heartbeat", ""])
    }

    func testTheThreeLineEndingsAreOneEndingEach() {
        let expected = ["event: snapshot", "data: {\"a\":1}", "", "data: {\"b\":2}", ""]
        XCTAssertEqual(lines(of: "event: snapshot\ndata: {\"a\":1}\n\ndata: {\"b\":2}\n\n"), expected)
        XCTAssertEqual(lines(of: "event: snapshot\r\ndata: {\"a\":1}\r\n\r\ndata: {\"b\":2}\r\n\r\n"), expected, "CR LF is one ending, not two")
        XCTAssertEqual(lines(of: "event: snapshot\rdata: {\"a\":1}\r\rdata: {\"b\":2}\r\r"), expected, "a lone CR ends a line")
        XCTAssertEqual(lines(of: "a\n\rb\r\n\nc\n"), ["a", "", "b", "", "c"], "LF then CR are two endings; CR LF then LF are two")
        XCTAssertEqual(lines(of: "a\rb\nc\n"), ["a", "b", "c"], "only an LF RIGHT after a CR belongs to it: the LF that ends the next line is an ending")
    }

    func testALineIsHandedOnAtItsCarriageReturnAndTheLineFeedAfterItIsSwallowed() {
        var splitter = SSELineSplitter()
        XCTAssertEqual(splitter.consume(contentsOf: Array("data: {\"a\":1}\r\n\r".utf8)), ["data: {\"a\":1}", ""], "the event is complete before the last LF has come")
        XCTAssertEqual(splitter.consume(contentsOf: Array("\n".utf8)), [], "that LF, arriving later, is no line of its own")
        XCTAssertEqual(splitter.consume(contentsOf: Array("\n".utf8)), [""], "the next LF is")
    }

    /// Whatever the pieces: the same lines. Every single cut and every pair of cuts of a stream
    /// with all three endings, Korean text and an emoji -- so a CR LF in two pieces and a UTF-8
    /// sequence in two (or three) pieces are among them.
    func testTheLinesDoNotDependOnWhereTheStreamIsCut() {
        let wire = "event: snapshot\r\ndata: {\"방\":\"거실 🛋\"}\r\n\r\n: heartbeat\n\ndata: 첫 줄\rdata: 둘째 줄\r\r\n"
        let bytes = Array(wire.utf8)
        let whole = lines(of: wire)
        XCTAssertEqual(whole, ["event: snapshot", "data: {\"방\":\"거실 🛋\"}", "", ": heartbeat", "", "data: 첫 줄", "data: 둘째 줄", ""])
        for first in 0...bytes.count {
            var one = SSELineSplitter()
            var got = one.consume(contentsOf: bytes[..<first])
            got += one.consume(contentsOf: bytes[first...])
            XCTAssertEqual(got, whole, "cut at \(first)")
            for second in stride(from: first, through: bytes.count, by: 7) {
                var two = SSELineSplitter()
                var pieces = two.consume(contentsOf: bytes[..<first])
                pieces += two.consume(contentsOf: bytes[first..<second])
                pieces += two.consume(contentsOf: bytes[second...])
                XCTAssertEqual(pieces, whole, "cut at \(first) and \(second)")
            }
        }
        var byteByByte = SSELineSplitter()
        XCTAssertEqual(bytes.compactMap { byteByByte.consume($0) }, whole)
    }

    func testAByteOrderMarkAtTheStartIsNotPartOfTheFirstLine() {
        var splitter = SSELineSplitter()
        XCTAssertEqual(splitter.consume(contentsOf: [0xEF, 0xBB, 0xBF] + Array("data: x\n\n".utf8)), ["data: x", ""])
        XCTAssertEqual(splitter.consume(contentsOf: [0xEF, 0xBB, 0xBF] + Array("y\n".utf8)), ["\u{FEFF}y"], "only at the very start")
    }

    func testWhatFollowsTheLastEndingIsAnUnfinishedLineAndNotALine() {
        var splitter = SSELineSplitter()
        XCTAssertEqual(splitter.consume(contentsOf: Array("data: {\"a\":1}\ndata: unfin".utf8)), ["data: {\"a\":1}"])
        XCTAssertEqual(splitter.unfinishedByteCount, "data: unfin".utf8.count, "kept until its ending comes -- and dropped with the connection if it never does")
        XCTAssertEqual(splitter.consume(contentsOf: Array("ished\n".utf8)), ["data: unfinished"])
        XCTAssertEqual(splitter.unfinishedByteCount, 0, "nothing is kept of a line that was handed on")
    }

    func testALineBeyondTheLimitIsDroppedWholeAndItsBytesAreNotKept() {
        var splitter = SSELineSplitter(maxLineBytes: 16)
        XCTAssertEqual(splitter.consume(contentsOf: Array("data: 0123456789".utf8)), [])
        XCTAssertEqual(splitter.unfinishedByteCount, 16, "a line of exactly the limit is kept")
        XCTAssertEqual(splitter.consume(contentsOf: Array("\n".utf8)), ["data: 0123456789"])

        var most = 0
        for _ in 0..<10_000 {
            XCTAssertNil(splitter.consume(UInt8(ascii: "x")))
            most = max(most, splitter.unfinishedByteCount)
        }
        XCTAssertLessThanOrEqual(most, 16, "ten thousand bytes without an ending: never more than the limit is held")
        XCTAssertEqual(splitter.unfinishedByteCount, 0, "and once the line is over the limit, nothing of it")
        XCTAssertEqual(splitter.consume(contentsOf: Array("\r\n".utf8)), [], "its ending hands nothing on")
        XCTAssertEqual(splitter.droppedLineCount, 1)
        XCTAssertEqual(splitter.consume(contentsOf: Array("\ndata: ok\n\n".utf8)), ["", "data: ok", ""], "the lines after it are lines again")
        XCTAssertEqual(splitter.droppedLineCount, 1)
    }

    func testTheLimitIsThatOfTheStreamUnlessAnotherIsGiven() {
        XCTAssertEqual(SSELineSplitter().maxLineBytes, SSEStreamLimits.maxLineBytes)
        XCTAssertEqual(SSEStreamLimits.maxLineBytes, 1_048_576)
        XCTAssertEqual(SSEStreamLimits.maxEventDataBytes, 1_048_576)
    }
}

// MARK: - The parser's bounds

@MainActor
final class SSELineParserBoundsTests: XCTestCase {
    private func feed(_ parser: inout SSELineParser, _ lines: [String]) -> [SSEParsedEvent] {
        lines.compactMap { parser.consume(line: $0) }
    }

    func testTheDataOfAnEventIsReleasedWhenTheEventIsDispatched() {
        var parser = SSELineParser()
        XCTAssertNil(parser.consume(line: "event: snapshot"))
        XCTAssertNil(parser.consume(line: "data: {\"a\":1}"))
        XCTAssertEqual(parser.bufferedDataByteCount, "{\"a\":1}".utf8.count + 1)
        XCTAssertEqual(parser.consume(line: ""), SSEParsedEvent(event: "snapshot", data: "{\"a\":1}"))
        XCTAssertEqual(parser.bufferedDataByteCount, 0)
        XCTAssertEqual(parser.consume(line: "data: next"), nil)
        XCTAssertEqual(parser.consume(line: ""), SSEParsedEvent(event: nil, data: "next"), "neither the name nor the data of the event before")
    }

    func testSeveralDataLinesAreOneEventAndCommentsAreNone() {
        var parser = SSELineParser()
        let events = feed(&parser, ["data: first", ": heartbeat", "data: second", "data:", "", ": heartbeat", ""])
        XCTAssertEqual(events, [SSEParsedEvent(event: nil, data: "first\nsecond\n")])
        XCTAssertEqual(parser.bufferedDataByteCount, 0)
    }

    func testAnEventWithoutAnEndIsGivenUpAtTheLimitAndNothingOfItIsKeptOrDispatched() {
        var parser = SSELineParser(maxEventDataBytes: 64)
        var most = 0
        for index in 0..<1_000 {
            XCTAssertNil(parser.consume(line: "data: line \(index) of an event that never ends"))
            most = max(most, parser.bufferedDataByteCount)
        }
        XCTAssertLessThanOrEqual(most, 64, "a thousand data lines without a blank line: never more than the limit is held")
        XCTAssertEqual(parser.bufferedDataByteCount, 0, "and once it is over the limit, nothing")
        XCTAssertEqual(parser.droppedEventCount, 1, "one event was given up, however long it ran on")
        XCTAssertNil(parser.consume(line: ""), "the blank line that ends it dispatches nothing -- not a part of it either")
        XCTAssertEqual(feed(&parser, ["event: snapshot", "data: {\"ok\":true}", ""]), [SSEParsedEvent(event: "snapshot", data: "{\"ok\":true}")], "the next event is an event again")
        XCTAssertEqual(parser.droppedEventCount, 1)
    }

    func testAnEventOfExactlyTheLimitIsDispatchedAndOneByteMoreIsNot() {
        // One data line of n bytes counts n + 1 (the line break the lines are joined with).
        var fits = SSELineParser(maxEventDataBytes: 11)
        XCTAssertEqual(feed(&fits, ["data: 0123456789", ""]), [SSEParsedEvent(event: nil, data: "0123456789")])
        var tooLarge = SSELineParser(maxEventDataBytes: 10)
        XCTAssertEqual(feed(&tooLarge, ["data: 0123456789", ""]), [])
        XCTAssertEqual(tooLarge.droppedEventCount, 1)
    }

    func testAnEventThatWasNotFinishedIsNeverDispatched() {
        var parser = SSELineParser()
        XCTAssertEqual(feed(&parser, ["event: snapshot", "data: {\"half\":"]), [])
        XCTAssertGreaterThan(parser.bufferedDataByteCount, 0, "it stays what it is: unfinished. The parser ends with its connection")
        // The next connection has a parser of its own (`LiveSensorDataSource` makes one per
        // connection): nothing of this one is in it.
        var next = SSELineParser()
        XCTAssertEqual(feed(&next, ["data: {\"whole\":1}", ""]), [SSEParsedEvent(event: nil, data: "{\"whole\":1}")])
    }
}

// MARK: - Through the real URLSession

@MainActor
final class URLSessionEventStreamTests: XCTestCase {
    override func setUp() async throws {
        PiecewiseHTTP.reset()
    }

    override func tearDown() async throws {
        PiecewiseHTTP.reset()
    }

    private func open(_ path: String) -> AsyncThrowingStream<String, Error> {
        URLSessionSensorAPITransport(session: PiecewiseHTTP.session()).openEventStream(from: PiecewiseHTTP.url(path))
    }

    private static let one = Data("{\"sample\":1}".utf8)
    private static let two = Data("{\"sample\":2}".utf8)

    func testTheEventsOfAStreamAreDispatchedWhateverItsLineEnding() async {
        for newline in ["\n", "\r\n", "\r"] {
            PiecewiseHTTP.plan("events", .stream([eventFrame(Self.one, newline: newline), eventFrame(Self.two, newline: newline)]))
            let received = await receive(open("events"))
            XCTAssertEqual(received.lines, ["event: snapshot", "data: {\"sample\":1}", "", "event: snapshot", "data: {\"sample\":2}", ""], "ending \(newline.debugDescription): the empty lines arrive")
            XCTAssertEqual(received.events, [SSEParsedEvent(event: "snapshot", data: "{\"sample\":1}"), SSEParsedEvent(event: "snapshot", data: "{\"sample\":2}")])
            XCTAssertEqual(received.bufferedDataByteCount, 0, "nothing is kept once the events were dispatched")
        }
    }

    /// The defect itself was this: nothing came out while the connection lived.
    func testAnEventIsDispatchedAtItsEmptyLineWhileTheConnectionStaysOpen() async throws {
        PiecewiseHTTP.plan("kept-open", .stream([eventFrame(Self.one)], ends: false))
        let stream = open("kept-open")
        let first = await receive(stream, events: 1)
        XCTAssertEqual(first.events, [SSEParsedEvent(event: "snapshot", data: "{\"sample\":1}")], "the first event, with the connection still open")
        // The reader stopped: the connection is given up with it.
        try await waitUntil { PiecewiseHTTP.stoppedCount("kept-open") == 1 && PiecewiseHTTP.openCount("kept-open") == 0 }
    }

    func testEventsKeepComingOnAnOpenConnection() async throws {
        PiecewiseHTTP.plan("kept-coming", .stream([eventFrame(Self.one)], ends: false))
        let stream = open("kept-coming")
        async let received = receive(stream, events: 3)
        try await waitUntil { PiecewiseHTTP.openCount("kept-coming") == 1 }
        PiecewiseHTTP.send(": heartbeat\n\n", to: "kept-coming")
        PiecewiseHTTP.send(eventFrame(Self.two), to: "kept-coming")
        PiecewiseHTTP.send(": heartbeat\n\n" + eventFrame(Self.one), to: "kept-coming")
        let got = await received
        XCTAssertEqual(got.events.map(\.data), ["{\"sample\":1}", "{\"sample\":2}", "{\"sample\":1}"])
        XCTAssertEqual(got.lines.filter { $0 == ": heartbeat" }.count, 2, "a heartbeat is a line (the watchdog counts it) and no event")
        XCTAssertEqual(got.bufferedDataByteCount, 0)
    }

    func testACarriageReturnAndItsLineFeedInTwoPiecesAreOneEnding() async {
        PiecewiseHTTP.plan("events", .stream(["event: snapshot\r", "\ndata: {\"sample\":1}\r", "\n\r", "\n", "data: {\"sample\":2}\r", "\n", "\r", "\n"]))
        let received = await receive(open("events"))
        XCTAssertEqual(received.lines, ["event: snapshot", "data: {\"sample\":1}", "", "data: {\"sample\":2}", ""], "no empty line of its own for an LF that came later than its CR")
        XCTAssertEqual(received.events.map(\.data), ["{\"sample\":1}", "{\"sample\":2}"])
    }

    func testAnEventWhoseLastByteSoFarIsACarriageReturnIsNotHeldBack() async throws {
        PiecewiseHTTP.plan("ends-in-cr", .stream(["data: {\"sample\":1}\r\n\r"], ends: false))
        let stream = open("ends-in-cr")
        let first = await receive(stream, events: 1)
        XCTAssertEqual(first.events.map(\.data), ["{\"sample\":1}"], "dispatched before the LF of its last line ending has arrived")
    }

    func testAUTF8SequenceInTwoPiecesIsDecodedWhole() async {
        let json = Data("{\"room\":\"거실 🛋\",\"name\":\"조각보 센서\"}".utf8)
        let body = Data(eventFrame(json).utf8)
        // A cut inside every multi-byte sequence of the body.
        let cuts = body.indices.filter { body[$0] & 0xC0 == 0x80 }
        XCTAssertGreaterThan(cuts.count, 10, "cuts inside the Korean syllables and inside the emoji")
        PiecewiseHTTP.plan("events", .stream(body, cutAt: cuts))
        let received = await receive(open("events"))
        XCTAssertEqual(received.events, [SSEParsedEvent(event: "snapshot", data: String(decoding: json, as: UTF8.self))])
    }

    func testSeveralEventsInOnePieceAndOneEventOverManyPieces() async {
        let together = eventFrame(Self.one) + eventFrame(Self.two) + eventFrame(Self.one)
        let apart = Data(eventFrame(Self.two).utf8)
        PiecewiseHTTP.plan("events", PiecewiseHTTP.Plan(pieces: [Data(together.utf8)] + apart.map { Data([$0]) }, pause: 0.001))
        let received = await receive(open("events"))
        XCTAssertEqual(received.events.map(\.data), ["{\"sample\":1}", "{\"sample\":2}", "{\"sample\":1}", "{\"sample\":2}"])
        XCTAssertEqual(received.bufferedDataByteCount, 0)
    }

    func testSeveralDataLinesAreOneEvent() async {
        PiecewiseHTTP.plan("events", .stream(["event: snapshot\ndata: {\"a\":\n", "data: 1}\n\n"]))
        let received = await receive(open("events"))
        XCTAssertEqual(received.events, [SSEParsedEvent(event: "snapshot", data: "{\"a\":\n1}")])
    }

    func testAnEventThatWasNotFinishedWhenTheConnectionEndedIsNotDispatched() async {
        PiecewiseHTTP.plan("events", .stream([eventFrame(Self.one), "event: snapshot\ndata: {\"sample\":2}\n", "data: {\"unfin"]))
        let received = await receive(open("events"))
        XCTAssertEqual(received.events.map(\.data), ["{\"sample\":1}"], "only the event that ended")
        XCTAssertEqual(received.lines.last, "data: {\"sample\":2}", "the bytes after the last line ending are no line")
        XCTAssertGreaterThan(received.bufferedDataByteCount, 0, "the unfinished event is still unfinished when the stream ends: it goes with its parser")
    }

    /// The review's own measure: a thousand events, a thousand dispatched, nothing kept.
    func testAThousandEventsAreAThousandEventsAndNothingOfThemIsKept() async {
        let frames = (1...1_000).map { "event: snapshot\ndata: {\"sample\":\($0)}\n\n" }
        PiecewiseHTTP.plan("events", PiecewiseHTTP.Plan(pieces: frames.map { Data($0.utf8) }, pause: 0))
        let received = await receive(open("events"), within: 30)
        XCTAssertEqual(received.events.count, 1_000)
        XCTAssertEqual(received.lines.count, 3_000)
        XCTAssertEqual(received.lines.filter(\.isEmpty).count, 1_000)
        XCTAssertEqual(received.events.last?.data, "{\"sample\":1000}")
        XCTAssertEqual(received.bufferedDataByteCount, 0)
    }

    func testALineBeyondTheLimitIsDroppedAndTheStreamGoesOn() async {
        let long = Data("data: ".utf8) + Data(repeating: UInt8(ascii: "x"), count: SSEStreamLimits.maxLineBytes + 100)
        var pieces: [Data] = [Data("event: snapshot\n".utf8)]
        pieces += stride(from: 0, to: long.count, by: 128 * 1024).map { long.subdata(in: $0..<min($0 + 128 * 1024, long.count)) }
        pieces += [Data("\n\n".utf8), Data(eventFrame(Self.two).utf8)]
        PiecewiseHTTP.plan("events", PiecewiseHTTP.Plan(pieces: pieces, pause: 0))
        let received = await receive(open("events"), within: 30)
        XCTAssertEqual(received.lines, ["event: snapshot", "", "event: snapshot", "data: {\"sample\":2}", ""], "the long line was handed on neither whole nor in part")
        XCTAssertEqual(received.events.map(\.data), ["{\"sample\":2}"], "its event had no data and was not dispatched; the next one was")
    }

    /// The largest snapshot the hub's own limits allow goes through whole, with room to spare.
    func testTheLargestSnapshotAHubCanSendIsFarBelowTheLimit() async throws {
        let bases = (0..<16).map { ForgetFixtures.baseJSON(String(format: "00124b0001a2%04x", $0), online: true, moduleCount: 4) }
        let modules = (0..<64).map { ForgetFixtures.moduleJSON(String(format: "744dbdfffe65%04x", $0), base: String(format: "00124b0001a2%04x", $0 % 16), online: true) }
        let jobs = (0..<64).map { _ in DepartureFixtures.job("completed") }
        let snapshot = numbered(DepartureFixtures.snapshot(bases: bases, modules: modules, removals: jobs), sequence: 7)
        XCTAssertNoThrow(try PogoSnapshotMapper.decodeSnapshot(from: snapshot))
        // The size is written into the result bundle (the test's activities), for the record.
        XCTContext.runActivity(named: "largest snapshot of this test: \(snapshot.count) bytes; limit \(SSEStreamLimits.maxLineBytes)") { _ in }
        XCTAssertLessThan(snapshot.count * 8, SSEStreamLimits.maxLineBytes, "16 Bases, 64 modules, 64 jobs: \(snapshot.count) bytes")
        PiecewiseHTTP.plan("events", .stream(Data(eventFrame(snapshot).utf8), cutAt: Array(stride(from: 1_000, to: snapshot.count, by: 1_000))))
        let received = await receive(open("events"))
        XCTAssertEqual(received.events.count, 1)
        let decoded = try PogoSnapshotMapper.decodeSnapshot(from: Data(try XCTUnwrap(received.events.first).data.utf8))
        XCTAssertEqual(decoded.powerBases.count, 16)
        XCTAssertEqual(decoded.modules.count, 64)
        XCTAssertEqual(decoded.delivery.hubOrder, HubSnapshotOrder(stream: String(repeating: "5a", count: 16), sequence: 7))
    }

    func testAResponseThatIsNoEventStreamIsStillRefused() async {
        PiecewiseHTTP.plan("events", PiecewiseHTTP.Plan(contentType: "text/html", pieces: [Data("<html>".utf8)]))
        do {
            for try await _ in open("events") {}
            XCTFail("a content type that is no event stream must throw")
        } catch {}
        PiecewiseHTTP.plan("events", PiecewiseHTTP.Plan(status: 503, pieces: []))
        do {
            for try await _ in open("events") {}
            XCTFail("a status that is no success must throw")
        } catch {}
    }
}

// MARK: - The data source and the model on the real session

/// The real `LiveSensorDataSource` on the real `URLSession` transport (the server is
/// `PiecewiseHTTP`), and the real `AppModel` on top of it: from the bytes of an event to what the
/// app shows. Synthetic HTTP -- no socket, no hub.
@MainActor
final class LiveSourceRealSessionEventTests: XCTestCase {
    private typealias F = ForgetFixtures
    private typealias D = DepartureFixtures
    private static let otherBase = "00124b0001a2b3c5"
    private static let thirdBase = "00124b0001a2b3c6"
    private var models: [AppModel] = []

    override func setUp() async throws {
        PiecewiseHTTP.reset()
    }

    override func tearDown() async throws {
        models.forEach { $0.stop() }
        models = []
        PiecewiseHTTP.reset()
    }

    private func source(polls: Double? = nil) -> LiveSensorDataSource {
        LiveSensorDataSource(
            endpoint: PogoAPIEndpoint(baseURL: URL(string: "http://\(PiecewiseHTTP.host)")!),
            transport: URLSessionSensorAPITransport(session: PiecewiseHTTP.session()), sleeper: RecordingSleeper(),
            livenessIdleTimeout: 30, periodicRefreshInterval: polls
        )
    }

    private func home(_ bases: [String], sequence: Int64, stream: String = String(repeating: "5a", count: 16)) -> Data {
        numbered(D.snapshot(bases: bases.map { F.baseJSON($0, online: true) }), sequence: sequence, stream: stream)
    }

    private func first(_ count: Int, of source: LiveSensorDataSource, within seconds: Double = 5) async -> [HomeSnapshot] {
        let collector = Task { @MainActor () -> [HomeSnapshot] in
            var seen: [HomeSnapshot] = []
            for await snapshot in source.updates() {
                seen.append(snapshot)
                if seen.count == count { break }
            }
            return seen
        }
        let limit = Task {
            try? await Task.sleep(for: .seconds(seconds))
            collector.cancel()
        }
        let seen = await collector.value
        limit.cancel()
        return seen
    }

    /// No periodic `GET` here: what arrives after the connect answer arrived as an event.
    func testTheConnectAnswerAndThenEveryEventReachTheDataSource() async throws {
        PiecewiseHTTP.plan("api/v1/snapshot", .json(home([F.base], sequence: 1)))
        PiecewiseHTTP.plan("api/v1/events", .stream([eventFrame(home([F.base], sequence: 2)), ": heartbeat\n\n", eventFrame(home([F.base, Self.otherBase], sequence: 3))], ends: false))
        let seen = await first(3, of: source())
        XCTAssertEqual(seen.map { $0.delivery.hubOrder?.sequence }, [1, 2, 3], "the connect answer, then both events")
        XCTAssertEqual(seen.map(\.powerBases.count), [1, 1, 2])
        let asked = seen.compactMap(\.delivery.requestOrdinal)
        XCTAssertEqual(asked.count, 3)
        XCTAssertLessThan(asked[0], asked[1], "the stream was opened after the connect GET was asked")
        XCTAssertEqual(asked[1], asked[2], "both events came on the one stream")
        XCTAssertEqual(PiecewiseHTTP.startedCount("api/v1/snapshot"), 1, "one GET: the connect answer. Nothing else could have brought the later snapshots")
    }

    /// A connection that ends in the middle of an event; the next one starts clean.
    func testNothingOfAConnectionThatEndedReachesTheNextOne() async throws {
        let unfinished = "event: snapshot\ndata: " + String(decoding: home([Self.otherBase], sequence: 99), as: UTF8.self).dropLast(30)
        PiecewiseHTTP.plan("api/v1/snapshot", .json(home([F.base], sequence: 1)), .json(home([F.base], sequence: 3)))
        PiecewiseHTTP.plan(
            "api/v1/events",
            .stream([eventFrame(home([F.base], sequence: 2)), String(unfinished)]),
            .stream([eventFrame(home([F.base], sequence: 4))], ends: false)
        )
        let seen = await first(4, of: source())
        XCTAssertEqual(seen.map { $0.delivery.hubOrder?.sequence }, [1, 2, 3, 4], "connect, event, (the connection ends), connect again, event -- and nothing made of the unfinished event")
        XCTAssertTrue(seen.allSatisfy { $0.powerBases.map(\.hardwareIdentifier) == [F.base] }, "the Base only the unfinished event named is nowhere")
        XCTAssertEqual(PiecewiseHTTP.startedCount("api/v1/events"), 2)
    }

    private func start(_ live: LiveSensorDataSource) async throws -> AppModel {
        let model = AppModel(
            dataSource: live, sourceIdentity: .hub(id: String(repeating: "a", count: 32)), sourceAddress: RemovalFixtures.url,
            configurationStore: InMemoryHomeConfigurationStore(language: .korean), language: .korean
        )
        models.append(model)
        model.start()
        try await waitUntil(timeout: 5) { model.lastSyncAt != nil }
        return model
    }

    /// The app follows the hub through its events alone.
    func testTheModelShowsWhatAnEventSaysWithoutAnyGET() async throws {
        PiecewiseHTTP.plan("api/v1/snapshot", .json(home([F.base], sequence: 1)))
        PiecewiseHTTP.plan("api/v1/events", .stream([], ends: false))
        let model = try await start(source())
        try await waitUntil(timeout: 5) { PiecewiseHTTP.openCount("api/v1/events") == 1 }
        XCTAssertEqual(model.snapshot.powerBases.map(\.hardwareIdentifier), [F.base])

        PiecewiseHTTP.send(eventFrame(home([F.base, Self.otherBase], sequence: 2)), to: "api/v1/events")
        try await waitUntil(timeout: 5) { model.snapshot.powerBases.count == 2 }
        PiecewiseHTTP.send(": heartbeat\n\n", to: "api/v1/events")
        PiecewiseHTTP.send(eventFrame(home([F.base, Self.otherBase, Self.thirdBase], sequence: 3)), to: "api/v1/events")
        try await waitUntil(timeout: 5) { model.snapshot.powerBases.count == 3 }
        XCTAssertEqual(PiecewiseHTTP.startedCount("api/v1/snapshot"), 1, "no GET but the connect answer")
        XCTAssertEqual(model.staleSnapshotCount, 0)
    }

    /// The order this change makes possible on a real connection, and 1.3.3's guard against it:
    /// an event is applied, then the answer to a `GET` that the hub made before that event arrives.
    func testAnOlderGETAnswerThatArrivesAfterAnEventDoesNotTakeTheScreenBack() async throws {
        PiecewiseHTTP.plan("api/v1/snapshot", .json(home([F.base], sequence: 1)), .json(Data(), ends: false))
        PiecewiseHTTP.plan("api/v1/events", .stream([], ends: false))
        let model = try await start(source(polls: 0.02))
        try await waitUntil(timeout: 5) { PiecewiseHTTP.openCount("api/v1/events") == 1 }
        // The periodic GET is asked and not answered yet.
        try await waitUntil(timeout: 5) { PiecewiseHTTP.openCount("api/v1/snapshot") == 1 }

        // The hub made snapshot 2 for that GET (the Base alone), then registered another Base and
        // said so in event 3. The event arrives first.
        PiecewiseHTTP.send(eventFrame(home([F.base, Self.otherBase], sequence: 3)), to: "api/v1/events")
        try await waitUntil(timeout: 5) { model.snapshot.powerBases.count == 2 }
        // Now the answer to the GET.
        PiecewiseHTTP.send(home([F.base], sequence: 2), to: "api/v1/snapshot")
        PiecewiseHTTP.finish("api/v1/snapshot")
        try await waitUntil(timeout: 5) { model.staleSnapshotCount >= 1 }
        XCTAssertEqual(model.snapshot.powerBases.count, 2, "the older answer was not applied: the Base the event showed is still there")
    }
}
