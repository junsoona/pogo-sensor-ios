import XCTest
@testable import PogoHome

final class ReconnectBackoffTests: XCTestCase {
    func testFirstAttemptHasNoDelay() {
        XCTAssertEqual(ReconnectBackoff.delaySeconds(forAttempt: 0), 0)
    }

    func testDelayDoublesEachAttempt() {
        XCTAssertEqual(ReconnectBackoff.delaySeconds(forAttempt: 1), 1)
        XCTAssertEqual(ReconnectBackoff.delaySeconds(forAttempt: 2), 2)
        XCTAssertEqual(ReconnectBackoff.delaySeconds(forAttempt: 3), 4)
        XCTAssertEqual(ReconnectBackoff.delaySeconds(forAttempt: 4), 8)
    }

    func testDelayIsCappedAndNeverGrowsUnbounded() {
        let cap = 30.0
        for attempt in 5...100 {
            XCTAssertLessThanOrEqual(ReconnectBackoff.delaySeconds(forAttempt: attempt, cap: cap), cap)
        }
        // And it must actually reach the cap, not stay stuck at some smaller ceiling.
        XCTAssertEqual(ReconnectBackoff.delaySeconds(forAttempt: 20, cap: cap), cap)
    }

    func testDelayIsNeverZeroOrNegativeForARealRetry() {
        // A busy loop would show up as a zero (or negative) delay on real retries.
        for attempt in 1...10 {
            XCTAssertGreaterThan(ReconnectBackoff.delaySeconds(forAttempt: attempt), 0)
        }
    }
}
