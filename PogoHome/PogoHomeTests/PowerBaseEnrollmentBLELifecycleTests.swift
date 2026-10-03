#if DEBUG
import PowerBaseBLEKit
import XCTest
@testable import PogoHome

/// The connection lifecycle the real central uses (`PowerBaseEnrollmentBLELifecycle`), driven by a
/// scripted radio instead of CoreBluetooth: which connection a `didConnect` / `didFailToConnect` /
/// `didDisconnect` belongs to when the same board is connected again, and that every opening is
/// answered exactly once. No Bluetooth is used; a real radio may behave in ways not scripted here.
@MainActor
final class PowerBaseEnrollmentBLELifecycleTests: XCTestCase {
    @MainActor
    private final class FakeRadio: PowerBaseBLERadio {
        enum Call: Equatable {
            case connect(UUID)
            case cancel(UUID)
        }

        var calls: [Call] = []
        var availability = PowerBaseBLEAvailability.poweredOn
        /// What the system says about each peripheral when asked.
        var disconnected: Set<UUID> = []

        func connect(_ peripheral: UUID) { calls.append(.connect(peripheral)) }
        func cancelConnection(_ peripheral: UUID) { calls.append(.cancel(peripheral)) }
        func isDisconnected(_ peripheral: UUID) -> Bool { disconnected.contains(peripheral) }

        func connects(_ peripheral: UUID) -> Int { calls.filter { $0 == .connect(peripheral) }.count }
        func cancels(_ peripheral: UUID) -> Int { calls.filter { $0 == .cancel(peripheral) }.count }
    }

    /// A connection's GATT side: counts what the lifecycle tells it.
    @MainActor
    private final class FakeOwner: PowerBaseBLELinkOwner {
        var connects = 0
        var ends: [PowerBaseBLELinkError] = []

        func linkDidConnect() { connects += 1 }
        func linkDidEnd(_ error: PowerBaseBLELinkError) { ends.append(error) }
    }

    /// One `open`: how it ended. More than one entry would be a continuation resumed twice (which
    /// also traps), none a continuation never resumed.
    @MainActor
    private final class Opening {
        var results: [Result<Void, PowerBaseBLEOpenError>] = []
        var task: Task<Void, Never>?

        var succeeded: Bool {
            if case .success? = results.first { return results.count == 1 }
            return false
        }

        var error: PowerBaseBLEOpenError? {
            if case let .failure(error)? = results.first, results.count == 1 { return error }
            return nil
        }
    }

    private let board = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let otherBoard = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
    private var radio: FakeRadio!
    private var lifecycle: PowerBaseEnrollmentBLELifecycle!

    override func setUp() async throws {
        radio = FakeRadio()
        makeLifecycle()
    }

    private func makeLifecycle(setupTimeout: Duration = .seconds(5), closeTimeout: Duration = .seconds(5)) {
        lifecycle = PowerBaseEnrollmentBLELifecycle(setupTimeout: setupTimeout, closeTimeout: closeTimeout)
        lifecycle.radio = radio
    }

    /// Starts an `open` and lets it run until it waits (for the radio, for a previous connection or
    /// for `permit`). Without a `permit` the opening may always connect.
    private func open(_ peripheral: UUID, for owner: FakeOwner, permit: @escaping PowerBaseBLESendPermit = {}) async throws -> Opening {
        let opening = Opening()
        let lifecycle = lifecycle!
        opening.task = Task {
            do {
                try await lifecycle.open(peripheral, for: owner, permit: permit)
                opening.results.append(.success(()))
            } catch {
                opening.results.append(.failure(error as? PowerBaseBLEOpenError ?? .connectionFailed("not an open error")))
            }
        }
        try await settle()
        return opening
    }

    /// A connection that is open: connected, GATT service checked.
    private func ready(_ peripheral: UUID) async throws -> FakeOwner {
        let owner = FakeOwner()
        let opening = try await open(peripheral, for: owner)
        lifecycle.didConnect(peripheral)
        lifecycle.setupDidFinish(owner, mismatch: nil)
        try await eventually { opening.succeeded }
        return owner
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(30))
    }

    // MARK: - The same board again

    func testTheSameBoardIsNotConnectedAgainUntilItsPreviousConnectionWasReportedOver() async throws {
        let old = try await ready(board)
        XCTAssertEqual(radio.calls, [.connect(board)])

        // The controller reconnects: the old connection is closed and a new one asked for at once.
        let new = FakeOwner()
        let opening = try await open(board, for: new)
        XCTAssertEqual(old.ends, [.disconnected], "the old connection is over for its owner")
        XCTAssertEqual(radio.calls, [.connect(board), .cancel(board)], "no connect while the old connection's end is outstanding")
        XCTAssertTrue(opening.results.isEmpty)

        // The old connection's end arrives late. It is the old one's: the new one is not harmed.
        lifecycle.didDisconnect(board)
        XCTAssertTrue(new.ends.isEmpty, "the late didDisconnect did not reach the new connection")
        try await eventually { self.radio.connects(self.board) == 2 }
        XCTAssertEqual(radio.calls, [.connect(board), .cancel(board), .connect(board)], "now the new connection is made")
        XCTAssertEqual(new.connects, 0)

        lifecycle.didConnect(board)
        XCTAssertEqual(new.connects, 1)
        lifecycle.setupDidFinish(new, mismatch: nil)
        try await eventually { opening.succeeded }
        XCTAssertTrue(new.ends.isEmpty)
        XCTAssertEqual(old.ends.count, 1, "and the old one heard nothing more")
        XCTAssertEqual(old.connects, 1)

        // The new connection's own end is its own.
        lifecycle.didDisconnect(board)
        XCTAssertEqual(new.ends, [.disconnected])
        lifecycle.didDisconnect(board)
        XCTAssertEqual(new.ends.count, 1, "a repeated callback changes nothing")
        XCTAssertEqual(opening.results.count, 1)
    }

    func testALateCallbackOfAnOpeningThatWasCancelledNeverReachesTheNextConnection() async throws {
        for late in ["didConnect then didDisconnect", "didFailToConnect"] {
            radio = FakeRadio()
            makeLifecycle()
            let old = FakeOwner()
            let cancelled = try await open(board, for: old)
            XCTAssertEqual(radio.calls, [.connect(board)])
            cancelled.task?.cancel()
            try await eventually { cancelled.error == .cancelled }
            XCTAssertEqual(old.ends, [.cancelled])
            XCTAssertEqual(radio.calls, [.connect(board), .cancel(board)], "the pending connect is cancelled")

            let new = FakeOwner()
            let opening = try await open(board, for: new)
            XCTAssertEqual(radio.connects(board), 1, "\(late): the new connect waits")

            if late == "didFailToConnect" {
                lifecycle.didFailToConnect(board)
            } else {
                // The cancelled connect got through before the cancel did.
                lifecycle.didConnect(board)
                XCTAssertEqual(new.connects, 0, "\(late): that connection is not the new owner's")
                XCTAssertEqual(old.connects, 0)
                XCTAssertEqual(radio.connects(board), 1)
                XCTAssertEqual(radio.cancels(board), 2, "it is still to be ended")
                XCTAssertTrue(opening.results.isEmpty)
                lifecycle.didDisconnect(board)
            }
            XCTAssertTrue(new.ends.isEmpty, late)
            try await eventually { self.radio.connects(self.board) == 2 }
            lifecycle.didConnect(board)
            lifecycle.setupDidFinish(new, mismatch: nil)
            try await eventually { opening.succeeded }
            XCTAssertEqual(new.connects, 1)
            XCTAssertEqual(old.ends.count, 1)
            XCTAssertEqual(cancelled.results.count, 1, "\(late): the cancelled opening was answered once")
        }
    }

    func testALateCloseOfAnOldConnectionCannotEndTheNewOne() async throws {
        let old = try await ready(board)
        let new = FakeOwner()
        let opening = try await open(board, for: new)
        lifecycle.didDisconnect(board)
        try await eventually { self.radio.connects(self.board) == 2 }
        XCTAssertEqual(radio.calls, [.connect(board), .cancel(board), .connect(board)])

        // The old session object is closed again while the new connection is being made...
        lifecycle.close(old)
        lifecycle.close(old, .cancelled)
        XCTAssertEqual(radio.cancels(board), 1, "no cancel for a connection the old object doesn't own")
        XCTAssertTrue(new.ends.isEmpty)
        lifecycle.didConnect(board)
        lifecycle.setupDidFinish(new, mismatch: nil)
        try await eventually { opening.succeeded }

        // ...and once more when it is open. Nor can the old one report a GATT result for it.
        lifecycle.close(old)
        lifecycle.setupDidFinish(old, mismatch: .gattMismatch("service"))
        XCTAssertEqual(radio.cancels(board), 1)
        XCTAssertTrue(new.ends.isEmpty)
        XCTAssertEqual(old.ends.count, 1)
        XCTAssertEqual(opening.results.count, 1)
    }

    func testAnotherBoardIsConnectedAtOnceAndTheOldBoardsLateCallbacksAreNotItsOwn() async throws {
        let old = try await ready(board)
        let new = FakeOwner()
        let opening = try await open(otherBoard, for: new)
        XCTAssertEqual(old.ends, [.disconnected], "one connection at a time")
        XCTAssertEqual(radio.calls, [.connect(board), .cancel(board), .connect(otherBoard)], "another peripheral: nothing to wait for")

        lifecycle.didDisconnect(board)
        lifecycle.didFailToConnect(board)
        lifecycle.didConnect(board)
        XCTAssertTrue(new.ends.isEmpty)
        XCTAssertEqual(new.connects, 0, "the old board's callbacks are not the new connection's")
        XCTAssertEqual(radio.connects(board), 1, "and nothing connects to the old board again")

        lifecycle.didConnect(otherBoard)
        lifecycle.setupDidFinish(new, mismatch: nil)
        try await eventually { opening.succeeded }
        XCTAssertEqual(new.connects, 1)
        XCTAssertTrue(new.ends.isEmpty)
    }

    // MARK: - Waiting for the previous connection to end

    func testBluetoothGoingAwayWhileWaitingFailsTheOpeningWithoutConnecting() async throws {
        for state in [PowerBaseBLEAvailability.poweredOff, .resetting] {
            radio = FakeRadio()
            makeLifecycle()
            _ = try await ready(board)
            let new = FakeOwner()
            let opening = try await open(board, for: new)
            XCTAssertTrue(opening.results.isEmpty)

            lifecycle.radioDidBecomeUnavailable(state)
            try await eventually { opening.error == .bluetoothUnavailable(state) }
            XCTAssertEqual(radio.connects(board), 1, "\(state): no connect for the opening that waited")
            XCTAssertEqual(new.ends, [.disconnected])
            XCTAssertEqual(new.connects, 0)

            // Whatever is still reported for the connections that went with Bluetooth is nobody's.
            lifecycle.didDisconnect(board)
            lifecycle.didConnect(board)
            XCTAssertEqual(radio.connects(board), 1)
            XCTAssertEqual(opening.results.count, 1, "\(state): answered once")

            // Bluetooth is back: nothing of before is waited for.
            let next = FakeOwner()
            let again = try await open(board, for: next)
            XCTAssertEqual(radio.connects(board), 2)
            lifecycle.didConnect(board)
            lifecycle.setupDidFinish(next, mismatch: nil)
            try await eventually { again.succeeded }
        }
    }

    func testBluetoothGoingAwayEndsTheOpenConnectionWithoutACancel() async throws {
        let owner = try await ready(board)
        lifecycle.radioDidBecomeUnavailable(.poweredOff)
        XCTAssertEqual(owner.ends, [.disconnected])
        XCTAssertEqual(radio.calls, [.connect(board)], "nothing is asked of a radio that is off")
        lifecycle.close(owner)
        XCTAssertEqual(radio.calls, [.connect(board)])
    }

    func testAnEndThatIsNeverReportedFailsTheOpeningAndNeverConnectsOntoTheOldLink() async throws {
        makeLifecycle(closeTimeout: .milliseconds(60))
        _ = try await ready(board)

        let second = FakeOwner()
        let waited = try await open(board, for: second)
        try await eventually { waited.error == .connectionFailed("previous connection still closing") }
        XCTAssertEqual(radio.connects(board), 1, "no connect onto a link that may still be there")
        XCTAssertEqual(second.connects, 0)
        XCTAssertEqual(second.ends, [.disconnected])
        XCTAssertEqual(waited.results.count, 1)

        // Asking again changes nothing while the system doesn't say the peripheral is disconnected.
        let third = FakeOwner()
        let again = try await open(board, for: third)
        try await eventually { again.error == .connectionFailed("previous connection still closing") }
        XCTAssertEqual(radio.connects(board), 1)

        // The system says it is disconnected: the opening that waited still fails, but the next
        // one may connect.
        radio.disconnected = [board]
        let fourth = FakeOwner()
        let released = try await open(board, for: fourth)
        try await eventually { released.error == .connectionFailed("previous connection still closing") }
        XCTAssertEqual(radio.connects(board), 1, "never the opening that timed out")

        let fifth = FakeOwner()
        let opening = try await open(board, for: fifth)
        XCTAssertEqual(radio.connects(board), 2)
        lifecycle.didConnect(board)
        lifecycle.setupDidFinish(fifth, mismatch: nil)
        try await eventually { opening.succeeded }
        XCTAssertEqual(fifth.connects, 1)
        XCTAssertTrue(fifth.ends.isEmpty)
    }

    func testAnEndReportedAfterTheTimeLimitStillFreesTheBoard() async throws {
        makeLifecycle(closeTimeout: .milliseconds(60))
        _ = try await ready(board)
        let second = FakeOwner()
        let waited = try await open(board, for: second)
        try await eventually { waited.error != nil }

        lifecycle.didDisconnect(board)
        XCTAssertEqual(radio.connects(board), 1, "the opening that failed is not revived")
        let third = FakeOwner()
        let opening = try await open(board, for: third)
        XCTAssertEqual(radio.connects(board), 2, "the end was consumed: nothing to wait for")
        lifecycle.didConnect(board)
        lifecycle.setupDidFinish(third, mismatch: nil)
        try await eventually { opening.succeeded }
    }

    func testCancellingAnOpeningThatWaitsAnswersItOnceAndConnectsNothing() async throws {
        _ = try await ready(board)
        let new = FakeOwner()
        let opening = try await open(board, for: new)
        opening.task?.cancel()
        try await eventually { opening.error == .cancelled }
        XCTAssertEqual(new.ends, [.cancelled])
        XCTAssertEqual(radio.calls, [.connect(board), .cancel(board)], "it never connected, so it has nothing to cancel")

        // The old connection's end arrives when nobody waits for it.
        lifecycle.didDisconnect(board)
        try await settle()
        XCTAssertEqual(radio.connects(board), 1, "no connect for an opening that was cancelled")
        XCTAssertEqual(opening.results.count, 1)

        // The board is free for the next opening.
        let next = FakeOwner()
        _ = try await open(board, for: next)
        XCTAssertEqual(radio.connects(board), 2)
    }

    func testShutdownEndsTheConnectionAndTheWaitingOpeningAndTheNextOpeningStillWaitsForTheEnd() async throws {
        let old = try await ready(board)
        let waiting = FakeOwner()
        let opening = try await open(board, for: waiting)
        lifecycle.shutdown()
        try await eventually { opening.error == .cancelled }
        XCTAssertEqual(waiting.ends, [.cancelled])
        XCTAssertEqual(old.ends.count, 1)
        XCTAssertEqual(radio.calls, [.connect(board), .cancel(board)])

        // A new test starts before the old connection's end was reported.
        let next = FakeOwner()
        let again = try await open(board, for: next)
        XCTAssertEqual(radio.connects(board), 1, "the same rule after a shutdown")
        lifecycle.didDisconnect(board)
        try await eventually { self.radio.connects(self.board) == 2 }
        lifecycle.didConnect(board)
        lifecycle.setupDidFinish(next, mismatch: nil)
        try await eventually { again.succeeded }
        XCTAssertTrue(next.ends.isEmpty)
        XCTAssertEqual(opening.results.count, 1)
    }

    func testShutdownOfAnOpenConnectionCancelsItOnce() async throws {
        let owner = try await ready(board)
        lifecycle.shutdown()
        lifecycle.shutdown()
        lifecycle.close(owner)
        XCTAssertEqual(owner.ends, [.disconnected])
        XCTAssertEqual(radio.calls, [.connect(board), .cancel(board)])
    }

    // MARK: - Each opening is answered once

    func testANewOpeningEndsTheOneUnderWay() async throws {
        let first = FakeOwner()
        let superseded = try await open(board, for: first)
        let second = FakeOwner()
        let opening = try await open(otherBoard, for: second)
        try await eventually { superseded.error == .cancelled }
        XCTAssertEqual(first.ends, [.cancelled])
        XCTAssertEqual(radio.calls, [.connect(board), .cancel(board), .connect(otherBoard)])

        // The first one's connect comes through after all.
        lifecycle.didConnect(board)
        XCTAssertEqual(first.connects, 0)
        XCTAssertEqual(second.connects, 0)
        lifecycle.didConnect(otherBoard)
        lifecycle.setupDidFinish(second, mismatch: nil)
        try await eventually { opening.succeeded }
        XCTAssertEqual(superseded.results.count, 1)
    }

    func testAServiceThatIsNotTheSpecifiedOneFailsTheOpeningAndTheLinkIsWaitedForLikeAnyOther() async throws {
        let owner = FakeOwner()
        let opening = try await open(board, for: owner)
        lifecycle.didConnect(board)
        lifecycle.setupDidFinish(owner, mismatch: .gattMismatch("duplicate endpoint"))
        try await eventually { opening.error == .gattMismatch("duplicate endpoint") }
        XCTAssertEqual(owner.ends, [.disconnected])
        XCTAssertEqual(radio.calls, [.connect(board), .cancel(board)])

        // Late and repeated reports change nothing.
        lifecycle.setupDidFinish(owner, mismatch: nil)
        lifecycle.setupDidFinish(owner, mismatch: .gattMismatch("service"))
        XCTAssertEqual(opening.results.count, 1)

        let next = FakeOwner()
        _ = try await open(board, for: next)
        XCTAssertEqual(radio.connects(board), 1, "its end is still outstanding")
        lifecycle.didDisconnect(board)
        try await eventually { self.radio.connects(self.board) == 2 }
    }

    func testAnOpeningThatGetsNoAnswerInTimeFailsOnceAndItsLateCallbacksChangeNothing() async throws {
        makeLifecycle(setupTimeout: .milliseconds(60))
        let owner = FakeOwner()
        let opening = try await open(board, for: owner)
        try await eventually { opening.error == .connectionFailed("timeout") }
        XCTAssertEqual(owner.ends, [.disconnected])
        XCTAssertEqual(radio.calls, [.connect(board), .cancel(board)], "the pending connect is given up")

        lifecycle.didConnect(board)
        lifecycle.setupDidFinish(owner, mismatch: nil)
        XCTAssertEqual(owner.connects, 0)
        lifecycle.didDisconnect(board)
        lifecycle.didFailToConnect(board)
        XCTAssertEqual(owner.ends.count, 1)
        XCTAssertEqual(opening.results.count, 1)
    }

    func testRepeatedAndMisplacedCallbacksAnswerAnOpeningExactlyOnce() async throws {
        let owner = FakeOwner()
        let opening = try await open(board, for: owner)
        // For a board nobody is connecting to.
        lifecycle.didConnect(otherBoard)
        lifecycle.didDisconnect(otherBoard)
        lifecycle.didFailToConnect(otherBoard)
        XCTAssertTrue(opening.results.isEmpty)
        XCTAssertTrue(owner.ends.isEmpty)

        // The GATT result before the radio connected is not a result.
        lifecycle.setupDidFinish(owner, mismatch: nil)
        try await settle()
        XCTAssertTrue(opening.results.isEmpty)

        lifecycle.didConnect(board)
        lifecycle.didConnect(board)
        XCTAssertEqual(owner.connects, 1)
        lifecycle.setupDidFinish(owner, mismatch: nil)
        lifecycle.setupDidFinish(owner, mismatch: nil)
        lifecycle.setupDidFinish(owner, mismatch: .gattMismatch("service"))
        try await eventually { opening.succeeded }
        XCTAssertTrue(owner.ends.isEmpty, "a late mismatch report does not end an open connection")
        XCTAssertEqual(radio.calls, [.connect(board)])

        // An opening whose task is cancelled after it succeeded stays open.
        opening.task?.cancel()
        try await settle()
        XCTAssertTrue(owner.ends.isEmpty)
        XCTAssertEqual(opening.results.count, 1)
    }

    func testAnOpeningAskedForByACancelledTaskConnectsNothing() async throws {
        let owner = FakeOwner()
        let opening = Opening()
        let lifecycle = lifecycle!
        let board = board
        let task = Task {
            // Cancelled before it gets to open anything.
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await lifecycle.open(board, for: owner, permit: {})
                opening.results.append(.success(()))
            } catch {
                opening.results.append(.failure(error as? PowerBaseBLEOpenError ?? .connectionFailed("not an open error")))
            }
        }
        await task.value
        XCTAssertEqual(opening.error, .cancelled)
        XCTAssertTrue(radio.calls.isEmpty)
    }

    // MARK: - The permit, right before the radio connects

    /// What an opening is allowed, answered the way the controller's permits answer: at once while
    /// the app is active, and never once the run is over. While the app is away, `waiting` waits
    /// for it to come back and `uninterrupted` refuses.
    @MainActor
    private final class Foreground {
        var isAway = false
        private(set) var isOver = false
        private(set) var asked = 0
        private var held: [CheckedContinuation<Void, Never>] = []

        var isHolding: Bool { !held.isEmpty }

        func comeBack() {
            isAway = false
            wake()
        }

        /// The run ends: whatever waits is woken, with a "no".
        func endRun() {
            isOver = true
            wake()
        }

        private func wake() {
            let waiting = held
            held = []
            waiting.forEach { $0.resume() }
        }

        var waiting: PowerBaseBLESendPermit {
            { [self] in
                asked += 1
                while isAway, !isOver {
                    await withCheckedContinuation { held.append($0) }
                }
                if isOver { throw CancellationError() }
            }
        }

        var uninterrupted: PowerBaseBLESendPermit {
            { [self] in
                asked += 1
                if isAway || isOver { throw CancellationError() }
            }
        }
    }

    /// An opening for `board` whose previous connection ended only after the app went to the
    /// background: it is asking `foreground`, and nothing was connected for it.
    private func openingThatAsksItsPermit(_ foreground: Foreground) async throws -> (owner: FakeOwner, opening: Opening) {
        _ = try await ready(board)
        let owner = FakeOwner()
        let opening = try await open(board, for: owner, permit: foreground.waiting)
        XCTAssertEqual(foreground.asked, 0, "nothing is asked while the previous connection's end is outstanding")
        foreground.isAway = true
        lifecycle.didDisconnect(board)
        try await eventually { foreground.isHolding }
        XCTAssertEqual(radio.calls, [.connect(board), .cancel(board)])
        XCTAssertTrue(opening.results.isEmpty)
        return (owner, opening)
    }

    /// Everything that can still arrive for `board` arrives: nothing of it connects.
    private func assertNothingConnectsAnyMore(_ foreground: Foreground, connects: Int, _ context: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        foreground.comeBack()
        lifecycle.didDisconnect(board)
        lifecycle.didFailToConnect(board)
        lifecycle.didConnect(board)
        try await settle()
        XCTAssertEqual(radio.connects(board), connects, "\(context): no connect after the opening ended", file: file, line: line)
    }

    /// The review's reproduction, with the permit handed to the lifecycle as the central now
    /// hands it: the previous connection's end arrives after the permit stopped being valid.
    func testReviewDelayedConnectDoesNotSendAfterForegroundPermitBecameStale() async throws {
        _ = try await ready(board)
        let foreground = Foreground()
        // The real central asks its permit before `connection.open` -> `lifecycle.open`.
        try await foreground.uninterrupted()
        let newer = FakeOwner()
        let pending = try await open(board, for: newer, permit: foreground.uninterrupted)
        XCTAssertEqual(radio.connects(board), 1)
        // While awaiting the old connection's end, the scene goes to the background.
        foreground.isAway = true
        lifecycle.didDisconnect(board)
        try await eventually { pending.error == .cancelled }
        XCTAssertEqual(radio.connects(board), 1, "old didDisconnect must not start a new BLE connect after the foreground permit expired")
        XCTAssertEqual(foreground.asked, 2, "asked again when the wait was over, not only before it")
        XCTAssertEqual(newer.ends, [.cancelled])
        XCTAssertEqual(newer.connects, 0)
        XCTAssertEqual(radio.cancels(board), 1, "it never connected, so it has nothing to cancel")

        try await assertNothingConnectsAnyMore(foreground, connects: 1, "given up")
        XCTAssertEqual(pending.results.count, 1)

        // The end was consumed: the next opening has nothing to wait for.
        let next = FakeOwner()
        _ = try await open(board, for: next, permit: foreground.uninterrupted)
        XCTAssertEqual(radio.connects(board), 2)
    }

    func testAnOpeningWhosePreviousConnectionEndedWhileTheAppWasAwayConnectsOnceWhenItIsBack() async throws {
        let foreground = Foreground()
        let (owner, opening) = try await openingThatAsksItsPermit(foreground)
        try await settle()
        XCTAssertEqual(radio.connects(board), 1, "no connect in the background")
        XCTAssertTrue(owner.ends.isEmpty, "the opening is kept")

        foreground.comeBack()
        try await eventually { self.radio.connects(self.board) == 2 }
        lifecycle.didConnect(board)
        lifecycle.setupDidFinish(owner, mismatch: nil)
        try await eventually { opening.succeeded }
        try await settle()
        XCTAssertEqual(radio.calls, [.connect(board), .cancel(board), .connect(board)], "one connect for the one opening")
        XCTAssertEqual(owner.connects, 1)
        XCTAssertEqual(foreground.asked, 1)
    }

    func testTheFirstConnectionToABoardWaitsForItsPermitToo() async throws {
        let foreground = Foreground()
        foreground.isAway = true
        let owner = FakeOwner()
        let opening = try await open(board, for: owner, permit: foreground.waiting)
        XCTAssertTrue(foreground.isHolding)
        XCTAssertTrue(radio.calls.isEmpty, "nothing to wait for, and still no connect without the permit")

        foreground.comeBack()
        try await eventually { self.radio.calls == [.connect(self.board)] }
        lifecycle.didConnect(board)
        lifecycle.setupDidFinish(owner, mismatch: nil)
        try await eventually { opening.succeeded }

        // A permit that says no: the opening ends without a connect.
        radio = FakeRadio()
        makeLifecycle()
        foreground.isAway = true
        let refused = try await open(board, for: FakeOwner(), permit: foreground.uninterrupted)
        XCTAssertEqual(refused.error, .cancelled)
        XCTAssertTrue(radio.calls.isEmpty)
    }

    func testAnOpeningThatEndsWhileItsPermitIsAskedNeverConnects() async throws {
        for ending in ["task cancelled", "run over", "shutdown", "closed by its owner"] {
            radio = FakeRadio()
            makeLifecycle()
            let foreground = Foreground()
            let (owner, opening) = try await openingThatAsksItsPermit(foreground)

            switch ending {
            case "task cancelled":
                opening.task?.cancel()
                try await eventually { opening.error == .cancelled }
                XCTAssertEqual(owner.ends, [.cancelled], ending)
            case "run over":
                foreground.endRun()
                try await eventually { opening.error == .cancelled }
                XCTAssertEqual(owner.ends, [.cancelled], ending)
            case "shutdown":
                lifecycle.shutdown()
                try await eventually { opening.error == .cancelled }
                XCTAssertEqual(owner.ends, [.cancelled], ending)
            default:
                lifecycle.close(owner)
                try await eventually { opening.error == .connectionFailed("disconnected") }
                XCTAssertEqual(owner.ends, [.disconnected], ending)
            }
            XCTAssertEqual(radio.calls, [.connect(board), .cancel(board)], "\(ending): it never connected, so it has nothing to cancel")

            try await assertNothingConnectsAnyMore(foreground, connects: 1, ending)
            XCTAssertEqual(owner.connects, 0, ending)
            XCTAssertEqual(owner.ends.count, 1, ending)
            XCTAssertEqual(opening.results.count, 1, "\(ending): answered once")

            // The board is free for the next opening.
            let next = FakeOwner()
            let again = try await open(board, for: next)
            XCTAssertEqual(radio.connects(board), 2, ending)
            lifecycle.didConnect(board)
            lifecycle.setupDidFinish(next, mismatch: nil)
            try await eventually { again.succeeded }
        }
    }

    func testACancelledOpeningDoesNotConnectEvenIfItsPermitAnswersFirst() async throws {
        @MainActor final class Asking {
            var task: Task<Void, Never>?
        }
        _ = try await ready(board)
        let asking = Asking()
        let owner = FakeOwner()
        // The task that asked for the opening is cancelled while its permit is answering "yes":
        // the cancellation handler's hop to the main actor arrives only after that answer.
        let opening = try await open(board, for: owner, permit: { asking.task?.cancel() })
        asking.task = opening.task
        lifecycle.didDisconnect(board)
        try await eventually { opening.error == .cancelled }
        try await settle()
        XCTAssertEqual(radio.calls, [.connect(board), .cancel(board)], "no connect that would have to be cancelled right away")
        XCTAssertEqual(owner.ends, [.cancelled])
        XCTAssertEqual(opening.results.count, 1)
    }

    func testBluetoothGoingAwayWhileThePermitIsAskedFailsTheOpeningWithoutConnecting() async throws {
        for state in [PowerBaseBLEAvailability.poweredOff, .resetting] {
            for reported in [true, false] {
                radio = FakeRadio()
                makeLifecycle()
                let foreground = Foreground()
                let (owner, opening) = try await openingThatAsksItsPermit(foreground)
                radio.availability = state
                if reported {
                    lifecycle.radioDidBecomeUnavailable(state)
                } else {
                    // The state change has not been delivered when the permit answers.
                    foreground.comeBack()
                }
                try await eventually { opening.error == .bluetoothUnavailable(state) }
                XCTAssertEqual(owner.ends, [.disconnected], "\(state)")
                XCTAssertEqual(radio.calls, [.connect(board), .cancel(board)], "\(state): nothing is asked of a radio that is off")

                radio.availability = .poweredOn
                try await assertNothingConnectsAnyMore(foreground, connects: 1, "\(state), reported: \(reported)")
                XCTAssertEqual(opening.results.count, 1, "\(state): answered once")
            }
        }
    }

    func testAnOpeningThatReplacesOneWhosePermitIsAskedIsNeitherConnectedNorFailedByTheOldPermit() async throws {
        for peripheral in [board, otherBoard] {
            radio = FakeRadio()
            makeLifecycle()
            let old = Foreground()
            let (first, replaced) = try await openingThatAsksItsPermit(old)

            let new = Foreground()
            new.isAway = true
            let second = FakeOwner()
            let opening = try await open(peripheral, for: second, permit: new.waiting)
            try await eventually { replaced.error == .cancelled }
            XCTAssertEqual(first.ends, [.cancelled])
            XCTAssertTrue(new.isHolding, "the new opening asks its own permit")

            // The old opening's permit answers now -- and it says yes.
            old.comeBack()
            try await settle()
            XCTAssertEqual(radio.calls, [.connect(board), .cancel(board)], "\(peripheral): the old permit connects nothing, not for the new opening either")
            XCTAssertTrue(opening.results.isEmpty, "\(peripheral): and does not end it")
            XCTAssertTrue(second.ends.isEmpty)

            new.comeBack()
            try await eventually { self.radio.calls == [.connect(self.board), .cancel(self.board), .connect(peripheral)] }
            lifecycle.didConnect(peripheral)
            lifecycle.setupDidFinish(second, mismatch: nil)
            try await eventually { opening.succeeded }
            XCTAssertEqual(second.connects, 1)
            XCTAssertEqual(first.connects, 0)
            XCTAssertEqual(replaced.results.count, 1)
        }
    }

    func testTheWaitForThePermitHasNoTimeLimitAndTheConnectHasItsOwn() async throws {
        makeLifecycle(setupTimeout: .milliseconds(400), closeTimeout: .milliseconds(400))
        let foreground = Foreground()
        let (owner, opening) = try await openingThatAsksItsPermit(foreground)
        // Longer than either limit: the app is simply away.
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(opening.results.isEmpty, "neither the previous connection's limit nor the connect's runs while the permit is asked")
        XCTAssertTrue(owner.ends.isEmpty)
        XCTAssertEqual(radio.connects(board), 1)

        // The connect's limit starts with the connect.
        foreground.comeBack()
        try await eventually { self.radio.connects(self.board) == 2 }
        XCTAssertTrue(opening.results.isEmpty)
        try await eventually { opening.error == .connectionFailed("timeout") }
        XCTAssertEqual(owner.ends, [.disconnected])
        XCTAssertEqual(radio.calls, [.connect(board), .cancel(board), .connect(board), .cancel(board)], "the pending connect is given up")
        XCTAssertEqual(opening.results.count, 1)
    }

    func testTheTimeLimitsOfAnOpeningThatEndedDoNotFailTheNextOne() async throws {
        makeLifecycle(setupTimeout: .milliseconds(400), closeTimeout: .milliseconds(400))
        _ = try await ready(board)
        // Waits for the previous connection's end (its limit runs), and is replaced.
        let first = FakeOwner()
        let replaced = try await open(board, for: first)
        let foreground = Foreground()
        foreground.isAway = true
        let second = FakeOwner()
        let opening = try await open(board, for: second, permit: foreground.waiting)
        try await eventually { replaced.error == .cancelled }
        lifecycle.didDisconnect(board)
        try await eventually { foreground.isHolding }

        // Both openings' limits for the previous connection have passed by now.
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(opening.results.isEmpty, "no limit of an earlier wait ends an opening that asks its permit")
        XCTAssertTrue(second.ends.isEmpty)
        XCTAssertEqual(replaced.results.count, 1)

        foreground.comeBack()
        try await eventually { self.radio.connects(self.board) == 2 }
        lifecycle.didConnect(board)
        lifecycle.setupDidFinish(second, mismatch: nil)
        try await eventually { opening.succeeded }
        // The connect's own limit was cancelled with the opening's success.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(second.ends.isEmpty)
        XCTAssertEqual(opening.results.count, 1)
    }
}

/// `proto-ver` and the handshake as the real central runs them (`PowerBaseBLESessionOpener` with
/// the package's real client), over a scripted link: what is asked before each message, and that
/// nothing is sent while the answer is "not now" or after it is "never".
@MainActor
final class PowerBaseEnrollmentBLESessionOpenerTests: XCTestCase {
    /// A connected board that answers `proto-ver` and refuses the first handshake message.
    private final class ScriptedLink: PowerBaseBLELink, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [PowerBaseBLEProtocol.Endpoint] = []
        private var closeCount = 0

        var exchanges: [PowerBaseBLEProtocol.Endpoint] { lock.withLock { sent } }
        var closes: Int { lock.withLock { closeCount } }

        func exchange(endpoint: PowerBaseBLEProtocol.Endpoint, payload: Data) async throws -> Data {
            lock.withLock { sent.append(endpoint) }
            switch endpoint {
            case .version:
                return Data(#"{"prov":{"ver":"v1.1","sec_ver":2,"sec_patch_ver":1,"cap":[]},"pb_enroll":{"proto":1}}"#.utf8)
            default:
                throw PowerBaseBLELinkError.rejected
            }
        }

        func close() async {
            lock.withLock { closeCount += 1 }
        }
    }

    /// The controller's side of a permit: counts the questions, and can hold or refuse one.
    @MainActor
    private final class Foreground {
        var asked = 0
        var holdsQuestion: Int?
        var refusesQuestion: Int?
        private var held: [CheckedContinuation<Void, Never>] = []

        var isHolding: Bool { !held.isEmpty }

        func release() {
            holdsQuestion = nil
            let waiting = held
            held = []
            waiting.forEach { $0.resume() }
        }

        var permit: PowerBaseBLESendPermit {
            { [self] in
                asked += 1
                let question = asked
                if holdsQuestion == question {
                    await withCheckedContinuation { held.append($0) }
                }
                if refusesQuestion == question { throw CancellationError() }
            }
        }
    }

    private let eui64 = PowerBaseBLEEUI64(hex: EnrollmentFixtures.eui64)!

    private func authenticate(_ link: ScriptedLink, _ foreground: Foreground) -> Task<PowerBaseBLEOpenError?, Never> {
        let eui64 = eui64
        let permit = foreground.permit
        return Task {
            do {
                _ = try await PowerBaseBLESessionOpener.authenticate(over: link, eui64: eui64, setupCode: EnrollmentFixtures.setupCode, permit: permit)
                return nil
            } catch {
                return error as? PowerBaseBLEOpenError ?? .connectionFailed("not an open error")
            }
        }
    }

    func testTheHandshakeIsNotStartedBetweenProtoVerAndTheForegroundComingBack() async throws {
        let link = ScriptedLink()
        let foreground = Foreground()
        // The app goes to the background while `proto-ver` is answered.
        foreground.holdsQuestion = 2
        let task = authenticate(link, foreground)
        try await eventually { foreground.isHolding }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(link.exchanges, [.version], "the first handshake message is a new command: not sent")
        XCTAssertEqual(link.closes, 0, "and the connection is kept")

        foreground.release()
        let error = await task.value
        XCTAssertEqual(link.exchanges, [.version, .session], "the same opening goes on with the handshake")
        XCTAssertEqual(error, .client(.handshakeRefused), "this board refuses it; the real handshake is the package's own test")
        XCTAssertEqual(foreground.asked, 2, "asked once before each message that was sent")
        XCTAssertEqual(link.closes, 1, "a failed opening closes its connection")
    }

    func testAnOpeningWhoseRunEndedWhileItWaitedSendsNothingMore() async throws {
        let link = ScriptedLink()
        let foreground = Foreground()
        foreground.holdsQuestion = 2
        foreground.refusesQuestion = 2
        let task = authenticate(link, foreground)
        try await eventually { foreground.isHolding }
        // The run is cancelled while the opening waits: the wait ends, with a "no".
        foreground.release()
        let error = await task.value
        XCTAssertEqual(error, .client(.handshakeInterrupted(.cancelled)))
        XCTAssertEqual(link.exchanges, [.version], "no handshake message for a run that is over")
        XCTAssertEqual(link.closes, 1)
    }

    func testProtoVerIsNotReadWithoutThePermit() async throws {
        let link = ScriptedLink()
        let foreground = Foreground()
        foreground.refusesQuestion = 1
        let error = await authenticate(link, foreground).value
        XCTAssertEqual(error, .client(.versionUnreadable(.cancelled)))
        XCTAssertTrue(link.exchanges.isEmpty)
        XCTAssertEqual(link.closes, 1)
    }
}
#endif
