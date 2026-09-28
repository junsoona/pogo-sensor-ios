import XCTest
@testable import PogoHome

/// Apple Home access and control: nothing starts before the user opts in, denied/no-home
/// states show no accessories, and a control is reported as applied only after the device
/// reads back the requested value — failures, timeouts, disconnections and permission
/// revocation all leave the last confirmed value on screen with a message.
@MainActor
final class AppleHomeModelTests: XCTestCase {
    private typealias F = AppleHomeFixtures

    private func makeModel(
        _ snapshot: AppleHomeSnapshot = F.ready([F.light(), F.readOnlyLight(), F.sensor(), F.lock()]),
        defaults: UserDefaults? = nil
    ) -> (AppleHomeModel, ScriptedAppleHomeProvider) {
        let provider = ScriptedAppleHomeProvider(snapshot: snapshot)
        let model = AppleHomeModel(provider: provider, defaults: defaults ?? makeIsolatedDefaults())
        return (model, provider)
    }

    private func powerCommand(_ on: Bool, controlID: UUID = F.lightPowerID, accessoryID: UUID = F.lightID) -> DeviceCommand {
        DeviceCommand(device: .appleHomeAccessory(accessoryID), controlID: controlID, kind: .power, value: .bool(on))
    }

    private func confirmedPower(_ model: AppleHomeModel) -> DeviceControlValue? {
        model.snapshot.accessory(with: F.lightID)
            .flatMap { AppleHomeCapabilities.controls(of: $0).first { $0.id == F.lightPowerID } }?
            .confirmedValue
    }

    // MARK: - Access

    func testStaysOffAndNeverTouchesHomeKitUntilTheUserTurnsItOn() {
        let (model, provider) = makeModel()
        model.startIfEnabled()
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(provider.startCount, 0, "no HomeKit (and no permission prompt) before opting in")
        XCTAssertEqual(model.snapshot.accessState, .off)
        XCTAssertTrue(model.snapshot.accessories.isEmpty)
    }

    func testTurningOnStartsOnceAndIsRememberedAcrossLaunches() {
        let defaults = makeIsolatedDefaults()
        let (model, provider) = makeModel(defaults: defaults)
        model.enable()
        model.enable()
        XCTAssertEqual(provider.startCount, 1)
        XCTAssertEqual(model.snapshot.accessState, .ready)

        let (relaunched, relaunchedProvider) = makeModel(defaults: defaults)
        XCTAssertTrue(relaunched.isEnabled)
        relaunched.startIfEnabled()
        XCTAssertEqual(relaunchedProvider.startCount, 1)
    }

    func testDeniedRestrictedAndNoHomeNeverCarryAccessories() {
        for state in [AppleHomeAccessState.denied, .restricted, .noHome, .loading, .unsupported] {
            let (model, _) = makeModel(AppleHomeSnapshot(accessState: state, accessories: [F.light()]))
            model.enable()
            XCTAssertEqual(model.snapshot.accessState, state)
            XCTAssertTrue(model.snapshot.accessories.isEmpty, "\(state)")
        }
    }

    func testTurningOffStopsHomeKitAndIgnoresLateCallbacks() {
        let (model, provider) = makeModel()
        model.enable()
        model.disable()
        XCTAssertEqual(provider.stopCount, 1)
        XCTAssertEqual(model.snapshot, .off)
        provider.lastOnChange?(F.ready([F.light()]))
        XCTAssertEqual(model.snapshot, .off, "a HomeKit callback arriving after stop must not bring devices back")
    }

    func testUnsupportedPlatformReportsUnsupported() {
        let model = AppleHomeModel(provider: UnsupportedAppleHomeProvider(), defaults: makeIsolatedDefaults())
        model.enable()
        XCTAssertEqual(model.snapshot.accessState, .unsupported)
        XCTAssertFalse(model.isAccessorySetupAvailable)
    }

    // MARK: - Controls

    func testAWriteIsConfirmedOnlyAfterTheDeviceReportsTheNewValue() async {
        let (model, provider) = makeModel()
        provider.snapshotAfterWrite = { _ in F.ready([F.light(power: .bool(true))]) }
        model.enable()

        let outcome = await model.perform(powerCommand(true))

        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(provider.writes.map(\.value), [.bool(true)])
        XCTAssertEqual(provider.refreshCount, 1, "the value is read back after the write")
        XCTAssertEqual(confirmedPower(model), .bool(true))
        XCTAssertTrue(model.pendingValues.isEmpty)
        XCTAssertNil(model.controlMessages[F.lightPowerID])
    }

    func testWhileTheWriteIsRunningTheOldValueStaysConfirmedAndTheRequestIsPending() async {
        let (model, provider) = makeModel()
        provider.holdsWrites = true
        provider.snapshotAfterWrite = { _ in F.ready([F.light(power: .bool(true))]) }
        model.enable()

        let task = Task { await model.perform(powerCommand(true)) }
        let holding = await waitUntil { provider.isHoldingWrite }
        XCTAssertTrue(holding)
        XCTAssertEqual(model.pendingValues[F.lightPowerID], .bool(true))
        XCTAssertEqual(confirmedPower(model), .bool(false), "not shown as on before the device confirms")
        let second = await model.perform(powerCommand(false))
        XCTAssertFalse(second.isConfirmed, "a second request for the same control is refused while one is running")

        provider.releaseWrite()
        let outcome = await task.value
        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(confirmedPower(model), .bool(true))
        XCTAssertTrue(model.pendingValues.isEmpty)
    }

    func testFailedOrTimedOutWritesLeaveTheConfirmedValueAndShowAMessage() async {
        for error in [AppleHomeProviderError.notReachable, .timedOut, .underlying("HomeKit error")] {
            let (model, provider) = makeModel()
            provider.writeError = error
            provider.snapshotAfterWrite = { _ in F.ready([F.light(power: .bool(true))]) }
            model.enable()

            let outcome = await model.perform(powerCommand(true))

            guard case .failed = outcome else { return XCTFail("\(error): \(outcome)") }
            XCTAssertEqual(confirmedPower(model), .bool(false), "\(error)")
            XCTAssertNotNil(model.controlMessages[F.lightPowerID], "\(error)")
            XCTAssertTrue(model.pendingValues.isEmpty, "\(error)")
        }
    }

    func testAWriteTheDeviceDoesNotReportBackIsUnconfirmed() async {
        let (model, provider) = makeModel()
        provider.snapshotAfterWrite = nil
        model.enable()

        let outcome = await model.perform(powerCommand(true))

        guard case .unconfirmed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(confirmedPower(model), .bool(false))
        XCTAssertNotNil(model.controlMessages[F.lightPowerID])
    }

    func testAFailedReadBackIsUnconfirmed() async {
        let (model, provider) = makeModel()
        provider.snapshotAfterWrite = { _ in F.ready([F.light(power: .bool(true))]) }
        model.enable()
        provider.refreshError = AppleHomeProviderError.notReachable

        let outcome = await model.perform(powerCommand(true))

        guard case .unconfirmed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(confirmedPower(model), .bool(false), "the write's value isn't shown without a read-back")
    }

    func testUnreachableOrBlockedAccessoriesAreNotWrittenTo() async {
        for accessory in [F.light(reachable: false), F.light(blocked: true)] {
            let (model, provider) = makeModel(F.ready([accessory]))
            model.enable()

            let outcome = await model.perform(powerCommand(true))

            guard case .rejected = outcome else { return XCTFail("\(outcome)") }
            XCTAssertTrue(provider.writes.isEmpty)
            XCTAssertNotNil(model.controlMessages[F.lightPowerID])
        }
    }

    func testDisconnectionDuringTheWriteEndsAsAFailure() async {
        let (model, provider) = makeModel()
        provider.holdsWrites = true
        model.enable()

        let task = Task { await model.perform(powerCommand(true)) }
        _ = await waitUntil { provider.isHoldingWrite }
        provider.publish(F.ready([F.light(reachable: false)]))
        provider.writeError = AppleHomeProviderError.notReachable
        provider.releaseWrite()

        let outcome = await task.value
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(confirmedPower(model), .bool(false))
        let control = model.snapshot.accessory(with: F.lightID).flatMap { AppleHomeCapabilities.controls(of: $0).first }
        XCTAssertEqual(control?.isEnabled, false, "controls are disabled while the device doesn't respond")
    }

    func testPermissionRevokedDuringTheWriteEndsAsAFailureAndRemovesAccessories() async {
        let (model, provider) = makeModel()
        provider.holdsWrites = true
        model.enable()

        let task = Task { await model.perform(powerCommand(true)) }
        _ = await waitUntil { provider.isHoldingWrite }
        provider.publish(AppleHomeSnapshot(accessState: .denied))
        provider.writeError = AppleHomeProviderError.notAuthorized
        provider.releaseWrite()

        let outcome = await task.value
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(model.snapshot.accessState, .denied)
        XCTAssertTrue(model.snapshot.accessories.isEmpty)
        XCTAssertTrue(model.pendingValues.isEmpty)
    }

    func testReadOnlyAndUnsupportedCharacteristicsCannotBeControlled() async {
        let (model, provider) = makeModel()
        model.enable()

        let readOnly = await model.perform(powerCommand(false, controlID: F.readOnlyPowerID, accessoryID: F.readOnlyLightID))
        let lock = await model.perform(DeviceCommand(device: .appleHomeAccessory(F.lockID), controlID: F.lockStateID, kind: .power, value: .bool(false)))
        let sensor = await model.perform(DeviceCommand(device: .appleHomeAccessory(F.sensorID), controlID: F.temperatureID, kind: .brightness, value: .percent(10)))
        let wrongKind = await model.perform(DeviceCommand(device: .appleHomeAccessory(F.lightID), controlID: F.lightPowerID, kind: .brightness, value: .percent(10)))

        for outcome in [readOnly, lock, sensor, wrongKind] {
            guard case .rejected = outcome else { return XCTFail("\(outcome)") }
        }
        XCTAssertTrue(provider.writes.isEmpty)
    }

    func testBrightnessIsRangeCheckedAndAllowsOneStepOfDeviceRounding() async {
        let (model, provider) = makeModel()
        provider.snapshotAfterWrite = { _ in F.ready([F.light(brightness: .int(49))]) }
        model.enable()
        let brightness = { (percent: Int) in
            DeviceCommand(device: .appleHomeAccessory(F.lightID), controlID: F.lightBrightnessID, kind: .brightness, value: .percent(percent))
        }

        let outOfRange = await model.perform(brightness(140))
        guard case .rejected = outOfRange else { return XCTFail("\(outOfRange)") }
        XCTAssertTrue(provider.writes.isEmpty)

        let fifty = await model.perform(brightness(50))
        XCTAssertEqual(fifty, .confirmed)
        XCTAssertEqual(provider.writes.map(\.value), [.int(50)])
    }

    func testActiveIsWrittenAsHomeKitsUInt8() {
        XCTAssertEqual(AppleHomeCapabilities.rawValue(for: .bool(true), kind: .active), .int(1))
        XCTAssertEqual(AppleHomeCapabilities.rawValue(for: .bool(false), kind: .active), .int(0))
        XCTAssertEqual(AppleHomeCapabilities.rawValue(for: .bool(true), kind: .power), .bool(true))
        XCTAssertNil(AppleHomeCapabilities.rawValue(for: .percent(10), kind: .power))
    }

    func testPOGODevicesAreNeverSentCommands() async {
        let (model, provider) = makeModel()
        model.enable()
        let outcome = await model.perform(DeviceCommand(device: .pogoModule(F.lightID), controlID: F.lightPowerID, kind: .power, value: .bool(true)))
        guard case .rejected = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(provider.writes.isEmpty, "the same UUID under the POGO source is a different device")
    }

    // MARK: - Adding accessories

    func testSetupSuccessOnlyRepeatsWhatAppleHomeReportedAndCreatesNoDevice() async {
        let (model, provider) = makeModel(F.ready([F.light()]))
        let added = UUID()
        provider.setupResult = .success(AppleHomeSetupResult(homeID: F.homeID, accessoryIDs: [added]))
        model.enable()

        await model.startAccessorySetup()

        XCTAssertEqual(provider.setupCount, 1)
        XCTAssertEqual(model.setupState, .succeeded(AppleHomeSetupResult(homeID: F.homeID, accessoryIDs: [added])))
        XCTAssertNil(model.snapshot.accessory(with: added), "listed only once HomeKit itself reports it")
        XCTAssertEqual(model.snapshot.accessories.map(\.id), [F.lightID])

        provider.publish(F.ready([F.light(), F.sensor()]))
        XCTAssertEqual(model.snapshot.accessories.count, 2)
    }

    func testSetupCancelledOrFailedAddsNothing() async {
        let (model, provider) = makeModel(F.ready([F.light()]))
        model.enable()

        provider.setupResult = .failure(AppleHomeProviderError.cancelled)
        await model.startAccessorySetup()
        XCTAssertEqual(model.setupState, .cancelled)

        provider.setupResult = .failure(AppleHomeProviderError.underlying("설정 코드가 올바르지 않습니다"))
        await model.startAccessorySetup()
        XCTAssertEqual(model.setupState, .failed("설정 코드가 올바르지 않습니다"))
        XCTAssertEqual(model.snapshot.accessories.map(\.id), [F.lightID])

        model.clearSetupState()
        XCTAssertEqual(model.setupState, .idle)
    }

    func testSetupWorksWithoutHomeDataAccessAndReportsUnavailability() async {
        // HMAccessorySetupManager needs no home-data permission, so setup must not require
        // Apple Home to be turned on in PogoHome.
        let (model, provider) = makeModel()
        provider.setupResult = .success(AppleHomeSetupResult(homeID: F.homeID, accessoryIDs: [F.sensorID]))
        await model.startAccessorySetup()
        XCTAssertEqual(provider.startCount, 0)
        XCTAssertEqual(model.setupState, .succeeded(AppleHomeSetupResult(homeID: F.homeID, accessoryIDs: [F.sensorID])))

        let (unavailable, unavailableProvider) = makeModel()
        unavailableProvider.isAccessorySetupAvailable = false
        await unavailable.startAccessorySetup()
        guard case .failed = unavailable.setupState else { return XCTFail("\(unavailable.setupState)") }
        XCTAssertEqual(unavailableProvider.setupCount, 0)
    }

    // MARK: - Duplicate links

    func testDuplicateLinksPersistAndCanBeCleared() {
        let defaults = makeIsolatedDefaults()
        let (model, _) = makeModel(defaults: defaults)
        let module = UUID()
        model.link(accessoryID: F.sensorID, toPogoModule: module)

        let (relaunched, _) = makeModel(defaults: defaults)
        XCTAssertEqual(relaunched.linkedModuleID(forAccessory: F.sensorID), module)

        relaunched.link(accessoryID: F.sensorID, toPogoModule: nil)
        let (again, _) = makeModel(defaults: defaults)
        XCTAssertNil(again.linkedModuleID(forAccessory: F.sensorID))
    }
}
