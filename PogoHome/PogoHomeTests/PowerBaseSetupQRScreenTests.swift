#if DEBUG
import PowerBaseBLEKit
import SwiftUI
import UIKit
import XCTest
@testable import PogoHome

/// The QR code entry on the three screens that ask for a setup code -- "Power Base 추가", "다른
/// 허브에 연결하기" and "삭제 확인" -- with each screen's real controller, a scripted board, a
/// scripted Bluetooth provider and a scripted hub.
///
/// What is checked on every one of them: only the selected board's own QR code is entered;
/// another board's code changes neither the field nor the selection; and reading a code sends
/// nothing -- not one Bluetooth connection, not one command to the board, not one request to the
/// hub. The user's own button then sends exactly the code that was read, to exactly that board.
@MainActor
final class PowerBaseSetupQRScreenTests: XCTestCase {
    private typealias F = SetupQRFixtures
    private typealias Intake = PowerBaseSetupQRIntake

    private let board = PowerBaseBLEDiscoveredBoard(id: FakeBLEBoardProvider.boardID, name: "POGO-PB-00124B0001A2B3C4", advertisedEUI64: SetupQRFixtures.eui64, rssi: -52)
    private let otherBoard = PowerBaseBLEDiscoveredBoard(id: SetupQRFixtures.otherBoardID, name: "POGO-PB-00124B0001A2B3D9", advertisedEUI64: SetupQRFixtures.otherEUI64, rssi: -60)

    private func makeIntake(for target: Intake.Target) -> Intake {
        let intake = Intake(camera: nil)
        intake.hubDidChange(EnrollmentFixtures.hubA)
        intake.screenDidAppear()
        intake.targetDidChange(target)
        return intake
    }

    /// The rounds every screen goes through. `traffic` describes everything the screen's
    /// controller, provider, board and hub have sent or done so far: it must stay as it is.
    private func readCodes(
        on screen: String, intake: Intake, target: Intake.Target, field: () -> PowerBaseSetupCodeField,
        apply: @escaping (PowerBaseSetupQRPayload) -> Bool, traffic: () -> String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let before = traffic()
        let typed = field().text

        // Another board's (valid) code, several codes, another kind of code: nothing changes.
        for (reading, problem) in [
            (PowerBaseSetupQRReading.symbols([F.otherText]), Intake.Problem.differentBoard),
            (.symbols([F.text, F.otherText]), .severalCodes),
            (.symbols([F.setupCode]), .notPowerBaseCode),
            (.symbols([F.text + "\n"]), .damagedCode),
        ] {
            let ticket = try XCTUnwrap(intake.beginReadingImage(for: target, apply: apply), screen, file: file, line: line)
            XCTAssertEqual(intake.complete(ticket, with: reading), .refused(problem), screen, file: file, line: line)
            XCTAssertEqual(field().text, typed, "\(screen): the field keeps what it had", file: file, line: line)
            XCTAssertNil(field().codeBoardEUI64, screen, file: file, line: line)
            XCTAssertEqual(field().selectedBoardEUI64, target.boardEUI64, "\(screen): the selection is not moved", file: file, line: line)
        }
        XCTAssertEqual(traffic(), before, "\(screen): a refused code sends nothing", file: file, line: line)

        // The selected board's own code: entered, and that is all.
        let ticket = try XCTUnwrap(intake.beginReadingImage(for: target, apply: apply), screen, file: file, line: line)
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .applied, screen, file: file, line: line)
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored, "\(screen): once", file: file, line: line)
        XCTAssertEqual(field().text, F.setupCode, screen, file: file, line: line)
        XCTAssertEqual(field().codeBoardEUI64, F.eui64, screen, file: file, line: line)
        XCTAssertEqual(field().codeForSelectedBoard, F.setupCode, screen, file: file, line: line)
        XCTAssertEqual(traffic(), before, "\(screen): reading the code started nothing", file: file, line: line)
    }

    // MARK: Power Base 추가

    func testRegistrationTakesOnlyTheSelectedBoardsCodeAndStartsNothing() async throws {
        let hub = FakeEnrollmentHub()
        hub.issuedManagement = EnrollmentFixtures.managementCredential()
        let fakeBoard = FakeBoard()
        fakeBoard.set(capabilities: [.bridgeEndpointV1, .managementV1])
        let provider = FakeBLEBoardProvider(board: fakeBoard)
        provider.boards.append(otherBoard)
        let controller = PowerBaseEnrollmentBLEController(
            provider: provider, transport: hub, credentials: InMemoryHubCredentialStore([EnrollmentFixtures.credential()]), pollInterval: .milliseconds(20),
            boardPollInterval: .milliseconds(20), quietScanPeriod: .milliseconds(20), maxReconnects: 1, requireManagement: true
        )
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        // The user looked for boards and picked one: that much Bluetooth is theirs.
        controller.activate()
        controller.startScanning()
        var form = PowerBaseSetupForm(didStartFinding: true, setupCode: "TYPED")
        form.select(board)
        let intake = makeIntake(for: F.target)
        func traffic() -> String {
            "\(provider.opens) \(provider.sentSteps) \(provider.activations) \(provider.scanStarts) \(provider.scanStops) \(hub.recorded) \(fakeBoard.openedSessions) "
                + "\(fakeBoard.statusCalls) \(fakeBoard.starts) \(fakeBoard.cancels) \(controller.phase) \(controller.isBusy) \(controller.isScanning)"
        }

        try readCodes(on: "registration", intake: intake, target: F.target, field: { form.code }, apply: { form.code.fill(from: $0) }, traffic: traffic)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(provider.opens, [], "no connection")
        XCTAssertEqual(hub.recorded, [], "no enrollment session on the hub")
        XCTAssertEqual(fakeBoard.starts, [])
        XCTAssertEqual(controller.phase, .idle)

        // Another board is picked: the code that was read does not go with it.
        var moved = form
        moved.select(otherBoard)
        XCTAssertEqual(moved.setupCode, "")
        XCTAssertEqual(moved.selectedBoardID, otherBoard.id)

        // The user's own "등록": the code that was read, to the board it was read for. The
        // controller authenticates and compares the board's own EUI-64 as it always did.
        fakeBoard.report(eui64: "00124b0001a2ffff")
        let code = try XCTUnwrap(form.code.codeForSelectedBoard)
        controller.start(boardID: board.id, expectedEUI64: F.eui64, setupCode: code)
        try await eventually { !controller.isBusy }
        XCTAssertEqual(provider.opens, [.init(boardID: board.id, eui64: F.eui64, setupCode: F.setupCode)])
        XCTAssertEqual(PowerBaseSetupPresentation.result(of: controller.phase), .notRegistered(.differentBoard),
                       "a QR code that names a board is no proof: the authenticated board's own word still decides")
        XCTAssertEqual(hub.recorded, [], "and the hub was asked for nothing")
        controller.leave()
    }

    // MARK: 다른 허브에 연결하기

    func testMovingToAnotherHubTakesOnlyTheSelectedBoardsCodeAndStartsNothing() async throws {
        let resetBoard = FakeResetBoard()
        let provider = FakeResetProvider(board: resetBoard)
        provider.boards.append(otherBoard)
        let controller = PowerBaseLocalResetController(provider: provider, quietScanPeriod: .milliseconds(20), pollInterval: .milliseconds(5))
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        controller.activate()
        controller.startScanning()
        let shown = try XCTUnwrap(provider.boards.first { $0.advertisedEUI64 == F.eui64 })
        var form = PowerBaseReenrollForm(didStartFinding: true, setupCode: "TYPED")
        form.select(shown)
        let target = Intake.Target(boardID: shown.id, boardEUI64: F.eui64)
        let intake = makeIntake(for: target)
        func traffic() -> String {
            "\(provider.opens) \(resetBoard.log) \(resetBoard.resets) \(resetBoard.executedResets) \(resetBoard.openedSessions) \(controller.phase) \(controller.isBusy) "
                + "\(controller.hasUnresolvedOperation)"
        }

        try readCodes(on: "re-enrollment", intake: intake, target: target, field: { form.code }, apply: { form.code.fill(from: $0) }, traffic: traffic)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(provider.opens.count, 0, "no connection")
        XCTAssertEqual(resetBoard.resets, [], "no reset command")
        XCTAssertEqual(resetBoard.executedResets, 0, "nothing erased")
        XCTAssertEqual(controller.phase, .idle)

        // The user's own "보드 확인": authenticates and stops at the confirmation. Nothing is
        // erased by a code that was read, or by verifying with it.
        let code = try XCTUnwrap(form.code.codeForSelectedBoard)
        controller.verify(boardID: shown.id, expectedEUI64: F.eui64, setupCode: code)
        try await eventually { controller.phase == .awaitingConfirmation }
        XCTAssertEqual(provider.opens.map(\.setupCode), [F.setupCode])
        XCTAssertEqual(provider.opens.map(\.eui64), [F.eui64])
        XCTAssertEqual(resetBoard.resets, [], "the reset still waits for the user's explicit confirmation")
        XCTAssertEqual(resetBoard.executedResets, 0)

        // What the registration that follows is given: this code, for this board only.
        let handoff = try XCTUnwrap(PowerBaseReenrollPresentation.handoff(code: form.code, authenticatedBoard: controller.boardIdentifier))
        XCTAssertEqual(handoff.boardEUI64, F.eui64)
        var next = PowerBaseSetupForm.starting(with: handoff)
        next.select(otherBoard)
        XCTAssertEqual(next.setupCode, "", "another board on the registration screen does not get the code")
        next = PowerBaseSetupForm.starting(with: handoff)
        next.select(board)
        XCTAssertEqual(next.code.codeForSelectedBoard, F.setupCode)
        controller.leave()
    }

    // MARK: 삭제 확인

    func testConfirmingARemovalTakesOnlyTheRemovedBoardsCodeAndStartsNothing() async throws {
        let hub = FakeRemovalHub()
        let fakeBoard = FakeBoard()
        fakeBoard.set(capabilities: [.bridgeEndpointV1, .managementV1, .releaseReceiptV1])
        fakeBoard.set(receipt: EnrollmentFixtures.releaseReceipt())
        let provider = FakeBLEBoardProvider(board: fakeBoard)
        // Another Power Base is in range too: the screen does not offer it.
        provider.boards.append(otherBoard)
        let controller = PowerBaseReleaseConfirmationController(
            powerBaseIdentifier: F.eui64, provider: provider, transport: hub, credentials: InMemoryHubCredentialStore([EnrollmentFixtures.credential()]),
            quietScanPeriod: .milliseconds(20)
        )
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        controller.activate()
        controller.startScanning()
        XCTAssertEqual(controller.boards.map(\.advertisedEUI64), [F.eui64])
        var form = PowerBaseReleaseConfirmationForm(didStartFinding: true, setupCode: "TYPED")
        form.select(controller.boards.first)
        let target = Intake.Target(boardID: board.id, boardEUI64: F.eui64, requiredEUI64: controller.powerBaseIdentifier)
        let intake = makeIntake(for: target)
        func traffic() -> String {
            "\(provider.opens) \(provider.sentSteps) \(hub.recorded) \(fakeBoard.openedSessions) \(fakeBoard.statusCalls) \(fakeBoard.receiptCalls) \(controller.phase) "
                + "\(controller.isBusy)"
        }

        try readCodes(on: "confirm removal", intake: intake, target: target, field: { form.code }, apply: { form.code.fill(from: $0) }, traffic: traffic)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(provider.opens, [], "no connection")
        XCTAssertEqual(fakeBoard.receiptCalls, 0, "no receipt read")
        XCTAssertEqual(hub.recorded, [], "nothing handed to the hub")
        XCTAssertEqual(controller.phase, .idle)

        // A code for a board that is not this removal's board has no scan to arrive in.
        let foreign = Intake.Target(boardID: otherBoard.id, boardEUI64: F.otherEUI64, requiredEUI64: controller.powerBaseIdentifier)
        intake.targetDidChange(foreign)
        XCTAssertNil(intake.beginReadingImage(for: foreign) { form.code.fill(from: $0) })
        intake.targetDidChange(target)

        // The user's own "삭제 확인": the code that was read, and still the hub that decides.
        hub.scriptReceipt(.success(RemovalFixtures.removal(.completed, base: F.eui64)))
        let code = try XCTUnwrap(form.code.codeForSelectedBoard)
        controller.confirm(boardID: board.id, setupCode: code)
        try await eventually { !controller.isBusy }
        XCTAssertEqual(provider.opens, [.init(boardID: board.id, eui64: F.eui64, setupCode: F.setupCode)])
        XCTAssertEqual(hub.receipts.count, 1)
        guard case .confirmed = controller.phase else { return XCTFail("\(controller.phase)") }
        controller.leave()
    }

    // MARK: A code that is known to be another board's is never sent

    func testAFormSelectedAroundTheRuleStillSendsNoForeignCode() throws {
        // A code read for one board, and a selection changed without `select` (restored state,
        // a future caller): the code is not offered to the other board.
        var setup = PowerBaseSetupForm(didStartFinding: true)
        setup.select(board)
        XCTAssertTrue(setup.code.fill(from: F.payload))
        setup.selectedBoardID = otherBoard.id
        XCTAssertEqual(setup.code.codeForSelectedBoard, F.setupCode, "the field still names the board it was read for")
        XCTAssertEqual(setup.code.selectedBoardEUI64, F.eui64)
        setup.select(otherBoard)
        XCTAssertEqual(setup.code.codeForSelectedBoard, "", "told about the selection, it lets go of the code")

        var reenroll = PowerBaseReenrollForm(didStartFinding: true)
        reenroll.select(board)
        XCTAssertTrue(reenroll.code.fill(from: F.payload))
        reenroll.select(otherBoard)
        XCTAssertEqual(reenroll.setupCode, "")
        XCTAssertFalse(reenroll.code.fill(from: F.payload), "and the first board's code cannot be read into it now")

        var confirmation = PowerBaseReleaseConfirmationForm(didStartFinding: true)
        confirmation.select(board)
        XCTAssertTrue(confirmation.code.fill(from: F.payload))
        confirmation.select(nil)
        XCTAssertNil(confirmation.code.codeForSelectedBoard)
        confirmation.select(board)
        XCTAssertEqual(confirmation.code.codeForSelectedBoard, F.setupCode)
    }
}

// MARK: - The real views

/// The form of a hosted screen, owned by the test.
@MainActor
@Observable
private final class FormBox<Form> {
    var form: Form
    init(_ form: Form) { self.form = form }
    var binding: Binding<Form> { Binding(get: { self.form }, set: { self.form = $0 }) }
}

@MainActor
@Observable
private final class QRScenePhaseBox {
    var value: ScenePhase
    init(_ value: ScenePhase) { self.value = value }
}

private struct HostedOwner<Screen: View>: View {
    let phase: QRScenePhaseBox
    let isShown: FormBox<Bool>
    @ViewBuilder let screen: () -> Screen

    var body: some View {
        NavigationStack {
            if isShown.form { screen() } else { Text(verbatim: "left") }
        }
        .environment(\.scenePhase, phase.value)
    }
}

/// The three screens' views as the app builds them: each tells its `PowerBaseSetupQRIntake` what
/// the scan may be for, and when the screen comes and goes.
@MainActor
final class PowerBaseSetupQRViewWiringTests: XCTestCase {
    private typealias F = SetupQRFixtures
    private typealias Intake = PowerBaseSetupQRIntake

    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows {
            window.isHidden = true
            window.rootViewController = nil
        }
        windows = []
    }

    @discardableResult
    private func host(_ view: some View, size: CGSize = CGSize(width: 390, height: 760)) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        windows.append(window)
        return window
    }

    /// A screen as the app shows it: in a navigation stack, with the app's model, in the foreground.
    private func active(@ViewBuilder _ screen: @escaping () -> some View) -> some View {
        HostedOwner(phase: QRScenePhaseBox(.active), isShown: FormBox(true), screen: screen).environment(AppModel(dataSource: MockSensorDataSource()))
    }

    // MARK: Which board the code entry is for

    func testTheRegistrationScreenNamesTheSelectedBoardWhileItsCodeCanBeEntered() async throws {
        typealias P = PowerBaseSetupPresentation
        let provider = FakeBLEBoardProvider(board: FakeBoard())
        let other = PowerBaseBLEDiscoveredBoard(id: F.otherBoardID, name: nil, advertisedEUI64: F.otherEUI64, rssi: -60)
        let nameless = PowerBaseBLEDiscoveredBoard(id: UUID(), name: nil, advertisedEUI64: nil, rssi: -30)
        provider.boards += [other, nameless]
        provider.holdsOpens = true
        let controller = PowerBaseEnrollmentBLEController(
            provider: provider, transport: FakeEnrollmentHub(), credentials: InMemoryHubCredentialStore([EnrollmentFixtures.credential()]),
            quietScanPeriod: .milliseconds(20), requireManagement: true
        )
        var form = PowerBaseSetupForm()
        XCTAssertNil(P.qrTarget(controller: controller, form: form), "no hub, nothing found, nothing picked")
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        controller.activate()
        controller.startScanning()
        form.select(provider.boards[0])
        XCTAssertNil(P.qrTarget(controller: controller, form: form), "the list is not shown before the user asked to look")
        form.didStartFinding = true
        XCTAssertEqual(P.qrTarget(controller: controller, form: form), F.target)
        form.select(other)
        XCTAssertEqual(P.qrTarget(controller: controller, form: form), F.otherTarget)
        form.select(nameless)
        XCTAssertNil(P.qrTarget(controller: controller, form: form), "a peripheral without an EUI-64 is not a row, and not a target")
        form.select(nil)
        XCTAssertNil(P.qrTarget(controller: controller, form: form))

        // The hub cannot be used: no code entry.
        form.select(provider.boards[0])
        controller.targetDidChange(.init(hubID: EnrollmentFixtures.hubA, baseURL: EnrollmentFixtures.urlA, isSimulated: false, isPaired: false))
        XCTAssertNil(P.qrTarget(controller: controller, form: form))
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        XCTAssertEqual(P.qrTarget(controller: controller, form: form), F.target)
        // A run under way, and its result: no code entry.
        controller.start(boardID: FakeBLEBoardProvider.boardID, expectedEUI64: F.eui64, setupCode: F.setupCode)
        XCTAssertTrue(controller.isBusy)
        XCTAssertNil(P.qrTarget(controller: controller, form: form))
        controller.cancel()
        provider.releaseHeld()
        try await eventually { !controller.isBusy }
        XCTAssertNotNil(P.result(of: controller.phase))
        XCTAssertNil(P.qrTarget(controller: controller, form: form), "a result is shown")
        controller.leave()
    }

    func testTheReenrollScreenNamesTheSelectedBoardWhileItsCodeCanBeEntered() {
        typealias P = PowerBaseReenrollPresentation
        let shown = PowerBaseBLEDiscoveredBoard(id: F.boardID, name: nil, advertisedEUI64: F.eui64, rssi: -50)
        let other = PowerBaseBLEDiscoveredBoard(id: F.otherBoardID, name: nil, advertisedEUI64: F.otherEUI64, rssi: -60)
        var state = PowerBaseReenrollScreenState(phase: .idle, availability: .poweredOn, boards: [shown, other], hubName: "Hub")
        var form = PowerBaseReenrollForm(didStartFinding: true)
        XCTAssertNil(P.qrTarget(state: state, form: form))
        form.select(shown)
        XCTAssertEqual(P.qrTarget(state: state, form: form), F.target)
        form.select(other)
        XCTAssertEqual(P.qrTarget(state: state, form: form), F.otherTarget)
        form.select(shown)
        // Where the code entry is not shown, there is nothing to read a code for.
        for phase in [PowerBaseLocalResetController.Phase.connecting, .checking, .awaitingConfirmation, .resetting, .ready(.resetVerified), .failed(.wrongSetupCode)] {
            state.phase = phase
            XCTAssertNil(P.qrTarget(state: state, form: form), "\(phase)")
        }
        // After a result that could not be confirmed the board is asked again: the entry is back.
        state.phase = .uncertain(.answerLost)
        XCTAssertEqual(P.qrTarget(state: state, form: form), F.target)
        // While a sent command is unresolved only the board it went to is offered.
        state.hasUnresolvedOperation = true
        state.unresolvedBoardIdentifier = F.otherEUI64
        XCTAssertNil(P.qrTarget(state: state, form: form))
        // The hub not being ready does not stand in the way of the first half, as before.
        state = PowerBaseReenrollScreenState(phase: .idle, availability: .poweredOn, boards: [shown], hubIneligibility: .notPaired)
        XCTAssertEqual(P.qrTarget(state: state, form: form), F.target)
    }

    func testTheConfirmationScreenNamesTheRemovedBoardOnly() async throws {
        typealias C = PowerBaseReleaseConfirmationContent
        let provider = FakeBLEBoardProvider(board: FakeBoard())
        let other = PowerBaseBLEDiscoveredBoard(id: F.otherBoardID, name: nil, advertisedEUI64: F.otherEUI64, rssi: -40)
        provider.boards.append(other)
        provider.holdsOpens = true
        let controller = PowerBaseReleaseConfirmationController(
            powerBaseIdentifier: F.eui64, provider: provider, transport: FakeRemovalHub(),
            credentials: InMemoryHubCredentialStore([EnrollmentFixtures.credential()]), quietScanPeriod: .milliseconds(20)
        )
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        controller.activate()
        controller.startScanning()
        var form = PowerBaseReleaseConfirmationForm(didStartFinding: true)
        XCTAssertNil(C.qrTarget(controller: controller, form: form))
        form.select(controller.boards.first)
        let removed = Intake.Target(boardID: FakeBLEBoardProvider.boardID, boardEUI64: F.eui64, requiredEUI64: F.eui64)
        XCTAssertEqual(C.qrTarget(controller: controller, form: form), removed)
        XCTAssertTrue(removed.isUsable)
        // Another Power Base in range is not offered, and cannot be made the target.
        form.select(other)
        XCTAssertNil(C.qrTarget(controller: controller, form: form))
        form.select(controller.boards.first)
        controller.confirm(boardID: FakeBLEBoardProvider.boardID, setupCode: F.setupCode)
        XCTAssertTrue(controller.isBusy)
        XCTAssertNil(C.qrTarget(controller: controller, form: form), "a run under way")
        controller.leave()
    }

    // MARK: The screens tell their intake which board that is

    /// The real screens, hosted: the board of the form they start with is the intake's target
    /// while its code can be entered, and stops being it the moment a run begins -- so that a
    /// picture that was still being read then enters nothing.
    func testTheRegistrationScreenKeepsItsIntakeUpToDate() async throws {
        let provider = FakeBLEBoardProvider(board: FakeBoard())
        provider.holdsOpens = true
        let controller = PowerBaseEnrollmentBLEController(
            provider: provider, transport: FakeEnrollmentHub(), credentials: InMemoryHubCredentialStore([EnrollmentFixtures.credential()]),
            quietScanPeriod: .milliseconds(20), requireManagement: true
        )
        var form = PowerBaseSetupForm(didStartFinding: true)
        form.select(provider.boards[0])
        let intake = Intake(camera: nil)
        let box = QRFieldBox()
        box.field.select(boardEUI64: F.eui64)
        let screen = PowerBaseSetupView(makeController: { controller }, makeQRIntake: { intake }, initialForm: form)
        try host(active { screen })
        try await eventually { intake.isScreenPresent }
        XCTAssertNil(intake.currentTarget, "the app reads no paired hub here: no code entry")
        // The run below is about the screen, so the controller is given a paired hub and boards.
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        controller.activate()
        controller.startScanning()
        try await eventually { intake.currentTarget == F.target }

        let late = try XCTUnwrap(intake.beginReadingImage(for: F.target) { box.apply($0) })
        controller.start(boardID: FakeBLEBoardProvider.boardID, expectedEUI64: F.eui64, setupCode: F.setupCode)
        try await eventually { intake.currentTarget == nil }
        XCTAssertNil(intake.scan)
        XCTAssertEqual(intake.complete(late, with: .symbols([F.text])), .ignored)
        XCTAssertEqual(box.offers, 0)
        controller.leave()
    }

    func testTheReenrollScreenKeepsItsIntakeUpToDate() async throws {
        let provider = FakeResetProvider(board: FakeResetBoard())
        let controller = PowerBaseLocalResetController(provider: provider, quietScanPeriod: .milliseconds(20), pollInterval: .milliseconds(5))
        var form = PowerBaseReenrollForm(didStartFinding: true)
        form.select(provider.boards[0])
        let target = Intake.Target(boardID: provider.boards[0].id, boardEUI64: F.eui64)
        let intake = Intake(camera: nil)
        let box = QRFieldBox()
        box.field.select(boardEUI64: F.eui64)
        let screen = PowerBaseReenrollView(makeController: { controller }, makeQRIntake: { intake }, initialForm: form)
        try host(active { screen })
        try await eventually { intake.isScreenPresent }
        controller.activate()
        controller.startScanning()
        try await eventually { intake.currentTarget == target }

        let late = try XCTUnwrap(intake.beginReadingImage(for: target) { box.apply($0) })
        controller.verify(boardID: provider.boards[0].id, expectedEUI64: F.eui64, setupCode: F.setupCode)
        try await eventually { intake.currentTarget == nil }
        XCTAssertEqual(intake.complete(late, with: .symbols([F.text])), .ignored)
        XCTAssertEqual(box.offers, 0)
        controller.leave()
    }

    func testTheConfirmationScreenKeepsItsIntakeUpToDate() async throws {
        let provider = FakeBLEBoardProvider(board: FakeBoard())
        provider.holdsOpens = true
        let controller = PowerBaseReleaseConfirmationController(
            powerBaseIdentifier: F.eui64, provider: provider, transport: FakeRemovalHub(),
            credentials: InMemoryHubCredentialStore([EnrollmentFixtures.credential()]), quietScanPeriod: .milliseconds(20)
        )
        // Not selected yet: the screen selects the removed Base by itself when it shows up.
        let intake = Intake(camera: nil)
        let box = QRFieldBox()
        box.field.select(boardEUI64: F.eui64)
        let screen = PowerBaseReleaseConfirmationView(
            powerBaseIdentifier: F.eui64, makeController: { controller }, makeQRIntake: { intake }, initialForm: PowerBaseReleaseConfirmationForm(didStartFinding: true)
        )
        try host(active { screen })
        try await eventually { intake.isScreenPresent }
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        // The list is drawn (the user tapped "찾기" there) before the Base shows up in it.
        try await Task.sleep(for: .milliseconds(300))
        controller.activate()
        controller.startScanning()
        let removed = Intake.Target(boardID: FakeBLEBoardProvider.boardID, boardEUI64: F.eui64, requiredEUI64: F.eui64)
        try await eventually { intake.currentTarget == removed }

        let late = try XCTUnwrap(intake.beginReadingImage(for: removed) { box.apply($0) })
        controller.confirm(boardID: FakeBLEBoardProvider.boardID, setupCode: F.setupCode)
        try await eventually { intake.currentTarget == nil }
        XCTAssertEqual(intake.complete(late, with: .symbols([F.text])), .ignored)
        XCTAssertEqual(box.offers, 0)
        controller.leave()
    }

    // MARK: The screens tell the intake when they come and go

    func testEveryScreenTellsItsIntakeWhenItAppearsLeavesAndGoesToTheBackground() async throws {
        let model = AppModel(dataSource: MockSensorDataSource())
        let screens: [(String, (Intake) -> AnyView)] = [
            ("registration", { intake in
                AnyView(PowerBaseSetupView(
                    makeController: { PowerBaseEnrollmentBLEController(provider: FakeBLEBoardProvider(board: FakeBoard()), transport: FakeEnrollmentHub(), requireManagement: true) },
                    makeQRIntake: { intake }
                ))
            }),
            ("re-enrollment", { intake in
                AnyView(PowerBaseReenrollView(makeController: { PowerBaseLocalResetController(provider: FakeResetProvider(board: FakeResetBoard())) }, makeQRIntake: { intake }))
            }),
            ("confirm removal", { intake in
                AnyView(PowerBaseReleaseConfirmationView(
                    powerBaseIdentifier: SetupQRFixtures.eui64,
                    makeController: {
                        PowerBaseReleaseConfirmationController(
                            powerBaseIdentifier: SetupQRFixtures.eui64, provider: FakeBLEBoardProvider(board: FakeBoard()), transport: FakeRemovalHub(),
                            credentials: InMemoryHubCredentialStore([])
                        )
                    },
                    makeQRIntake: { intake }
                ))
            }),
        ]
        for (name, make) in screens {
            let intake = Intake(camera: nil)
            XCTAssertFalse(intake.isScreenPresent, name)
            let phase = QRScenePhaseBox(.active)
            let isShown = FormBox(true)
            let window = try host(HostedOwner(phase: phase, isShown: isShown) { make(intake) }.environment(model))
            try await eventually { intake.isScreenPresent }
            XCTAssertFalse(intake.isSuspended, name)

            phase.value = .inactive
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(intake.isSuspended, "\(name): the app switcher or a system alert (the camera question) holds nothing back")
            phase.value = .background
            try await eventually { intake.isSuspended }
            phase.value = .inactive
            phase.value = .active
            try await eventually { !intake.isSuspended }

            isShown.form = false
            try await eventually { !intake.isScreenPresent }
            window.isHidden = true
        }
    }

    func testAScreenThatAppearsInTheBackgroundTellsItsIntakeSo() async throws {
        let model = AppModel(dataSource: MockSensorDataSource())
        let intake = Intake(camera: nil)
        let screen = PowerBaseSetupView(
            makeController: { PowerBaseEnrollmentBLEController(provider: FakeBLEBoardProvider(board: FakeBoard()), transport: FakeEnrollmentHub(), requireManagement: true) },
            makeQRIntake: { intake }
        )
        try host(HostedOwner(phase: QRScenePhaseBox(.background), isShown: FormBox(true)) { screen }.environment(model))
        try await eventually { intake.isScreenPresent && intake.isSuspended }
    }

    // MARK: The scanner sheet

    /// The camera row's sheet over a screen built like the app's: opening it does not make the
    /// screen "disappear" (which would end the scan at once), it shows while the scan is the
    /// current one, and it goes away by itself when the selected board's code was read.
    func testTheScannerSheetStaysOpenForItsScanAndClosesWhenTheCodeWasRead() async throws {
        let provider = FakeQRCameraProvider()
        let intake = Intake(camera: PowerBaseSetupQRCamera(provider: provider))
        var form = PowerBaseSetupForm(didStartFinding: true)
        form.select(PowerBaseBLEDiscoveredBoard(id: F.boardID, name: nil, advertisedEUI64: F.eui64, rssi: -50))
        let box = FormBox(form)
        let screen = NavigationStack {
            List {
                Section {
                    PowerBaseSetupCodeEntry(field: box.binding.code, qrTarget: F.target, qr: intake)
                }
            }
            .onAppear {
                intake.screenDidAppear()
                intake.targetDidChange(F.target)
            }
            .onDisappear { intake.screenDidDisappear() }
        }
        let window = try host(screen)
        try await eventually { intake.isScreenPresent }
        XCTAssertNil(window.rootViewController?.presentedViewController)
        XCTAssertEqual(provider.accessRequests + provider.starts, 0, "showing the rows uses no camera")

        XCTAssertNotNil(PowerBaseSetupQRRows.begin(.camera, intake: intake, target: F.target, field: box.binding.code))
        try await eventually(timeout: .seconds(5)) { window.rootViewController?.presentedViewController != nil }
        try await eventually { provider.isRunning }
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(intake.isScreenPresent, "the screen under the sheet has not gone away")
        XCTAssertNotNil(intake.scan)
        XCTAssertTrue(provider.isRunning)

        provider.show(F.otherText)
        try await eventually { intake.problem == .differentBoard }
        XCTAssertNotNil(window.rootViewController?.presentedViewController, "the scanner stays open and says why")
        XCTAssertEqual(box.form.setupCode, "")

        provider.show(F.text)
        try await eventually { box.form.setupCode == F.setupCode }
        XCTAssertFalse(provider.isRunning)
        try await eventually(timeout: .seconds(5)) { window.rootViewController?.presentedViewController == nil }
        XCTAssertTrue(intake.didFill)
        XCTAssertTrue(intake.isScreenPresent)
    }
}
#endif
