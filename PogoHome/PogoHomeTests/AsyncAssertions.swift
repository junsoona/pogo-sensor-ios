import XCTest

/// `XCTAssertThrowsError` for an `async` expression (its autoclosure can't `await`).
@MainActor
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message.isEmpty ? "expected an error" : message, file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
