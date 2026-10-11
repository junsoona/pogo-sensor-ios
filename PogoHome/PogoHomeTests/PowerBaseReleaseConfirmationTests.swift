#if DEBUG
import PowerBaseBLEKit
import XCTest
@testable import PogoHome

/// "삭제 확인": reading a released board's receipt over Bluetooth and handing it to the hub, against
/// a scripted board and a scripted hub. Nothing here uses Bluetooth or a network. What is checked:
/// the board is authenticated and identified before anything is relayed, the receipt goes to the
/// hub byte for byte, and only the hub's `completed` is shown as a confirmed removal.
@MainActor
final class PowerBaseReleaseConfirmationTests: XCTestCase {
    typealias Controller = PowerBaseReleaseConfirmationController

    private var log: EnrollmentEventLog!
    private var hub: FakeRemovalHub!
    private var board: FakeBoard!
    private var provider: FakeBLEBoardProvider!
    private var credentials: InMemoryHubCredentialStore!
    private let eui = EnrollmentFixtures.eui64
    private let receipt = EnrollmentFixtures.releaseReceipt()

    override func setUp() async throws {
        log = EnrollmentEventLog()
        hub = FakeRemovalHub()
        board = FakeBoard(log: log)
        board.set(capabilities: [.bridgeEndpointV1, .managementV1, .releaseReceiptV1])
        board.set(receipt: receipt)
        provider = FakeBLEBoardProvider(board: board, log: log)
        credentials = InMemoryHubCredentialStore([EnrollmentFixtures.credential(hubID: EnrollmentFixtures.hubA, token: "token-A")])
    }

    private func makeController(target: PowerBaseHubTarget = EnrollmentFixtures.pairedTarget()) -> Controller {
        let controller = Controller(
            powerBaseIdentifier: eui, provider: provider, transport: hub, credentials: credentials, quietScanPeriod: .milliseconds(30)
        )
        controller.targetDidChange(target)
        controller.activate()
        controller.startScanning()
        return controller
    }

    private func completed() -> PowerBaseRemoval { RemovalFixtures.removal(.completed, base: eui) }

    private func confirm(_ controller: Controller, setupCode: String = EnrollmentFixtures.setupCode) {
        controller.confirm(boardID: FakeBLEBoardProvider.boardID, setupCode: setupCode)
    }

    private func failure(_ controller: Controller) -> Controller.Failure? {
        if case let .failed(failure) = controller.phase { return failure }
        return nil
    }

    // MARK: - The whole way

    func testTheBoardIsAuthenticatedThenItsReceiptGoesToTheHubByteForByte() async throws {
        hub.scriptReceipt(.success(completed()))
        let controller = makeController()
        XCTAssertTrue(controller.canStart)
        confirm(controller, setupCode: " " + EnrollmentFixtures.setupCode.lowercased() + "\n")
        XCTAssertEqual(controller.phase, .connecting)
        XCTAssertTrue(hub.recorded.isEmpty, "nothing goes to the hub before the board was read")
        try await eventually { !controller.isBusy }

        XCTAssertEqual(controller.phase, .confirmed(completed()), "confirmed is the hub's `completed`")
        XCTAssertEqual(provider.opens, [.init(boardID: FakeBLEBoardProvider.boardID, eui64: eui, setupCode: EnrollmentFixtures.setupCode)],
                       "the board is authenticated with its setup code, under the removed Base's EUI-64")
        XCTAssertEqual(log.all, ["board open", "board status", "board receipt"], "open, who are you, the receipt -- and nothing else")
        XCTAssertTrue(board.starts.isEmpty && board.cancels.isEmpty && board.joinerStarts == 0, "reading a receipt starts and changes nothing on the board")
        XCTAssertEqual(hub.recorded, [.receipt(hubID: EnrollmentFixtures.hubA, token: "token-A", pin: String(repeating: "c", count: 64), receiptHex: receipt.hex)],
                       "one request, with this device's credential for the hub, carrying exactly the board's bytes")
        XCTAssertEqual(board.closed, [1], "the Bluetooth session is closed")
        XCTAssertFalse(controller.canSendAgain)
    }

    // MARK: - Who the board is

    func testAWrongSetupCodeReadsNothingAndTellsTheHubNothing() async throws {
        provider.openErrors = [.client(.authenticationFailed)]
        let controller = makeController()
        confirm(controller)
        try await eventually { !controller.isBusy }
        XCTAssertEqual(failure(controller), .wrongSetupCode)
        XCTAssertEqual(board.receiptCalls, 0)
        XCTAssertTrue(hub.recorded.isEmpty)
    }

    func testAnotherBoardBehindTheSameNameIsNotAskedForAReceipt() async throws {
        board.report(eui64: "00124b0001a2ffff")
        let controller = makeController()
        confirm(controller)
        try await eventually { !controller.isBusy }
        XCTAssertEqual(failure(controller), .differentBoard)
        XCTAssertEqual(board.receiptCalls, 0, "the receipt is only asked of the board that proved to be the removed Base")
        XCTAssertTrue(hub.recorded.isEmpty)
        XCTAssertEqual(board.closed, [1])
    }

    func testOnlyAdvertisersNamingTheRemovedBaseAreOffered() {
        let other = PowerBaseBLEDiscoveredBoard(id: UUID(), name: "POGO-PB-00124B0001A2FFFF", advertisedEUI64: "00124b0001a2ffff", rssi: -30)
        let nameless = PowerBaseBLEDiscoveredBoard(id: UUID(), name: nil, advertisedEUI64: nil, rssi: -20)
        let weak = PowerBaseBLEDiscoveredBoard(id: UUID(), name: nil, advertisedEUI64: eui, rssi: -90)
        provider.boards += [other, nameless, weak]
        let controller = makeController()
        XCTAssertEqual(controller.boards.map(\.advertisedEUI64), [eui, eui], "two sightings of the removed Base, nothing else")
        XCTAssertEqual(controller.boards.first?.id, FakeBLEBoardProvider.boardID, "the stronger signal first")
        controller.confirm(boardID: other.id, setupCode: EnrollmentFixtures.setupCode)
        XCTAssertEqual(failure(controller), .boardNotFound, "a board that does not name the removed Base cannot be picked")
        XCTAssertTrue(provider.opens.isEmpty)
    }

    func testAnInvalidCodeAndAnIneligibleHubSendNothing() {
        let controller = makeController()
        confirm(controller, setupCode: "ABC")
        XCTAssertEqual(failure(controller), .invalidSetupCode)
        XCTAssertTrue(provider.opens.isEmpty)

        for target in [PowerBaseHubTarget(hubID: EnrollmentFixtures.hubA, baseURL: EnrollmentFixtures.urlA, isSimulated: false, isPaired: false),
                       PowerBaseHubTarget(hubID: EnrollmentFixtures.hubA, baseURL: EnrollmentFixtures.urlA, isSimulated: true, isPaired: true)] {
            let other = makeController(target: target)
            confirm(other)
            guard case .notEligible? = failure(other) else { return XCTFail("\(other.phase)") }
            XCTAssertFalse(other.canStart)
        }
        XCTAssertTrue(provider.opens.isEmpty && hub.recorded.isEmpty)
    }

    // MARK: - What the board has

    func testABoardWithoutAReceiptCompletesNothing() async throws {
        board.set(receipt: nil)
        let controller = makeController()
        confirm(controller)
        try await eventually { !controller.isBusy }
        XCTAssertEqual(failure(controller), .noReceipt)
        XCTAssertTrue(hub.recorded.isEmpty, "the hub is told nothing: no receipt, no completion")
        XCTAssertFalse(controller.canSendAgain)
    }

    func testFirmwareWithoutTheCapabilityIsNotAsked() async throws {
        board.set(capabilities: [.bridgeEndpointV1, .managementV1])
        let controller = makeController()
        confirm(controller)
        try await eventually { !controller.isBusy }
        XCTAssertEqual(failure(controller), .boardNeedsUpdate)
        XCTAssertEqual(board.receiptCalls, 0)
        XCTAssertTrue(hub.recorded.isEmpty)
    }

    func testAReceiptRequestWithoutAnAnswerIsAFailureNotANo() async throws {
        board.failNextReceipt(.requestFailed(.timeout))
        let controller = makeController()
        confirm(controller)
        try await eventually { !controller.isBusy }
        XCTAssertEqual(failure(controller), .boardUnreachable)
        XCTAssertTrue(hub.recorded.isEmpty)
    }

    // MARK: - The hub

    func testAReceiptTheHubCouldNotBeReachedWithIsKeptAndSentAgainWithoutBluetooth() async throws {
        hub.scriptReceipt(.failure(.unreachable("timeout")))
        let controller = makeController()
        confirm(controller)
        try await eventually { !controller.isBusy }
        XCTAssertEqual(failure(controller), .hub(.unreachable("timeout")), "read, not delivered: not confirmed")
        XCTAssertTrue(controller.canSendAgain)

        hub.scriptReceipt(.success(completed()))
        controller.sendAgain()
        XCTAssertEqual(controller.phase, .sendingToHub)
        try await eventually { !controller.isBusy }
        XCTAssertEqual(controller.phase, .confirmed(completed()))
        XCTAssertEqual(provider.opens.count, 1, "the second delivery needed no second Bluetooth session")
        XCTAssertEqual(board.receiptCalls, 1)
        XCTAssertEqual(hub.receipts.count, 2)
        XCTAssertEqual(hub.receipts[0], hub.receipts[1], "the same receipt both times")
    }

    func testAReceiptTheHubRejectsIsNotConfirmedAndNotSentAgain() async throws {
        hub.scriptReceipt(.failure(.receiptRejected))
        let controller = makeController()
        confirm(controller)
        try await eventually { !controller.isBusy }
        XCTAssertEqual(failure(controller), .hub(.receiptRejected))
        XCTAssertFalse(controller.canSendAgain, "the same bytes would be rejected again")
        controller.sendAgain()
        XCTAssertEqual(hub.receipts.count, 1)
    }

    func testOnlyTheHubsCompletedForThisBaseIsAConfirmation() async throws {
        // An answer that is not "completed", or names another Base, is not shown as one.
        for answer in [RemovalFixtures.removal(.released, base: eui), RemovalFixtures.removal(.completed, base: RemovalFixtures.otherBase)] {
            hub.scriptReceipt(.success(answer))
            let controller = makeController()
            confirm(controller)
            try await eventually { !controller.isBusy }
            guard case .hub(.badResponse)? = failure(controller) else { return XCTFail("\(controller.phase)") }
        }
    }

    // MARK: - Leaving

    func testLeavingEndsTheConnectionAndNothingLateIsShown() async throws {
        hub.hold()
        hub.scriptReceipt(.success(completed()))
        let controller = makeController()
        confirm(controller)
        try await eventually { self.hub.heldCount == 1 }
        controller.leave()
        XCTAssertEqual(controller.phase, .idle)
        hub.release()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(controller.phase, .idle, "an answer that arrives after the screen was left is not shown")
        XCTAssertFalse(controller.isScanning)
    }

    func testAnotherHubDropsAReceiptThatWasReadForThePreviousOne() async throws {
        hub.scriptReceipt(.failure(.unreachable("timeout")))
        let controller = makeController()
        confirm(controller)
        try await eventually { !controller.isBusy }
        XCTAssertTrue(controller.canSendAgain)
        controller.targetDidChange(EnrollmentFixtures.pairedTarget(hubID: EnrollmentFixtures.hubB, url: EnrollmentFixtures.urlB))
        XCTAssertFalse(controller.canSendAgain, "a receipt is for the hub it was read for")
        XCTAssertEqual(controller.phase, .idle)
    }

    // MARK: - Wording

    func testEveryFailureHasItsOwnWording() {
        let failures: [Controller.Failure] = [
            .notEligible(.notPaired), .credentialUnavailable, .invalidSetupCode, .bluetooth(.poweredOff), .boardNotFound, .wrongSetupCode, .boardLocked,
            .boardUnreachable, .differentBoard, .boardNeedsUpdate, .noReceipt, .hub(.unreachable("x")), .hub(.receiptRejected), .hub(.notSupported),
            .hub(.unauthorized),
        ]
        for failure in failures {
            XCTAssertFalse(PowerBaseReleaseConfirmationText.failureMessage(failure).isEmpty, "\(failure)")
        }
        let distinct = [Controller.Failure.wrongSetupCode, .differentBoard, .boardNeedsUpdate, .noReceipt, .hub(.unreachable("x")), .hub(.receiptRejected), .hub(.notSupported)]
            .map(PowerBaseReleaseConfirmationText.failureMessage)
        XCTAssertEqual(Set(distinct).count, distinct.count)
        XCTAssertEqual(PowerBaseReleaseConfirmationText.steps.count, 3)
        XCTAssertEqual(PowerBaseReleaseConfirmationText.stepIndex(of: .connecting), 0)
        XCTAssertEqual(PowerBaseReleaseConfirmationText.stepIndex(of: .reading), 1)
        XCTAssertEqual(PowerBaseReleaseConfirmationText.stepIndex(of: .sendingToHub), 2)
    }
}

/// The product enrollment run hands a receipt it finds on the board to the hub before it starts
/// the new enrollment (which replaces the board's record, and with it the receipt).
@MainActor
final class PowerBaseEnrollmentReceiptRelayTests: XCTestCase {
    typealias Controller = PowerBaseEnrollmentBLEController

    private var log: EnrollmentEventLog!
    private var hub: FakeEnrollmentHub!
    private var removals: FakeRemovalHub!
    private var board: FakeBoard!
    private var provider: FakeBLEBoardProvider!
    private var credentials: InMemoryHubCredentialStore!
    private let receipt = EnrollmentFixtures.releaseReceipt()

    override func setUp() async throws {
        log = EnrollmentEventLog()
        hub = FakeEnrollmentHub()
        hub.issuedManagement = EnrollmentFixtures.managementCredential()
        removals = FakeRemovalHub()
        board = FakeBoard(log: log)
        board.set(capabilities: [.bridgeEndpointV1, .managementV1, .releaseReceiptV1])
        provider = FakeBLEBoardProvider(board: board, log: log)
        credentials = InMemoryHubCredentialStore([EnrollmentFixtures.credential(hubID: EnrollmentFixtures.hubA, token: "token-A")])
    }

    private func makeController(relay: Bool = true) -> Controller {
        let controller = Controller(
            provider: provider, transport: LoggedEnrollmentHub(hub: hub, log: log), credentials: credentials,
            pollInterval: .milliseconds(10), boardPollInterval: .milliseconds(10), leaveGrace: .milliseconds(40),
            quietScanPeriod: .milliseconds(30), maxReconnects: 3, requireManagement: true, receiptRelay: relay ? removals : nil
        )
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        controller.activate()
        return controller
    }

    private func scriptWaitingSession() {
        let session = EnrollmentFixtures.session(.waitingForHeartbeat, managementGeneration: EnrollmentFixtures.managementGeneration)
        hub.scriptStart(.success(session))
        hub.scriptStatus(.success(session))
    }

    private func isJoining(_ controller: Controller) -> Bool {
        if case .joining = controller.phase { true } else { false }
    }

    private func start(_ controller: Controller) {
        controller.start(boardID: FakeBLEBoardProvider.boardID, expectedEUI64: EnrollmentFixtures.eui64, setupCode: EnrollmentFixtures.setupCode)
    }

    func testAReceiptOnTheBoardIsHandedInBeforeTheNewEnrollmentStarts() async throws {
        board.set(receipt: receipt)
        removals.scriptReceipt(.success(RemovalFixtures.removal(.completed, base: EnrollmentFixtures.eui64)))
        scriptWaitingSession()
        let controller = makeController()
        start(controller)
        try await eventually { self.isJoining(controller) }

        XCTAssertEqual(removals.receipts, [.receipt(hubID: EnrollmentFixtures.hubA, token: "token-A", pin: String(repeating: "c", count: 64), receiptHex: receipt.hex)],
                       "the receipt went to the hub, byte for byte, with this device's credential")
        XCTAssertEqual(controller.relayedReceipts, 1)
        let events = log.all
        let receiptRead = try XCTUnwrap(events.firstIndex(of: "board receipt"))
        let post = try XCTUnwrap(events.firstIndex(of: "hub POST"))
        let begun = try XCTUnwrap(events.firstIndex(of: "board start+management"))
        XCTAssertEqual(Array(events.prefix(3)), ["board open", "board status", "board receipt"], "after the board proved who it is, before anything else")
        XCTAssertTrue(receiptRead < post && post < begun, "read before the hub session and long before the start that replaces the board's record")
        XCTAssertEqual(board.starts.count, 1, "and the enrollment goes on as usual")
        controller.leave()
    }

    func testWhatTheHubMakesOfTheReceiptDoesNotDecideTheEnrollment() async throws {
        board.set(receipt: receipt)
        for refusal in [PowerBaseRemovalError.unreachable("timeout"), .receiptRejected, .notSupported] {
            removals.scriptReceipt(.failure(refusal))
            scriptWaitingSession()
            let controller = makeController()
            start(controller)
            try await eventually { self.isJoining(controller) }
            XCTAssertEqual(controller.relayedReceipts, 0, "\(refusal)")
            controller.leave()
            try await eventually { !controller.isBusy }
            board.forgetAttempt()
            board.set(state: .waiting)
        }
        XCTAssertEqual(removals.receipts.count, 3, "it was offered each time, once")
    }

    func testABoardWithoutAReceiptOrWithoutTheCapabilityCostsNothing() async throws {
        scriptWaitingSession()
        let controller = makeController()
        start(controller)
        try await eventually { self.isJoining(controller) }
        XCTAssertEqual(board.receiptCalls, 1, "asked once")
        XCTAssertTrue(removals.recorded.isEmpty, "nothing to hand in")
        controller.leave()
        try await eventually { !controller.isBusy }

        board.forgetAttempt()
        board.set(state: .waiting)
        board.set(capabilities: [.bridgeEndpointV1, .managementV1])
        scriptWaitingSession()
        let older = makeController()
        start(older)
        try await eventually { self.isJoining(older) }
        XCTAssertEqual(board.receiptCalls, 1, "firmware without the capability is not asked")
        older.leave()
    }

    func testWithoutARelayTheRunNeverAsksForAReceipt() async throws {
        board.set(receipt: receipt)
        scriptWaitingSession()
        let controller = makeController(relay: false)
        start(controller)
        try await eventually { self.isJoining(controller) }
        XCTAssertEqual(board.receiptCalls, 0, "the DEBUG test and every run without a relay are exactly as before")
        XCTAssertFalse(log.all.contains("board receipt"))
        controller.leave()
    }

    func testAReceiptRequestThatLosesTheSessionEndsTheRunBeforeAnyHubSession() async throws {
        board.failNextReceipt(.requestFailed(.timeout))
        let controller = makeController()
        start(controller)
        try await eventually { !controller.isBusy }
        guard case .failed = controller.phase else { return XCTFail("\(controller.phase)") }
        XCTAssertTrue(hub.recorded.isEmpty, "no hub session was made for a board that stopped answering")
        XCTAssertTrue(board.starts.isEmpty)
    }
}
#endif
