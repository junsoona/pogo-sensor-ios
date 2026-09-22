import XCTest
@testable import PogoHome

final class SSELineParserTests: XCTestCase {
    func testDispatchesEventOnBlankLine() {
        var parser = SSELineParser()
        XCTAssertNil(parser.consume(line: "event: snapshot"))
        XCTAssertNil(parser.consume(line: "data: {\"a\":1}"))
        let event = parser.consume(line: "")
        XCTAssertEqual(event, SSEParsedEvent(event: "snapshot", data: "{\"a\":1}"))
    }

    func testHeartbeatCommentLinesAreIgnored() {
        var parser = SSELineParser()
        XCTAssertNil(parser.consume(line: ": heartbeat"))
        XCTAssertNil(parser.consume(line: ":"))
        // A comment must not itself dispatch an event, and must not corrupt a
        // subsequently-accumulated one.
        XCTAssertNil(parser.consume(line: "event: snapshot"))
        XCTAssertNil(parser.consume(line: "data: {}"))
        XCTAssertEqual(parser.consume(line: ""), SSEParsedEvent(event: "snapshot", data: "{}"))
    }

    func testMultiLineDataIsJoinedWithNewlines() {
        var parser = SSELineParser()
        XCTAssertNil(parser.consume(line: "data: line one"))
        XCTAssertNil(parser.consume(line: "data: line two"))
        XCTAssertEqual(parser.consume(line: ""), SSEParsedEvent(event: nil, data: "line one\nline two"))
    }

    func testBlankLineWithNoAccumulatedDataDispatchesNothing() {
        var parser = SSELineParser()
        XCTAssertNil(parser.consume(line: ""))
        XCTAssertNil(parser.consume(line: ""))
    }

    func testStateResetsAfterDispatch() {
        var parser = SSELineParser()
        XCTAssertNil(parser.consume(line: "event: snapshot"))
        XCTAssertNil(parser.consume(line: "data: first"))
        XCTAssertEqual(parser.consume(line: ""), SSEParsedEvent(event: "snapshot", data: "first"))

        // No `event:` line this time — the previous event name must not leak forward.
        XCTAssertNil(parser.consume(line: "data: second"))
        XCTAssertEqual(parser.consume(line: ""), SSEParsedEvent(event: nil, data: "second"))
    }

    func testUnknownFieldsAreIgnoredWithoutError() {
        var parser = SSELineParser()
        XCTAssertNil(parser.consume(line: "id: 42"))
        XCTAssertNil(parser.consume(line: "retry: 3000"))
        XCTAssertNil(parser.consume(line: "data: payload"))
        XCTAssertEqual(parser.consume(line: ""), SSEParsedEvent(event: nil, data: "payload"))
    }
}
