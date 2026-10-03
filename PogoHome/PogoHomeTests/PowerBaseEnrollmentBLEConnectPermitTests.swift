#if DEBUG
import Foundation
import PowerBaseBLEKit
import XCTest
@testable import PogoHome

/// Bluetooth for the controller with the real connection lifecycle underneath. `openSession` goes
/// the real central's way (`PowerBaseEnrollmentBLECentral.openSession`): the permit, Bluetooth's
/// state, `PowerBaseEnrollmentBLELifecycle.open` with the same permit, then the permit before each
/// of the opening's three messages. The radio is this object instead of CoreBluetooth.
///
/// Real: the controller, its permits, the lifecycle -- so every `connect` counted here was decided
/// by the code the central connects through. Scripted: the radio's callbacks, the GATT check
/// (always the specified service) and the handshake (a `FakeBoard` session). No Bluetooth is used.
@MainActor
final class LifecycleBLEBoardProvider: PowerBaseBLEBoardProviding, PowerBaseBLERadio {
    static let boardID = FakeBLEBoardProvider.boardID

    private(set) var availability = PowerBaseBLEAvailability.poweredOn
    var boards: [PowerBaseBLEDiscoveredBoard]
    var onChange: (() -> Void)?

    let board: FakeBoard
    let lifecycle = PowerBaseEnrollmentBLELifecycle(setupTimeout: .seconds(5), closeTimeout: .seconds(5))
    private let log: EnrollmentEventLog
    private(set) var opens = 0
    /// What the lifecycle asked of the radio.
    private(set) var connects = 0
    private(set) var cancels = 0
    /// The radio reports the end of a connection by itself when it was cancelled. Off: the end is
    /// outstanding until the test reports it with `reportEnd()`.
    var reportsEnds = true

    init(board: FakeBoard, log: EnrollmentEventLog) {
        self.board = board
        self.log = log
        boards = [PowerBaseBLEDiscoveredBoard(id: Self.boardID, name: "POGO-PB-" + board.eui64.hex.uppercased(), advertisedEUI64: board.eui64.hex, rssi: -52)]
        lifecycle.radio = self
    }

    /// Bluetooth's state changes, told to the lifecycle the way the central tells it.
    func set(availability: PowerBaseBLEAvailability) {
        self.availability = availability
        if availability != .poweredOn { lifecycle.radioDidBecomeUnavailable(availability) }
        onChange?()
    }

    /// CoreBluetooth reports, late, that the connection that was cancelled is over.
    func reportEnd() {
        lifecycle.didDisconnect(Self.boardID)
    }

    // MARK: PowerBaseBLEBoardProviding

    func activate() {}
    func startScanning() { onChange?() }
    func stopScanning() {}
    func shutdown() { lifecycle.shutdown() }

    func openSession(
        boardID: UUID, eui64: PowerBaseBLEEUI64, setupCode: String, permit: @escaping PowerBaseBLESendPermit
    ) async throws -> any PowerBaseBLEBoardSession {
        opens += 1
        log.add("board open")
        do {
            try await permit()
        } catch {
            throw PowerBaseBLEOpenError.cancelled
        }
        guard availability == .poweredOn else { throw PowerBaseBLEOpenError.bluetoothUnavailable(availability) }
        let link = Link(lifecycle: lifecycle)
        try await lifecycle.open(boardID, for: link, permit: permit)
        // `proto-ver` and the two handshake messages.
        for _ in 0..<3 {
            do {
                try await permit()
            } catch {
                lifecycle.close(link)
                throw PowerBaseBLEOpenError.client(.handshakeInterrupted(.cancelled))
            }
        }
        return Session(base: board.openSession(), link: link, lifecycle: lifecycle)
    }

    // MARK: PowerBaseBLERadio

    func connect(_ peripheral: UUID) {
        connects += 1
        log.add("radio connect")
        Task { self.lifecycle.didConnect(peripheral) }
    }

    func cancelConnection(_ peripheral: UUID) {
        cancels += 1
        guard reportsEnds else { return }
        Task { self.lifecycle.didDisconnect(peripheral) }
    }

    func isDisconnected(_ peripheral: UUID) -> Bool { false }

    /// A connection's GATT side: the service is always the specified one.
    @MainActor
    private final class Link: PowerBaseBLELinkOwner {
        private weak var lifecycle: PowerBaseEnrollmentBLELifecycle?

        init(lifecycle: PowerBaseEnrollmentBLELifecycle) {
            self.lifecycle = lifecycle
        }

        func linkDidConnect() {
            Task { self.lifecycle?.setupDidFinish(self, mismatch: nil) }
        }

        func linkDidEnd(_ error: PowerBaseBLELinkError) {}
    }

    /// The board's session; closing it gives the connection up, like the real client does.
    private nonisolated struct Session: PowerBaseBLEBoardSession {
        let base: FakeBoardSession
        let link: Link
        let lifecycle: PowerBaseEnrollmentBLELifecycle

        func status(issueChallenge: Bool, requestID: PowerBaseBLERequestID?) async throws -> PowerBaseBLEStatus {
            try await base.status(issueChallenge: issueChallenge, requestID: requestID)
        }

        func start(target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID, challenge: PowerBaseBLEChallenge, pskd: String) async throws -> PowerBaseBLECode {
            try await base.start(target: target, requestID: requestID, challenge: challenge, pskd: pskd)
        }

        func cancel(target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID) async throws -> PowerBaseBLECode {
            try await base.cancel(target: target, requestID: requestID)
        }

        func close() async {
            await base.close()
            await MainActor.run { lifecycle.close(link) }
        }
    }
}

/// The controller's foreground rules at the moment a connection is really started, with the real
/// lifecycle between the controller and a scripted radio: a connect that had to wait for the end
/// of the previous connection is decided when that wait is over, not before it.
@MainActor
final class PowerBaseEnrollmentBLEConnectPermitTests: XCTestCase {
    typealias Controller = PowerBaseEnrollmentBLEController

    private var log: EnrollmentEventLog!
    private var hub: FakeEnrollmentHub!
    private var board: FakeBoard!
    private var provider: LifecycleBLEBoardProvider!
    private var credentials: InMemoryHubCredentialStore!
    private var reports: [Controller.CleanupReport] = []

    override func setUp() async throws {
        credentials = InMemoryHubCredentialStore([
            EnrollmentFixtures.credential(hubID: EnrollmentFixtures.hubA, token: "token-A"),
            EnrollmentFixtures.credential(hubID: EnrollmentFixtures.hubB, token: "token-B", certificate: String(repeating: "d", count: 64)),
        ])
        log = EnrollmentEventLog()
        freshFixtures()
    }

    private func freshFixtures() {
        log.clear()
        hub = FakeEnrollmentHub()
        board = FakeBoard(log: log)
        provider = LifecycleBLEBoardProvider(board: board, log: log)
        reports = []
    }

    private func makeController(maxReconnects: Int = 3) -> Controller {
        let controller = Controller(
            provider: provider, transport: LoggedEnrollmentHub(hub: hub, log: log), credentials: credentials,
            pollInterval: .milliseconds(10), boardPollInterval: .milliseconds(10), leaveGrace: .milliseconds(40),
            quietScanPeriod: .milliseconds(30), maxReconnects: maxReconnects
        )
        controller.onCleanupReport = { [weak self] in self?.reports.append($0) }
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        controller.activate()
        return controller
    }

    private func start(_ controller: Controller) {
        controller.start(boardID: LifecycleBLEBoardProvider.boardID, expectedEUI64: EnrollmentFixtures.eui64, setupCode: EnrollmentFixtures.setupCode)
    }

    private func scriptWaitingHub() {
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
    }

    private func isJoining(_ controller: Controller) -> Bool {
        if case .joining = controller.phase { true } else { false }
    }

    private func outcome(_ controller: Controller) -> Controller.Outcome? {
        if case let .finished(outcome) = controller.phase { return outcome }
        return nil
    }

    private func failure(_ controller: Controller) -> Controller.Failure? {
        if case let .failed(failure) = controller.phase { return failure }
        return nil
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    /// A first run ended before any hub session, and the end of its connection is not reported
    /// yet. A second run is started: its authentication waits for that end, nothing connected.
    private func startARunThatWaitsForTheEndOfThePreviousConnection(_ controller: Controller) async throws {
        provider.reportsEnds = false
        board.report(eui64: "00124b0001a2b3c5")
        start(controller)
        try await eventually { self.failure(controller) == .differentBoard(actual: "00124b0001a2b3c5") }
        try await eventually { self.provider.cancels == 1 }
        XCTAssertEqual(provider.connects, 1)
        XCTAssertTrue(hub.recorded.isEmpty)

        board.report(eui64: EnrollmentFixtures.eui64)
        start(controller)
        try await eventually { self.provider.opens == 2 }
        try await settle()
        XCTAssertEqual(controller.phase, .authenticating)
        XCTAssertEqual(provider.connects, 1, "the new connection waits for the end of the previous one")
    }

    // MARK: - Before a hub session exists

    func testAnAuthenticationWhosePreviousConnectionEndsWhileTheAppIsAwayConnectsOnceWhenItIsBack() async throws {
        scriptWaitingHub()
        let controller = makeController()
        try await startARunThatWaitsForTheEndOfThePreviousConnection(controller)

        controller.sceneDidEnterBackground()
        provider.reportEnd()
        try await settle()
        XCTAssertEqual(provider.connects, 1, "the late end of the old connection starts no connect in the background")
        XCTAssertEqual(controller.phase, .authenticating, "the run and its opening are kept")
        XCTAssertTrue(hub.recorded.isEmpty)

        provider.reportsEnds = true
        controller.sceneDidBecomeActive()
        try await eventually { self.isJoining(controller) }
        XCTAssertEqual(provider.connects, 2, "the opening that waited connected, once")
        XCTAssertEqual(provider.opens, 2, "the same opening went on: no new one was asked for")
        XCTAssertEqual(hub.recorded(.start).count, 1)
        XCTAssertEqual(board.starts.count, 1)
        XCTAssertEqual(board.joinerStarts, 1)
        controller.leave()
    }

    /// Where the connect of a run without a hub session can be waiting when the run ends.
    private enum WaitPoint: CaseIterable {
        /// The end of the previous connection is still outstanding.
        case previousEnd
        /// That end arrived in the background: the permit is asked.
        case permit
    }

    private enum Ending: CaseIterable {
        case cancel, leave, anotherHub
    }

    func testARunThatEndsWhileItsConnectWaitsNeverConnects() async throws {
        for point in WaitPoint.allCases {
            for ending in Ending.allCases {
                let context = "\(point), \(ending)"
                freshFixtures()
                scriptWaitingHub()
                let controller = makeController()
                try await startARunThatWaitsForTheEndOfThePreviousConnection(controller)
                controller.sceneDidEnterBackground()
                if point == .permit {
                    provider.reportEnd()
                    try await settle()
                    XCTAssertEqual(provider.connects, 1, context)
                }

                switch ending {
                case .cancel:
                    controller.cancel()
                    try await eventually { self.failure(controller) == .stopped(.init(hub: .notNeeded, board: .notNeeded)) }
                case .leave:
                    controller.leave()
                    XCTAssertEqual(controller.phase, .idle, context)
                    try await eventually { self.reports.count == 1 }
                case .anotherHub:
                    controller.targetDidChange(EnrollmentFixtures.pairedTarget(hubID: EnrollmentFixtures.hubB, url: EnrollmentFixtures.urlB))
                    XCTAssertEqual(controller.phase, .failed(.sourceChanged), context)
                    try await eventually { self.reports.count == 1 }
                }

                // The permit is released, and everything that can still arrive arrives.
                controller.sceneDidBecomeActive()
                provider.reportEnd()
                provider.lifecycle.didFailToConnect(LifecycleBLEBoardProvider.boardID)
                provider.lifecycle.didConnect(LifecycleBLEBoardProvider.boardID)
                try await settle()
                XCTAssertEqual(provider.connects, 1, "\(context): no connect for a run that is over")
                XCTAssertEqual(provider.opens, 2, context)
                XCTAssertTrue(hub.recorded.isEmpty, "\(context): no POST, no DELETE without a session")
                XCTAssertTrue(board.starts.isEmpty, context)
                XCTAssertFalse(controller.isBusy, context)

                // The board is free: a new run connects for itself.
                provider.reportsEnds = true
                start(controller)
                try await eventually { self.isJoining(controller) }
                XCTAssertEqual(provider.connects, 2, "\(context): the new run's own connection")
                XCTAssertEqual(hub.recorded(.start).count, 1, context)
                XCTAssertEqual(board.starts.count, 1, context)
                controller.leave()
            }
        }
    }

    func testBluetoothGoingAwayWhileAConnectWaitsForTheForegroundEndsTheRunWithoutConnecting() async throws {
        for state in [PowerBaseBLEAvailability.poweredOff, .resetting] {
            freshFixtures()
            scriptWaitingHub()
            let controller = makeController()
            try await startARunThatWaitsForTheEndOfThePreviousConnection(controller)
            controller.sceneDidEnterBackground()
            provider.reportEnd()
            try await settle()

            provider.set(availability: state)
            try await eventually { self.failure(controller) == .bluetooth(state) }
            provider.set(availability: .poweredOn)
            controller.sceneDidBecomeActive()
            provider.reportEnd()
            try await settle()
            XCTAssertEqual(provider.connects, 1, "\(state): the opening that waited went with Bluetooth")
            XCTAssertTrue(hub.recorded.isEmpty, "\(state)")
            XCTAssertEqual(failure(controller), .bluetooth(state), "\(state)")
        }
    }

    // MARK: - With a hub session

    func testADeliveryReconnectWhosePreviousConnectionEndsWhileTheAppIsAwayIsGivenUpAndTheHubIsAskedFirst() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.preparing)))
        // One try: the opening that is given up for the background must not use it up.
        let controller = makeController(maxReconnects: 1)
        start(controller)
        try await eventually { !self.hub.recorded(.status).isEmpty }
        XCTAssertEqual(provider.connects, 1)

        // The connection is lost, and its end is not reported yet when the delivery connects again.
        provider.reportsEnds = false
        board.disconnect()
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        try await eventually { self.provider.opens == 2 && self.provider.cancels == 1 }
        try await settle()
        XCTAssertEqual(provider.connects, 1, "the new connection waits for the end of the previous one")

        controller.sceneDidEnterBackground()
        provider.reportEnd()
        try await settle()
        XCTAssertEqual(provider.connects, 1, "the late end of the old connection starts no connect in the background")
        XCTAssertTrue(board.starts.isEmpty)
        XCTAssertTrue(controller.isBusy)
        let hubRequests = hub.recorded.count
        try await settle()
        XCTAssertEqual(hub.recorded.count, hubRequests, "and no poll either")

        log.clear()
        provider.reportsEnds = true
        controller.sceneDidBecomeActive()
        try await eventually { self.isJoining(controller) }
        let events = log.all
        XCTAssertEqual(events.first, "hub GET", "the hub is asked before the board hears anything")
        let asked = try XCTUnwrap(events.firstIndex(of: "hub GET"))
        let connected = try XCTUnwrap(events.firstIndex(of: "radio connect"))
        XCTAssertLessThan(asked, connected, "the hub's answer comes before the connect")
        XCTAssertEqual(provider.connects, 2, "one new connection")
        XCTAssertEqual(provider.opens, 3, "the opening that was given up was not carried on; a new one was made")
        XCTAssertEqual(board.starts.count, 1)
        XCTAssertEqual(board.joinerStarts, 1)
        XCTAssertEqual(hub.recorded(.start).count, 1)
        controller.leave()
    }

    func testAMonitorReconnectWhosePreviousConnectionEndsWhileTheAppIsAwayConnectsOnlyAfterTheHubAnswered() async throws {
        scriptWaitingHub()
        let controller = makeController()
        start(controller)
        try await eventually { self.isJoining(controller) }
        XCTAssertEqual(provider.connects, 1)

        provider.reportsEnds = false
        board.advance(to: .running, state: .attaching)
        board.disconnect()
        try await eventually { self.provider.opens == 2 && self.provider.cancels == 1 }
        try await settle()
        XCTAssertEqual(provider.connects, 1, "the new connection waits for the end of the previous one")

        hub.holdStatus()
        controller.sceneDidEnterBackground()
        provider.reportEnd()
        try await settle()
        XCTAssertEqual(provider.connects, 1, "the late end of the old connection starts no connect in the background")

        // Back, but the hub has not answered yet: the connect still waits.
        provider.reportsEnds = true
        controller.sceneDidBecomeActive()
        try await settle()
        XCTAssertEqual(provider.connects, 1, "the hub is asked first")
        hub.releaseHeld()
        try await eventually { controller.boardProgress == .attaching }
        XCTAssertEqual(provider.connects, 2, "then the same opening connects, once")
        XCTAssertEqual(provider.opens, 2)
        XCTAssertEqual(board.starts.count, 1, "the original request is looked up; nothing is started")
        XCTAssertEqual(hub.recorded(.start).count, 1)
        controller.leave()
    }

    // MARK: - The clean-up's own rule

    func testAnExplicitCancelStillConnectsForItsCleanUpWhileTheAppIsAway() async throws {
        scriptWaitingHub()
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        start(controller)
        try await eventually { self.isJoining(controller) }
        // The cancel on the live session gets no answer, so one more connection is made for it.
        board.failNextCancel(.requestFailed(.timeout))
        controller.sceneDidEnterBackground()
        controller.cancel()
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(provider.connects, 2, "cleaning up is not held back by the background")
        XCTAssertEqual(outcome(controller)?.cleanup?.board, .taken)
        XCTAssertEqual(board.cancels.count, 2)
        XCTAssertEqual(outcome(controller)?.session.state, .cancelled)
    }
}
#endif
