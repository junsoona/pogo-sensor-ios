import XCTest
@testable import PogoHome

final class URLSessionSensorAPITransportTests: XCTestCase {
    override func tearDown() {
        RecordingURLProtocol.reset()
        super.tearDown()
    }

    func testFetchSnapshotDataUsesReloadIgnoringLocalCacheData() async throws {
        RecordingURLProtocol.responseData = PogoAPIFixtures.fullSnapshotJSON()
        RecordingURLProtocol.responseContentType = "application/json; charset=utf-8"
        let transport = URLSessionSensorAPITransport(session: Self.makeSession())

        _ = try await transport.fetchSnapshotData(from: URL(string: "https://test.local/api/v1/snapshot")!)

        XCTAssertEqual(RecordingURLProtocol.lastRequest?.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testFetchSnapshotDataRejectsAnUnexpectedContentType() async {
        RecordingURLProtocol.responseData = Data("<html>not json</html>".utf8)
        RecordingURLProtocol.responseContentType = "text/html"
        let transport = URLSessionSensorAPITransport(session: Self.makeSession())

        do {
            _ = try await transport.fetchSnapshotData(from: URL(string: "https://test.local/api/v1/snapshot")!)
            XCTFail("expected a content-type mismatch to throw")
        } catch {
            // expected
        }
    }

    func testFetchSnapshotDataAllowsAMissingContentTypeHeader() async throws {
        // Real servers might reasonably omit the header; this must not be treated the same
        // as an actively wrong one.
        RecordingURLProtocol.responseData = PogoAPIFixtures.fullSnapshotJSON()
        RecordingURLProtocol.responseContentType = nil
        let transport = URLSessionSensorAPITransport(session: Self.makeSession())

        let data = try await transport.fetchSnapshotData(from: URL(string: "https://test.local/api/v1/snapshot")!)
        XCTAssertFalse(data.isEmpty)
    }

    /// The app-store-cache guard behind the fix for "recovery never lands until the app is
    /// force-quit": a snapshot GET must be provably impossible to answer from any HTTP
    /// cache, not just `URLRequest.cachePolicy` — real caches (an intermediate proxy, an
    /// over-eager library) key off headers too.
    func testFetchSnapshotDataIsAGETWithFullCacheBypassHeaders() async throws {
        RecordingURLProtocol.responseData = PogoAPIFixtures.fullSnapshotJSON()
        RecordingURLProtocol.responseContentType = "application/json; charset=utf-8"
        let transport = URLSessionSensorAPITransport(session: Self.makeSession())
        let url = URL(string: "https://test.local/api/v1/snapshot")!

        _ = try await transport.fetchSnapshotData(from: url)

        let request = try XCTUnwrap(RecordingURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache, no-store, max-age=0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Pragma"), "no-cache")
    }

    func testOpenEventStreamUsesReloadIgnoringLocalCacheDataAndExpectsEventStreamContentType() async throws {
        RecordingURLProtocol.responseData = Data("event: snapshot\ndata: {}\n\n".utf8)
        RecordingURLProtocol.responseContentType = "text/event-stream"
        let transport = URLSessionSensorAPITransport(session: Self.makeSession())

        var lines: [String] = []
        for try await line in transport.openEventStream(from: URL(string: "https://test.local/api/v1/events")!) {
            lines.append(line)
        }

        XCTAssertFalse(lines.isEmpty)
        XCTAssertEqual(RecordingURLProtocol.lastRequest?.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testOpenEventStreamRejectsAnUnexpectedContentType() async {
        RecordingURLProtocol.responseData = Data("<html>not sse</html>".utf8)
        RecordingURLProtocol.responseContentType = "text/html"
        let transport = URLSessionSensorAPITransport(session: Self.makeSession())

        do {
            for try await _ in transport.openEventStream(from: URL(string: "https://test.local/api/v1/events")!) {}
            XCTFail("expected a content-type mismatch to throw")
        } catch {
            // expected
        }
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        return URLSession(configuration: config)
    }
}

/// Intercepts requests made through a `URLSession` configured with it, so tests can inspect
/// the exact `URLRequest` `URLSessionSensorAPITransport` sends (cache policy, headers)
/// without touching real networking.
private final class RecordingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var responseContentType: String? = "application/json"
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func reset() {
        responseData = Data()
        responseContentType = "application/json"
        lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        var headers: [String: String] = [:]
        if let contentType = Self.responseContentType {
            headers["Content-Type"] = contentType
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
