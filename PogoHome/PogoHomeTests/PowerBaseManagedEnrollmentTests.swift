#if DEBUG
import PowerBaseBLEKit
import XCTest
@testable import PogoHome

/// The product "Power Base 추가" run: `PowerBaseEnrollmentBLEController` with `requireManagement`,
/// against a scripted hub and a scripted board. Nothing here uses Bluetooth or a network. What is
/// checked: the hub's management credential goes to the board exactly as the hub issued it and
/// only with message 0x06, a board or hub that cannot do that is not enrolled without it, and the
/// only success is the hub's `heartbeat_received`.
@MainActor
final class PowerBaseManagedEnrollmentTests: XCTestCase {
    typealias Controller = PowerBaseEnrollmentBLEController
    typealias Presentation = PowerBaseSetupPresentation

    private var log: EnrollmentEventLog!
    private var hub: FakeEnrollmentHub!
    private var board: FakeBoard!
    private var provider: FakeBLEBoardProvider!
    private var credentials: InMemoryHubCredentialStore!

    private let generation = EnrollmentFixtures.managementGeneration

    override func setUp() async throws {
        log = EnrollmentEventLog()
        hub = FakeEnrollmentHub()
        hub.issuedManagement = EnrollmentFixtures.managementCredential()
        board = FakeBoard(log: log)
        board.set(capabilities: [.bridgeEndpointV1, .managementV1])
        provider = FakeBLEBoardProvider(board: board, log: log)
        credentials = InMemoryHubCredentialStore([EnrollmentFixtures.credential(hubID: EnrollmentFixtures.hubA, token: "token-A")])
    }

    private func makeController(requireManagement: Bool = true) -> Controller {
        let controller = Controller(
            provider: provider, transport: LoggedEnrollmentHub(hub: hub, log: log), credentials: credentials,
            pollInterval: .milliseconds(10), boardPollInterval: .milliseconds(10), leaveGrace: .milliseconds(40),
            quietScanPeriod: .milliseconds(30), maxReconnects: 3, requireManagement: requireManagement
        )
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        controller.activate()
        return controller
    }

    private func start(_ controller: Controller, setupCode: String = EnrollmentFixtures.setupCode) {
        controller.start(boardID: FakeBLEBoardProvider.boardID, expectedEUI64: EnrollmentFixtures.eui64, setupCode: setupCode)
    }

    private func session(_ state: PowerBaseEnrollmentSession.State, generation: String? = EnrollmentFixtures.managementGeneration) -> PowerBaseEnrollmentSession {
        EnrollmentFixtures.session(state, managementGeneration: generation)
    }

    private func isJoining(_ controller: Controller) -> Bool {
        if case .joining = controller.phase { true } else { false }
    }

    private func failure(_ controller: Controller) -> Controller.Failure? {
        if case let .failed(failure) = controller.phase { return failure }
        return nil
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    // MARK: - The whole way

    func testTheHubsCredentialGoesToTheBoardWithMessage06AndOnlyTheHeartbeatIsSuccess() async throws {
        hub.scriptStart(.success(session(.preparing)))
        hub.scriptStatus(.success(session(.preparing)), .success(session(.waitingForHeartbeat)))
        let controller = makeController()

        start(controller)
        XCTAssertEqual(Presentation.stage(phase: controller.phase, boardProgress: nil), .verifyingBoard)
        XCTAssertTrue(hub.recorded.isEmpty, "nothing goes to the hub before the board is authenticated")
        try await eventually { self.isJoining(controller) }

        let post = try XCTUnwrap(hub.recorded(.start).first)
        XCTAssertEqual(hub.recorded(.start).count, 1)
        XCTAssertTrue(post.asksForBridgeEndpoint)
        XCTAssertTrue(post.asksForManagement, "the product run asks the hub for a management credential")
        XCTAssertEqual(post.eui64, EnrollmentFixtures.eui64, "the authenticated EUI-64")

        let delivered = try XCTUnwrap(board.starts.first)
        XCTAssertEqual(board.starts.count, 1, "exactly one start")
        XCTAssertEqual(delivered.managementGeneration, hub.issuedManagement?.generation, "the generation the hub issued")
        XCTAssertEqual(delivered.managementHubID, hub.issuedManagement?.hubID, "the hub the credential belongs to")
        XCTAssertEqual(delivered.endpoint, EnrollmentFixtures.bridgeEndpoint, "the hub's address comes from the hub, not from the user")
        XCTAssertEqual(delivered.pskd, post.pskd)
        XCTAssertTrue(log.all.contains("board start+management"))
        XCTAssertFalse(log.all.contains("board start"), "never the message without the credential")

        // The board's own progress is progress, whatever it says.
        board.advance(to: .enrolled, state: .enrolled, result: 17)
        try await eventually { controller.boardProgress == .enrolled }
        try await settle()
        XCTAssertNil(Presentation.result(of: controller.phase), "an enrolled board is not a registered Power Base")
        XCTAssertEqual(Presentation.stage(phase: controller.phase, boardProgress: controller.boardProgress), .confirmingWithHub)

        hub.scriptStatus(.success(session(.heartbeatReceived)))
        try await eventually { !controller.isBusy }
        XCTAssertEqual(Presentation.result(of: controller.phase), .registered)
        XCTAssertEqual(Presentation.stage(phase: controller.phase, boardProgress: controller.boardProgress), .done)
        XCTAssertTrue(hub.recorded(.cancel).isEmpty)
        XCTAssertTrue(board.cancels.isEmpty)
    }

    func testWithoutRequireManagementTheRunIsTheEarlierOne() async throws {
        hub.scriptStart(.success(session(.waitingForHeartbeat, generation: nil)))
        hub.scriptStatus(.success(session(.waitingForHeartbeat, generation: nil)))
        let controller = makeController(requireManagement: false)
        start(controller)
        try await eventually { self.isJoining(controller) }
        XCTAssertEqual(hub.recorded(.start).first?.asksForManagement, false)
        XCTAssertNil(board.starts.first?.managementGeneration)
        XCTAssertTrue(log.all.contains("board start"))
        controller.leave()
    }

    // MARK: - Who the board is

    func testABoardThatIsNotTheSelectedOneNeverReachesTheHub() async throws {
        board.report(eui64: "00124b0001a2ffff")
        let controller = makeController()
        start(controller)
        try await eventually { !controller.isBusy }
        guard case .differentBoard? = failure(controller) else { return XCTFail("\(controller.phase)") }
        XCTAssertTrue(hub.recorded.isEmpty, "no hub session for a board that is not the one picked")
        XCTAssertTrue(board.starts.isEmpty)
        XCTAssertEqual(Presentation.result(of: controller.phase), .notRegistered(.differentBoard))
    }

    func testAWrongSetupCodeNeverReachesTheHub() async throws {
        provider.openErrors = [.client(.authenticationFailed)]
        let controller = makeController()
        start(controller)
        try await eventually { !controller.isBusy }
        XCTAssertEqual(failure(controller), .authenticationFailed)
        XCTAssertTrue(hub.recorded.isEmpty)
        XCTAssertEqual(Presentation.result(of: controller.phase), .notRegistered(.wrongSetupCode))
    }

    func testAnInvalidSetupCodeIsNotSentAnywhere() {
        let controller = makeController()
        start(controller, setupCode: "ABC")
        XCTAssertEqual(failure(controller), .invalidSetupCode)
        XCTAssertTrue(provider.opens.isEmpty, "no Bluetooth connection for a code that is not a setup code")
        XCTAssertTrue(hub.recorded.isEmpty)
    }

    // MARK: - Versions

    func testABoardWithoutManagementIsNotEnrolledWithoutIt() async throws {
        board.set(capabilities: [.bridgeEndpointV1])
        let controller = makeController()
        start(controller)
        try await eventually { !controller.isBusy }
        XCTAssertEqual(failure(controller), .boardNeedsUpdate)
        XCTAssertTrue(hub.recorded.isEmpty, "no hub session for a board that could not take the credential")
        XCTAssertTrue(board.starts.isEmpty)
        XCTAssertEqual(Presentation.result(of: controller.phase), .notRegistered(.boardNeedsUpdate))
    }

    func testAHubWithoutManagementIsNotAskedAgainWithoutIt() async throws {
        hub.scriptStart(.failure(.managementNotSupported))
        let controller = makeController()
        start(controller)
        try await eventually { !controller.isBusy }
        XCTAssertEqual(failure(controller), .hub(.managementNotSupported, board: nil))
        XCTAssertEqual(hub.recorded(.start).count, 1, "one request; no fallback to an enrollment without the credential")
        XCTAssertTrue(board.starts.isEmpty, "nothing reached the board")
        XCTAssertEqual(Presentation.result(of: controller.phase), .notRegistered(.hubNeedsUpdate))
    }

    // MARK: - The credential

    func testAnAnswerWithoutACredentialSendsNothingToTheBoardAndCancelsItsSession() async throws {
        hub.issuedManagement = nil
        hub.scriptStart(.success(session(.waitingForHeartbeat)))
        hub.scriptCancel(.success(session(.cancelled)))
        let controller = makeController()
        start(controller)
        try await eventually { !controller.isBusy }
        guard case .hubEndpoint(.managementMissing, _)? = failure(controller) else { return XCTFail("\(controller.phase)") }
        XCTAssertTrue(board.starts.isEmpty, "the board gets no start without the credential")
        try await eventually { self.hub.recorded(.cancel).count == 1 }
        XCTAssertEqual(hub.recorded(.cancel).first?.sessionID, EnrollmentFixtures.sessionID, "the session is cancelled by name")
        XCTAssertEqual(Presentation.result(of: controller.phase), .notRegistered(.hubNeedsUpdate))
    }

    func testACredentialOfAnotherGenerationThanTheSessionsIsNotDelivered() async throws {
        hub.issuedManagement = EnrollmentFixtures.managementCredential(generation: EnrollmentFixtures.otherManagementGeneration)
        hub.scriptStart(.success(session(.waitingForHeartbeat)))
        hub.scriptCancel(.success(session(.cancelled)))
        let controller = makeController()
        start(controller)
        try await eventually { !controller.isBusy }
        guard case .hubEndpoint(.managementMissing, _)? = failure(controller) else { return XCTFail("\(controller.phase)") }
        XCTAssertTrue(board.starts.isEmpty)
    }

    func testASessionThatChangesItsGenerationIsNotDeliveredTo() async throws {
        hub.scriptStart(.success(session(.preparing)))
        hub.scriptStatus(.success(session(.waitingForHeartbeat, generation: EnrollmentFixtures.otherManagementGeneration)))
        hub.scriptCancel(.success(session(.cancelled)))
        let controller = makeController()
        start(controller)
        try await eventually { !controller.isBusy }
        guard case .hubEndpoint(.changed, _)? = failure(controller) else { return XCTFail("\(controller.phase)") }
        XCTAssertTrue(board.starts.isEmpty, "a credential is only delivered for the session it was issued with")
    }

    // MARK: - What is and is not said

    func testAnEnrolledBoardTheHubNeverHeardIsPartlyDoneAndNothingIsReset() async throws {
        hub.scriptStart(.success(session(.waitingForHeartbeat)))
        hub.scriptStatus(.success(session(.waitingForHeartbeat)))
        let controller = makeController()
        start(controller)
        try await eventually { self.isJoining(controller) }
        board.advance(to: .enrolled, state: .enrolled, result: 17)
        try await eventually { controller.boardProgress == .enrolled }

        hub.replaceStatus(.success(session(.expired)))
        try await eventually { !controller.isBusy }
        XCTAssertEqual(Presentation.result(of: controller.phase), .partlyDone)
        XCTAssertNil(Presentation.stage(phase: controller.phase, boardProgress: controller.boardProgress), "no step of the progress list is shown as reached")
        XCTAssertTrue(board.cancels.isEmpty, "an enrolled board is not asked to undo anything")
    }

    func testNothingTheScreenCanShowCarriesASecret() async throws {
        hub.scriptStart(.success(session(.waitingForHeartbeat)))
        hub.scriptStatus(.success(session(.waitingForHeartbeat)), .success(session(.heartbeatReceived)))
        let controller = makeController()
        start(controller)
        try await eventually { !controller.isBusy }
        XCTAssertEqual(Presentation.result(of: controller.phase), .registered)

        let pskd = try XCTUnwrap(hub.recorded(.start).first?.pskd)
        let key = String(repeating: "a5", count: 32)
        var shown = ""
        dump(controller.phase, to: &shown)
        dump(controller.boardProgress as Any, to: &shown)
        dump(hub.issuedManagement as Any, to: &shown)
        shown += String(describing: hub.issuedManagement!) + String(reflecting: hub.issuedManagement!)
        for stage in PowerBaseSetupStage.allCases { shown += PowerBaseSetupText.stageTitle(stage) }
        shown += PowerBaseSetupText.resultMessage(.registered)
        for secret in [pskd, key, key.uppercased(), EnrollmentFixtures.setupCode, "token-A"] {
            XCTAssertFalse(shown.contains(secret), "a secret appears in what can be shown")
        }
    }

    // MARK: - After a result

    func testAcknowledgingAResultGivesTheStartBackAndIsIgnoredDuringARun() async throws {
        hub.scriptStart(.success(session(.waitingForHeartbeat)))
        hub.scriptStatus(.success(session(.waitingForHeartbeat)))
        let controller = makeController()
        start(controller)
        try await eventually { self.isJoining(controller) }
        controller.acknowledgeResult()
        XCTAssertTrue(isJoining(controller), "a run under way is not dropped by leaving a result")

        hub.replaceStatus(.success(session(.heartbeatReceived)))
        try await eventually { !controller.isBusy }
        controller.acknowledgeResult()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.boardProgress)
        XCTAssertNil(Presentation.result(of: controller.phase))
    }
}
#endif
