import XCTest
@testable import PogoHome

/// `ScriptedPowerGateway` as the Watch's HomeKit connection, with the device list it would offer.
@MainActor
final class ScriptedWatchPowerGateway: WatchPowerGateway {
    let homeKit: ScriptedPowerGateway
    var hasHome = true

    init(_ homeKit: ScriptedPowerGateway) {
        self.homeKit = homeKit
    }

    func powerTargets() -> [AppleHomePowerTarget] {
        homeKit.accessories.compactMap { accessory in
            guard case let .eligible(characteristicID, kind) = AppleHomePowerEligibility.evaluate(accessory) else { return nil }
            return AppleHomePowerTarget(
                id: AppleHomePowerTargetID(homeID: accessory.homeID, accessoryID: accessory.id, characteristicID: characteristicID),
                name: accessory.name,
                roomName: accessory.roomName,
                homeName: "우리 집",
                kind: kind
            )
        }
    }

    func prepare() async throws { try await homeKit.prepare() }
    func accessory(id: UUID, inHome homeID: UUID) -> AppleHomeAccessory? { homeKit.accessory(id: id, inHome: homeID) }
    func readPower(characteristicID: UUID, accessoryID: UUID) async throws -> Bool { try await homeKit.readPower(characteristicID: characteristicID, accessoryID: accessoryID) }
    func writePower(_ isOn: Bool, characteristicID: UUID, accessoryID: UUID) async throws { try await homeKit.writePower(isOn, characteristicID: characteristicID, accessoryID: accessoryID) }
}

/// Apple Home on the Watch: only a read-back of the requested state is shown as success, and a
/// missing permission, a device that doesn't answer and a state that couldn't be confirmed are
/// told apart.
@MainActor
final class WatchPowerControllerTests: XCTestCase {
    private typealias F = AppleHomeFixtures
    private typealias P = PowerControlFixtures

    private var defaults: UserDefaults!
    private var suiteName = ""
    private let clock = Clock(AppleHomeFixtures.readAt)

    override func setUp() async throws {
        suiteName = "WatchPowerControllerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func controller(_ gateway: ScriptedWatchPowerGateway, enabled: Bool = true) -> WatchPowerController {
        defaults.set(enabled, forKey: WatchPowerController.enabledKey)
        let clock = clock
        return WatchPowerController(gateway: gateway, defaults: defaults, now: { clock.now }) { performer in
            performer.sleep = { _ in }
        }
    }

    private func homeKit(_ accessories: [AppleHomeAccessory] = [AppleHomeFixtures.light(), PowerControlFixtures.outlet()], isOn: Bool? = false) -> ScriptedWatchPowerGateway {
        ScriptedWatchPowerGateway(ScriptedPowerGateway(accessories: accessories, deviceIsOn: isOn))
    }

    private func row(_ controller: WatchPowerController, _ id: AppleHomePowerTargetID = PowerControlFixtures.lightTarget) -> WatchPowerRow? {
        controller.rows.first { $0.id == id }
    }

    // MARK: - Opening the page

    func testStaysOffUntilTurnedOnSoHomeKitIsntTouched() async {
        let gateway = homeKit()
        let power = controller(gateway, enabled: false)
        await power.load()
        XCTAssertEqual(power.access, .off)
        XCTAssertEqual(gateway.homeKit.prepareCount, 0, "no permission prompt before the wearer asks")

        await power.enable()
        XCTAssertEqual(power.access, .ready)
        XCTAssertTrue(defaults.bool(forKey: WatchPowerController.enabledKey))
    }

    func testListsOnlyUnambiguousOnOffDevicesAndReadsTheirState() async {
        let gateway = homeKit([F.light(), P.outlet(), P.powerStrip(), P.fan(), F.readOnlyLight()], isOn: true)
        let power = controller(gateway)
        clock.now = F.readAt.addingTimeInterval(10)

        await power.load()

        XCTAssertEqual(Set(power.rows.map(\.id)), [P.lightTarget, P.outletTarget], "no power strip, fan or read-only light")
        XCTAssertEqual(row(power)?.state, .known(isOn: true, checkedAt: clock.now))
        XCTAssertNil(row(power)?.visibleResult(now: clock.now), "an automatic read that worked says nothing")
        XCTAssertTrue(gateway.homeKit.writes.isEmpty, "opening the page never switches anything")
    }

    func testAccessProblemsAreNamedAndShowNoDevices() async {
        let cases: [(Error, WatchPowerController.Access)] = [
            (AppleHomePowerFailure.notAuthorized, .denied),
            (AppleHomePowerFailure.restricted, .restricted),
            (AppleHomePowerFailure.homeKitUnavailable, .unavailable),
        ]
        for (error, access) in cases {
            let gateway = homeKit()
            gateway.homeKit.prepareError = error
            let power = controller(gateway)
            await power.load()
            XCTAssertEqual(power.access, access)
            XCTAssertTrue(power.rows.isEmpty)
        }
        let noHome = homeKit()
        noHome.hasHome = false
        let power = controller(noHome)
        await power.load()
        XCTAssertEqual(power.access, .noHome)
    }

    // MARK: - Switching

    func testSwitchingIsShownAsDoneOnlyAfterTheDeviceReportsIt() async {
        let gateway = homeKit(isOn: false)
        let power = controller(gateway)
        await power.load()
        clock.now = F.readAt.addingTimeInterval(20)

        await power.tap(P.lightTarget)

        XCTAssertEqual(gateway.homeKit.writes.map(\.isOn), [true])
        XCTAssertEqual(row(power)?.state, .known(isOn: true, checkedAt: clock.now))
        XCTAssertEqual(row(power)?.lastResult, .confirmed)
        XCTAssertEqual(row(power)?.visibleResult(now: clock.now), .confirmed)
        XCTAssertNil(row(power)?.visibleResult(now: clock.now.addingTimeInterval(120)), "the confirmation note fades; the state stays")
    }

    func testADeviceThatDoesntSwitchIsUnconfirmedWithTheStateItReported() async {
        let gateway = homeKit(isOn: false)
        gateway.homeKit.writeTakesEffect = false
        let power = controller(gateway)
        await power.load()

        await power.tap(P.lightTarget)

        XCTAssertEqual(row(power)?.lastResult, .unconfirmed(.mismatch))
        XCTAssertEqual(row(power)?.state, .known(isOn: false, checkedAt: clock.now), "what the device said, not what was asked")
    }

    func testAReadBackThatFailsLeavesTheStateUnknownNotTheRequestedOne() async {
        let gateway = homeKit(isOn: false)
        let power = controller(gateway)
        await power.load()
        // The read before writing works, the write goes through, then every read-back fails.
        gateway.homeKit.queuedReads = [.success(false)]
        gateway.homeKit.writeTakesEffect = false
        gateway.homeKit.deviceIsOn = nil
        gateway.homeKit.readFailure = AppleHomePowerFailure.readFailed

        await power.tap(P.lightTarget)

        XCTAssertEqual(gateway.homeKit.writes.map(\.isOn), [true], "a command was sent")

        XCTAssertEqual(row(power)?.lastResult, .unconfirmed(.unconfirmed))
        XCTAssertEqual(row(power)?.state, .unknown)
    }

    func testADeviceThatDoesntRespondIsNoResponse() async {
        let gateway = homeKit(isOn: false)
        let power = controller(gateway)
        await power.load()
        gateway.homeKit.accessories = [F.light(reachable: false), P.outlet()]

        await power.tap(P.lightTarget)

        XCTAssertEqual(row(power)?.lastResult, .noResponse(.notReachable))
        XCTAssertEqual(row(power)?.state, .unknown)
        XCTAssertTrue(gateway.homeKit.writes.isEmpty)
    }

    func testARevokedPermissionClearsTheDevices() async {
        let gateway = homeKit(isOn: false)
        let power = controller(gateway)
        await power.load()
        gateway.homeKit.prepareError = AppleHomePowerFailure.notAuthorized

        await power.tap(P.lightTarget)

        XCTAssertEqual(power.access, .denied)
        XCTAssertTrue(power.rows.isEmpty, "nothing about the devices stays on screen")
        XCTAssertTrue(gateway.homeKit.writes.isEmpty)
    }

    func testAnUnknownStateIsOnlyReadNeverSwitched() async {
        let gateway = homeKit(isOn: nil)
        let power = controller(gateway)
        await power.load()
        XCTAssertEqual(row(power)?.state, .unknown)
        XCTAssertEqual(row(power)?.tapAction, .check)
        XCTAssertEqual(row(power)?.lastResult, .unconfirmed(.readFailed), "a failed automatic read is shown")

        gateway.homeKit.deviceIsOn = true
        await power.tap(P.lightTarget)

        XCTAssertTrue(gateway.homeKit.writes.isEmpty)
        XCTAssertEqual(row(power)?.state, .known(isOn: true, checkedAt: clock.now))
        XCTAssertEqual(row(power)?.lastResult, .checked)
    }

    func testAnOldStateIsShownAsTheLastOneSeen() {
        let row = WatchPowerRow(target: P.lightEntry, state: .known(isOn: true, checkedAt: F.readAt))
        XCTAssertEqual(row.stateDisplay(now: F.readAt.addingTimeInterval(60)), .on(checkedAt: F.readAt))
        XCTAssertEqual(row.stateDisplay(now: F.readAt.addingTimeInterval(HomeGlanceFreshness.staleAfter + 1)), .lastSeen(isOn: true, checkedAt: F.readAt))
        XCTAssertEqual(row.tapAction, .switchTo(on: false))
        var busy = row
        busy.activity = .switching(toOn: false)
        XCTAssertEqual(busy.tapAction, .none, "a second tap while one runs does nothing")
    }

    func testEveryFailureFallsIntoExactlyOneGroup() {
        for failure in AppleHomePowerFailure.allCases {
            let result = WatchPowerResult.from(.failed(failure, observedIsOn: nil))
            XCTAssertEqual(result.failure, failure)
            switch failure {
            case .notAuthorized, .restricted, .appleHomeOff:
                XCTAssertEqual(result, .noPermission(failure))
            case .notReachable, .timedOut, .homeKitUnavailable:
                XCTAssertEqual(result, .noResponse(failure))
            case .unconfirmed, .mismatch, .writeFailed, .readFailed:
                XCTAssertEqual(result, .unconfirmed(failure))
            default:
                XCTAssertEqual(result, .unavailable(failure))
            }
        }
        XCTAssertEqual(WatchPowerResult.from(.confirmed(isOn: true, didWrite: true)), .confirmed)
        XCTAssertEqual(WatchPowerResult.from(.checked(isOn: false)), .checked)
    }
}
