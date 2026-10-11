#if DEBUG
import PowerBaseBLEKit
import SwiftUI
import UIKit
import XCTest
@testable import PogoHome

/// "Power Base 추가" and "다른 허브에 연결하기" look for boards by themselves when they are entered
/// (2026-10-08). What these tests hold the two controllers and the two screens to:
///
/// - entering starts using Bluetooth and scans, once;
/// - a view that is rebuilt, a second `onAppear`, a screen that comes back from under another
///   one within a moment: no second activation, no second search (the list and what was picked
///   in it stay);
/// - Bluetooth off or not allowed: said, nothing found; coming on starts the search without a tap;
/// - the background starts nothing, pauses a search and goes on with it -- the same list -- when
///   the app is back; really leaving the screen ends it;
/// - nothing starts over a run, a question to the user, an unresolved command or a result;
/// - looking is only looking: not one connection, not one command to a board, not one request to
///   the hub.
///
/// The provider, the boards and the hub are scripted; no Bluetooth is used.
@MainActor
final class PowerBaseAutomaticSearchTests: XCTestCase {
    private typealias Enrollment = PowerBaseEnrollmentBLEController
    private typealias Reset = PowerBaseLocalResetController

    // MARK: - "Power Base 추가": PowerBaseEnrollmentBLEController

    private var hub: FakeEnrollmentHub!
    private var provider: FakeBLEBoardProvider!
    private var credentials: InMemoryHubCredentialStore!

    override func setUp() async throws {
        hub = FakeEnrollmentHub()
        hub.issuedManagement = EnrollmentFixtures.managementCredential()
        let board = FakeBoard()
        board.set(capabilities: [.bridgeEndpointV1, .managementV1])
        provider = FakeBLEBoardProvider(board: board)
        credentials = InMemoryHubCredentialStore([EnrollmentFixtures.credential()])
    }

    private func makeEnrollment(automatic: Bool = true, target: PowerBaseHubTarget = EnrollmentFixtures.pairedTarget(), leaveGrace: Duration = .milliseconds(40)) -> Enrollment {
        let controller = Enrollment(
            provider: provider, transport: hub, credentials: credentials, pollInterval: .milliseconds(10), boardPollInterval: .milliseconds(10),
            leaveGrace: leaveGrace, quietScanPeriod: .milliseconds(30), maxReconnects: 1, requireManagement: true, automaticSearch: automatic
        )
        controller.targetDidChange(target)
        return controller
    }

    /// Everything a search must never cause.
    private func assertOnlyLooked(_ controller: Enrollment, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(provider.opens, [], "no connection to a board", file: file, line: line)
        XCTAssertEqual(provider.sentSteps, [], "no command to a board", file: file, line: line)
        XCTAssertEqual(hub.recorded, [], "no request to the hub", file: file, line: line)
        XCTAssertEqual(controller.phase, .idle, file: file, line: line)
        XCTAssertFalse(controller.isBusy, file: file, line: line)
    }

    func testEnteringTheScreenStartsUsingBluetoothAndLooksOnce() {
        let controller = makeEnrollment()
        XCTAssertEqual(provider.activations, 0, "creating the controller uses no Bluetooth")
        XCTAssertFalse(controller.usesBluetooth)

        controller.screenDidAppear()

        XCTAssertEqual(provider.activations, 1, "the permission question, if any, comes with entering the screen")
        XCTAssertEqual(provider.scanStarts, 1)
        XCTAssertTrue(controller.usesBluetooth)
        XCTAssertTrue(controller.isScanning)
        XCTAssertEqual(controller.boards.count, 1, "what is found is listed")
        assertOnlyLooked(controller)
    }

    func testWithoutTheOptionEnteringStartsNothing() {
        let controller = makeEnrollment(automatic: false)
        controller.screenDidAppear()
        XCTAssertEqual(provider.activations, 0, "the DEBUG test screen and \"삭제 확인\" still wait for their button")
        XCTAssertEqual(provider.scanStarts, 0)
        XCTAssertFalse(controller.isScanning)
    }

    func testARepeatedAppearanceAndAScreenThatComesRightBackStartNothingAgain() async throws {
        let controller = makeEnrollment()
        controller.screenDidAppear()
        controller.screenDidAppear()
        controller.screenDidAppear()
        XCTAssertEqual(provider.activations, 1)
        XCTAssertEqual(provider.scanStarts, 1, "a second onAppear is not a second search")

        // Rebuilt, or covered for a moment: gone and back within the grace period.
        controller.screenDidDisappear()
        controller.screenDidAppear()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(provider.activations, 1)
        XCTAssertEqual(provider.scanStarts, 1, "the list is not started over")
        XCTAssertEqual(provider.scanStops, 0, "and the search was never stopped")
        XCTAssertEqual(provider.scanResumes, 0)
        XCTAssertTrue(controller.isScanning)
        assertOnlyLooked(controller)
    }

    func testReallyLeavingEndsTheSearchAndComingBackLooksAgainWithoutAskingForBluetoothAgain() async throws {
        let controller = makeEnrollment()
        controller.screenDidAppear()
        controller.screenDidDisappear()
        try await eventually { !controller.isScanning }
        XCTAssertEqual(provider.scanStops, 1, "leaving ends the search")

        // Late news from Bluetooth for a screen that is gone starts nothing.
        provider.set(availability: .poweredOff)
        provider.set(availability: .poweredOn)
        XCTAssertEqual(provider.scanStarts, 1)
        XCTAssertFalse(controller.isScanning)

        controller.screenDidAppear()
        XCTAssertEqual(provider.scanStarts, 2, "a new appearance is a new search")
        XCTAssertEqual(provider.activations, 1, "Bluetooth was already in use: it is not activated a second time")
        assertOnlyLooked(controller)
    }

    func testBluetoothOffOrNotAllowedIsShownAndComingOnStartsTheSearchWithoutATap() {
        for unavailable in [PowerBaseBLEAvailability.poweredOff, .denied, .unknown, .resetting] {
            let board = FakeBoard()
            provider = FakeBLEBoardProvider(board: board)
            provider.availability = unavailable
            let controller = makeEnrollment()
            controller.screenDidAppear()
            XCTAssertEqual(provider.activations, 1, "\(unavailable)")
            XCTAssertEqual(controller.availability, unavailable, "the screen can say why nothing is found (\(unavailable))")
            XCTAssertNotNil(unavailable == .unknown || unavailable == .resetting ? "" : PowerBaseSetupText.bluetoothMessage(unavailable))
            let before = provider.scanStarts

            provider.set(availability: .poweredOn)

            XCTAssertEqual(provider.scanStarts, before + 1, "Bluetooth came on: the search starts by itself (\(unavailable))")
            XCTAssertTrue(controller.isScanning)
            XCTAssertEqual(controller.availability, .poweredOn)
            XCTAssertEqual(provider.opens, [])
            XCTAssertEqual(hub.recorded, [])
        }
    }

    func testBluetoothGoingAwayAndComingBackWhileTheScreenIsShownLooksAgain() {
        let controller = makeEnrollment()
        controller.screenDidAppear()
        provider.set(availability: .poweredOff)
        XCTAssertEqual(controller.availability, .poweredOff)
        provider.set(availability: .poweredOn)
        XCTAssertEqual(provider.scanStarts, 2)
        XCTAssertTrue(controller.isScanning)
        // The same state told twice is not a change.
        provider.set(availability: .poweredOn)
        XCTAssertEqual(provider.scanStarts, 2)
        assertOnlyLooked(controller)
    }

    func testAScreenThatAppearsInTheBackgroundLooksOnlyOnceTheAppIsActive() {
        let controller = makeEnrollment()
        controller.sceneDidEnterBackground()
        controller.screenDidAppear()
        XCTAssertEqual(provider.activations, 0, "nothing new in the background: not even the permission question")
        XCTAssertEqual(provider.scanStarts, 0)
        XCTAssertFalse(controller.usesBluetooth)

        controller.sceneDidBecomeActive()
        XCTAssertEqual(provider.activations, 1)
        XCTAssertEqual(provider.scanStarts, 1)
        XCTAssertTrue(controller.isScanning)
        controller.sceneDidBecomeActive()
        XCTAssertEqual(provider.scanStarts, 1, "once")
        assertOnlyLooked(controller)
    }

    func testTheBackgroundPausesTheSearchAndTheForegroundGoesOnWithTheSameList() {
        let controller = makeEnrollment()
        controller.screenDidAppear()
        let found = controller.boards

        controller.sceneDidEnterBackground()
        XCTAssertFalse(controller.isScanning)
        XCTAssertEqual(provider.scanStops, 1)
        // Bluetooth news in the background starts nothing.
        provider.set(availability: .poweredOff)
        provider.set(availability: .poweredOn)
        XCTAssertEqual(provider.scanStarts, 1)
        XCTAssertEqual(provider.scanResumes, 0)

        controller.sceneDidBecomeActive()
        XCTAssertTrue(controller.isScanning)
        XCTAssertEqual(provider.scanStarts, 1, "not a new search: the boards seen so far are not forgotten")
        XCTAssertEqual(provider.scanResumes, 1)
        XCTAssertEqual(controller.boards, found, "what was picked in the list is still in it")
        XCTAssertEqual(provider.activations, 1)
        assertOnlyLooked(controller)
    }

    func testLeavingInTheBackgroundLeavesNothingToGoOnWith() async throws {
        let controller = makeEnrollment()
        controller.screenDidAppear()
        controller.sceneDidEnterBackground()
        controller.screenDidDisappear()
        try await Task.sleep(for: .milliseconds(120))
        controller.sceneDidBecomeActive()
        XCTAssertFalse(controller.isScanning, "the screen is gone: coming back to the app looks for nothing")
        XCTAssertEqual(provider.scanStarts, 1)
        XCTAssertEqual(provider.scanResumes, 0)
    }

    func testAHubThatCannotBeUsedIsNotLookedForAndOneThatCanIs() {
        let notPaired = PowerBaseHubTarget(hubID: EnrollmentFixtures.hubA, baseURL: EnrollmentFixtures.urlA, isSimulated: false, isPaired: false)
        let controller = makeEnrollment(target: notPaired)
        controller.screenDidAppear()
        XCTAssertEqual(provider.activations, 0, "the screen shows why the hub cannot be used, and uses no Bluetooth for a list it does not show")
        XCTAssertEqual(provider.scanStarts, 0)

        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        XCTAssertEqual(provider.activations, 1)
        XCTAssertEqual(provider.scanStarts, 1, "paired at last, the screen still shown: the search it owed starts")

        controller.targetDidChange(notPaired)
        XCTAssertFalse(controller.isScanning)
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        XCTAssertEqual(provider.scanStarts, 2)
        assertOnlyLooked(controller)
    }

    func testNothingIsLookedForOverARunOrItsResult() async throws {
        let controller = makeEnrollment()
        controller.screenDidAppear()
        XCTAssertEqual(provider.scanStarts, 1)
        func nudge(_ controller: Enrollment) {
            controller.screenDidAppear()
            controller.sceneDidEnterBackground()
            controller.sceneDidBecomeActive()
            provider.set(availability: .poweredOff)
            provider.set(availability: .poweredOn)
            controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        }

        // A run under way (the hub's answer to the POST is held back).
        hub.holdStarts()
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        controller.start(boardID: FakeBLEBoardProvider.boardID, expectedEUI64: EnrollmentFixtures.eui64, setupCode: EnrollmentFixtures.setupCode)
        try await eventually { self.hub.heldCount == 1 }
        XCTAssertTrue(controller.isBusy)
        XCTAssertFalse(controller.isScanning, "the run ended the search")
        nudge(controller)
        XCTAssertEqual(provider.scanStarts, 1, "authenticating, asking the hub, registering: not searched over")
        XCTAssertEqual(provider.scanResumes, 0)
        XCTAssertTrue(controller.isBusy, "and the run is still the run")
        controller.leave()
        hub.releaseHeld()

        // A result on show (here: a setup code that cannot be one) until the user has read it.
        let second = makeEnrollment()
        second.screenDidAppear()
        let searches = provider.scanStarts
        second.start(boardID: FakeBLEBoardProvider.boardID, expectedEUI64: EnrollmentFixtures.eui64, setupCode: "NOT-A-CODE")
        XCTAssertEqual(second.phase, .failed(.invalidSetupCode))
        second.stopScanning()
        nudge(second)
        XCTAssertEqual(provider.scanStarts, searches, "a result on show is not searched over")
        XCTAssertEqual(second.phase, .failed(.invalidSetupCode))
        XCTAssertFalse(second.isScanning)
    }

    func testAnUncertainHubRequestIsNotSearchedOver() async throws {
        let controller = makeEnrollment()
        controller.screenDidAppear()
        hub.scriptStart(.failure(.unreachable("timeout")))
        controller.start(boardID: FakeBLEBoardProvider.boardID, expectedEUI64: EnrollmentFixtures.eui64, setupCode: EnrollmentFixtures.setupCode)
        try await eventually { controller.phase == .hubUncertain }
        controller.sceneDidEnterBackground()
        controller.sceneDidBecomeActive()
        provider.set(availability: .poweredOff)
        provider.set(availability: .poweredOn)
        controller.screenDidAppear()
        XCTAssertEqual(controller.phase, .hubUncertain, "\"결과 확인 불가\" stays what the screen shows")
        XCTAssertEqual(provider.scanStarts, 1)
        XCTAssertFalse(controller.isScanning)
        controller.leave()
    }

    // MARK: - "다른 허브에 연결하기": PowerBaseLocalResetController

    private func makeReset(automatic: Bool = true, board: FakeResetBoard = FakeResetBoard()) -> (Reset, FakeResetProvider, FakeResetBoard) {
        let resetProvider = FakeResetProvider(board: board)
        let controller = Reset(
            provider: resetProvider, automaticSearch: automatic, leaveGrace: .milliseconds(40), quietScanPeriod: .milliseconds(30),
            pollInterval: .milliseconds(5), maximumPolls: 20
        )
        return (controller, resetProvider, board)
    }

    func testEnteringReenrollmentLooksOnceAndSendsNothingToAnyBoard() async throws {
        let (controller, resetProvider, board) = makeReset()
        XCTAssertEqual(resetProvider.activations, 0)
        controller.screenDidAppear()
        controller.screenDidAppear()
        XCTAssertEqual(resetProvider.activations, 1)
        XCTAssertEqual(resetProvider.scanStarts, 1)
        XCTAssertTrue(controller.isScanning)
        XCTAssertTrue(controller.usesBluetooth)

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(resetProvider.opens, [], "looking connects to nothing")
        XCTAssertEqual(board.log, [], "the board hears nothing: no window is opened for it, nothing is reset")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.hasUnresolvedOperation)
        XCTAssertFalse(controller.canConfirm)
    }

    func testWithoutTheOptionReenrollmentWaitsForItsButton() {
        let (controller, resetProvider, _) = makeReset(automatic: false)
        controller.screenDidAppear()
        XCTAssertEqual(resetProvider.activations, 0)
        XCTAssertEqual(resetProvider.scanStarts, 0)
    }

    func testReenrollmentKeepsItsSearchWhenTheScreenComesRightBackAndEndsItWhenItIsLeft() async throws {
        let (controller, resetProvider, _) = makeReset()
        controller.screenDidAppear()
        controller.screenDidDisappear()
        controller.screenDidAppear()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(resetProvider.scanStarts, 1)
        XCTAssertEqual(resetProvider.scanStops, 0)
        XCTAssertTrue(controller.isScanning)

        controller.screenDidDisappear()
        try await eventually { !controller.isScanning }
        XCTAssertEqual(resetProvider.scanStops, 1)
        resetProvider.set(availability: .poweredOff)
        resetProvider.set(availability: .poweredOn)
        XCTAssertEqual(resetProvider.scanStarts, 1, "gone: Bluetooth news starts nothing")

        controller.screenDidAppear()
        XCTAssertEqual(resetProvider.scanStarts, 2)
        XCTAssertEqual(resetProvider.activations, 1)
    }

    func testReenrollmentWaitsForBluetoothAndForTheForeground() {
        let (controller, resetProvider, _) = makeReset()
        resetProvider.availability = .denied
        controller.sceneDidEnterBackground()
        controller.screenDidAppear()
        XCTAssertEqual(resetProvider.activations, 0, "nothing new in the background")

        controller.sceneDidBecomeActive()
        XCTAssertEqual(resetProvider.activations, 1)
        XCTAssertEqual(controller.availability, .denied, "the screen says that Bluetooth is not allowed")
        let before = resetProvider.scanStarts

        resetProvider.set(availability: .poweredOn)
        XCTAssertEqual(resetProvider.scanStarts, before + 1, "allowed: the search starts by itself")
        XCTAssertTrue(controller.isScanning)

        controller.sceneDidEnterBackground()
        XCTAssertFalse(controller.isScanning)
        controller.sceneDidBecomeActive()
        XCTAssertEqual(resetProvider.scanResumes, 1, "the same search goes on, with its list")
        XCTAssertEqual(resetProvider.scanStarts, before + 1)
        XCTAssertEqual(resetProvider.opens, [])
    }

    func testReenrollmentIsNotSearchedOverWhileItWaitsForTheConfirmationOrShowsAnUnresolvedCommand() async throws {
        let (controller, resetProvider, board) = makeReset()
        controller.screenDidAppear()
        XCTAssertEqual(resetProvider.scanStarts, 1)
        func nudge() {
            controller.screenDidAppear()
            controller.sceneDidEnterBackground()
            controller.sceneDidBecomeActive()
            resetProvider.set(availability: .poweredOff)
            resetProvider.set(availability: .poweredOn)
        }

        // Authenticated, the confirmation is on show: nothing was sent, and nothing is searched.
        controller.verify(boardID: FakeResetProvider.boardID, expectedEUI64: EnrollmentFixtures.eui64, setupCode: EnrollmentFixtures.setupCode)
        try await eventually { controller.phase == .awaitingConfirmation }
        nudge()
        XCTAssertEqual(resetProvider.scanStarts, 1, "the confirmation is not searched over")
        XCTAssertEqual(resetProvider.scanResumes, 0)
        XCTAssertFalse(board.log.contains { if case .reset = $0 { true } else { false } }, "and no reset went out")

        // The user says no: back at the start. That alone starts no search either.
        controller.declineConfirmation()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(resetProvider.scanStarts, 1, "the list as it was, with what was picked in it")

        // A failure on show.
        controller.verify(boardID: FakeResetProvider.boardID, expectedEUI64: EnrollmentFixtures.eui64, setupCode: "NOT-A-CODE")
        guard case .failed = controller.phase else { return XCTFail("expected a failure, got \(controller.phase)") }
        nudge()
        XCTAssertEqual(resetProvider.scanStarts, 1, "a failure on show is not searched over")
        XCTAssertFalse(controller.isScanning)
    }

    // MARK: - The two screens as the app builds them

    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows {
            window.isHidden = true
            window.rootViewController = nil
        }
        windows = []
    }

    @discardableResult
    private func host(_ view: some View) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: CGSize(width: 375, height: 812))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        windows.append(window)
        return window
    }

    private func pairedModel() -> AppModel {
        AppModel(dataSource: MockSensorDataSource())
    }

    func testTheSetupScreenLooksWhenItIsEnteredAndStopsWhenItIsLeft() async throws {
        let controller = makeEnrollment()
        let phase = SearchScenePhase(.active)
        let shown = SearchShown(true)
        try host(SearchHost(phase: phase, shown: shown) {
            PowerBaseSetupView(makeController: { controller }, makeQRIntake: { PowerBaseSetupQRIntake(camera: nil) })
        }.environment(pairedModel()))

        // The screen hands the controller the app's own source: a mock source cannot be used, so
        // the screen shows that and looks for nothing. A hub that can be used starts the search.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(controller.ineligibility, "the test's AppModel reads simulated data")
        XCTAssertEqual(provider.activations, 0, "a screen that cannot register uses no Bluetooth")

        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        try await eventually { self.provider.scanStarts == 1 }
        XCTAssertEqual(provider.activations, 1)
        XCTAssertTrue(controller.isScanning)

        // The app goes away and comes back: the same search.
        phase.value = .background
        try await eventually { !controller.isScanning }
        phase.value = .active
        try await eventually { controller.isScanning }
        XCTAssertEqual(provider.scanStarts, 1)
        XCTAssertEqual(provider.scanResumes, 1)

        // The screen is left.
        shown.value = false
        try await eventually { !controller.isScanning }
        XCTAssertEqual(provider.opens, [])
        XCTAssertEqual(hub.recorded, [])
    }

    func testTheReenrollScreenLooksWhenItIsEnteredKeepsItsFormAndStopsWhenItIsLeft() async throws {
        let (controller, resetProvider, board) = makeReset()
        let phase = SearchScenePhase(.active)
        let shown = SearchShown(true)
        // The screen tells its QR intake which board the form has selected (and only while the
        // setup code field is shown): that is how this test sees the form the screen keeps.
        let intake = PowerBaseSetupQRIntake(camera: nil)
        let window = try host(SearchHost(phase: phase, shown: shown) {
            PowerBaseReenrollView(
                makeController: { controller }, makeQRIntake: { intake },
                initialForm: PowerBaseReenrollForm(selectedBoardID: FakeResetProvider.boardID, setupCode: EnrollmentFixtures.setupCode)
            )
        }.environment(pairedModel()))

        try await eventually { resetProvider.scanStarts == 1 }
        XCTAssertEqual(resetProvider.activations, 1, "entering the screen is what starts Bluetooth")
        XCTAssertTrue(controller.isScanning)
        try await eventually { intake.currentTarget?.boardID == FakeResetProvider.boardID }

        // Covered by another screen for a moment (a camera, a picker) and back: UIKit tells the
        // screen that it went and came.
        let host = try XCTUnwrap(window.rootViewController)
        host.beginAppearanceTransition(false, animated: false)
        host.endAppearanceTransition()
        host.beginAppearanceTransition(true, animated: false)
        host.endAppearanceTransition()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(resetProvider.scanStarts, 1, "coming back starts no second search")
        XCTAssertEqual(resetProvider.activations, 1)
        XCTAssertTrue(controller.isScanning)
        XCTAssertEqual(intake.currentTarget?.boardID, FakeResetProvider.boardID, "the board that was picked is still picked, its code field still shown")

        // In the background nothing goes on; back, the same search does, with the same list.
        phase.value = .background
        try await eventually { !controller.isScanning }
        phase.value = .active
        try await eventually { controller.isScanning }
        XCTAssertEqual(resetProvider.scanStarts, 1)
        XCTAssertEqual(resetProvider.scanResumes, 1)
        XCTAssertEqual(intake.currentTarget?.boardID, FakeResetProvider.boardID)

        shown.value = false
        try await eventually { !controller.isScanning }
        XCTAssertEqual(resetProvider.opens, [], "the whole time: no connection")
        XCTAssertEqual(board.log, [], "and nothing sent to the board")
    }

    func testAScreenShownWhileTheAppIsInTheBackgroundWaitsForTheForeground() async throws {
        let (controller, resetProvider, _) = makeReset()
        let phase = SearchScenePhase(.background)
        try host(SearchHost(phase: phase, shown: SearchShown(true)) {
            PowerBaseReenrollView(makeController: { controller }, makeQRIntake: { PowerBaseSetupQRIntake(camera: nil) })
        }.environment(pairedModel()))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(resetProvider.activations, 0)
        XCTAssertEqual(resetProvider.scanStarts, 0)

        phase.value = .active
        try await eventually { resetProvider.scanStarts == 1 }
        XCTAssertEqual(resetProvider.activations, 1)
    }

    // MARK: - The wording says what happens

    func testNoWordingSaysThatTheSearchWaitsForAButton() throws {
        for text in [PowerBaseSetupText.startFindingHint, PowerBaseSetupText.findFooter, PowerBaseReenrollText.startFindingHint, PowerBaseReenrollText.findFooter,
                     PowerBaseSetupText.stillFinding, PowerBaseSetupText.findingPaused] {
            XCTAssertFalse(text.isEmpty)
        }
        let gone = ["버튼을 누르면 Bluetooth로 주변의 등록되지 않은 Power Base를 찾습니다.",
                    "BOOT 버튼을 5초 누른 뒤 이 버튼을 누르면 Bluetooth로 재등록을 기다리는 Power Base를 찾습니다."]
        let added = ["이 화면을 열면 Bluetooth로 주변의 등록되지 않은 Power Base를 자동으로 찾습니다. 찾기가 시작되지 않았다면 위 버튼을 누르세요.",
                     "이 화면이 열려 있는 동안 Bluetooth로 주변의 등록되지 않은 Power Base를 자동으로 찾습니다. 찾는 것만으로는 Power Base에 연결하거나 등록하지 않습니다.",
                     "이 화면을 열면 Bluetooth로 재등록을 기다리는 Power Base를 자동으로 찾습니다. 찾기가 시작되지 않았다면 위 버튼을 누르세요. BOOT 버튼을 5초 누른 Power Base만 나타납니다.",
                     "이 화면이 열려 있는 동안 Bluetooth로 자동으로 찾습니다. 찾는 것만으로는 Power Base의 재등록 창이 열리지 않고 아무것도 지워지지 않습니다. 위 순서대로 BOOT 버튼을 5초 누른 Power Base만 여기에 나타납니다.",
                     "계속 찾고 있습니다. Power Base가 나타나면 여기에 표시됩니다.", "지금은 찾고 있지 않습니다. 아래 '다시 찾기'를 누르세요."]
        // What the code asks for is what the catalog holds, in the two translated languages.
        for language in ["en", "es"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), language)
            let bundle = try XCTUnwrap(Bundle(path: path))
            for old in gone {
                XCTAssertEqual(bundle.localizedString(forKey: old, value: "<gone>", table: nil), "<gone>", "\(language) still carries the sentence about the button: \(old)")
            }
            for key in added {
                let value = bundle.localizedString(forKey: key, value: "<missing>", table: nil)
                XCTAssertNotEqual(value, "<missing>", "\(language) has no translation of: \(key)")
                XCTAssertNotEqual(value, key, "\(language) shows the Korean text for: \(key)")
            }
        }
    }

}

@MainActor
@Observable
private final class SearchScenePhase {
    var value: ScenePhase
    init(_ value: ScenePhase) { self.value = value }
}

@MainActor
@Observable
private final class SearchShown {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}

/// The screen inside a navigation stack, with the scene phase the test sets and a way to leave it.
private struct SearchHost<Screen: View>: View {
    let phase: SearchScenePhase
    let shown: SearchShown
    @ViewBuilder let screen: () -> Screen

    var body: some View {
        NavigationStack {
            if shown.value { screen() } else { Text(verbatim: "left") }
        }
        .environment(\.scenePhase, phase.value)
    }
}
#endif
