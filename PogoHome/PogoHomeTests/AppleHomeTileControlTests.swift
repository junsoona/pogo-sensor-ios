import XCTest
@testable import PogoHome

/// The on/off button on an Apple Home tile: it switches only a single, readable-and-writable
/// on/off control whose state has been read back; goes through `AppleHomeModel.perform(_:)`
/// (so success means "read back"); never flips the shown state early; refuses repeated taps
/// while busy; and is kept apart from the tile body, which always opens the detail screen.
@MainActor
final class AppleHomeTileControlTests: XCTestCase {
    private typealias F = AppleHomeFixtures

    private static let stripID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
    private static let outletAID = UUID(uuidString: "40000000-0000-0000-0000-000000000011")!
    private static let outletBID = UUID(uuidString: "40000000-0000-0000-0000-000000000012")!

    /// Two outlets on one accessory: which one "the" power button means is ambiguous.
    private static func powerStrip() -> AppleHomeAccessory {
        AppleHomeAccessory(
            id: stripID,
            homeID: F.homeID,
            name: "멀티탭",
            roomID: F.livingRoomID,
            roomName: "거실",
            isReachable: true,
            services: [outletAID, outletBID].enumerated().map { index, id in
                AppleHomeService(id: UUID(), kind: .outlet, name: "콘센트 \(index + 1)", characteristics: [
                    AppleHomeCharacteristic(id: id, kind: .powerState, isWritable: true, value: .bool(false), confirmedAt: F.readAt),
                ])
            }
        )
    }

    private func makeModel(_ snapshot: AppleHomeSnapshot = F.ready([F.light(), F.readOnlyLight(), F.sensor(), F.lock(), AppleHomeTileControlTests.powerStrip()])) -> (AppleHomeModel, ScriptedAppleHomeProvider) {
        let provider = ScriptedAppleHomeProvider(snapshot: snapshot)
        let model = AppleHomeModel(provider: provider, defaults: makeIsolatedDefaults())
        model.enable()
        return (model, provider)
    }

    private func quick(_ model: AppleHomeModel, _ id: UUID = F.lightID) -> AppleHomeQuickControl? {
        model.snapshot.accessory(with: id).map(model.quickControl(for:))
    }

    private func isOn(_ model: AppleHomeModel) -> Bool? {
        if case let .toggle(_, isOn)? = quick(model) { return isOn }
        return nil
    }

    // MARK: - Switching

    func testTurningOnIsConfirmedByTheReadBack() async {
        let (model, provider) = makeModel()
        provider.snapshotAfterWrite = { _ in F.ready([F.light(power: .bool(true))]) }
        XCTAssertEqual(isOn(model), false)

        let outcome = await model.performQuickAction(for: F.lightID)

        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(provider.writes.map(\.characteristicID), [F.lightPowerID], "only the on/off characteristic, never brightness")
        XCTAssertEqual(provider.writes.map(\.value), [.bool(true)])
        XCTAssertEqual(provider.refreshCount, 1)
        XCTAssertEqual(isOn(model), true)
        XCTAssertNil(model.controlMessages[F.lightPowerID])
    }

    func testTurningOffIsConfirmedByTheReadBack() async {
        let (model, provider) = makeModel(F.ready([F.light(power: .bool(true))]))
        provider.snapshotAfterWrite = { _ in F.ready([F.light(power: .bool(false))]) }

        let outcome = await model.performQuickAction(for: F.lightID)

        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(provider.writes.map(\.value), [.bool(false)])
        XCTAssertEqual(isOn(model), false)
    }

    func testAnUnreadStateIsReadInsteadOfGuessed() async {
        let (model, provider) = makeModel(F.ready([F.light(power: nil)]))
        guard case .needsStateCheck? = quick(model) else { return XCTFail("\(String(describing: quick(model)))") }

        let outcome = await model.performQuickAction(for: F.lightID)

        XCTAssertNil(outcome, "nothing is sent")
        XCTAssertTrue(provider.writes.isEmpty)
        XCTAssertEqual(provider.refreshCount, 1, "the tap reads the state")
    }

    func testSeveralOnOffControlsAreLeftToTheDetailScreen() async {
        let (model, provider) = makeModel()
        XCTAssertEqual(quick(model, Self.stripID), .multipleControls(count: 2))
        let strip = model.snapshot.accessory(with: Self.stripID)!
        XCTAssertEqual(AppleHomeTileAction.iconAction(for: strip, quickControl: model.quickControl(for: strip)), .openDetail(.accessory(Self.stripID)))

        let outcome = await model.performQuickAction(for: Self.stripID)

        XCTAssertNil(outcome)
        XCTAssertTrue(provider.writes.isEmpty)
        XCTAssertEqual(provider.refreshCount, 0)
    }

    func testRepeatedTapsWhileBusySendOneCommand() async {
        let (model, provider) = makeModel()
        provider.holdsWrites = true
        provider.snapshotAfterWrite = { _ in F.ready([F.light(power: .bool(true))]) }

        let first = Task { await model.performQuickAction(for: F.lightID) }
        let holding = await waitUntil { provider.isHoldingWrite }
        XCTAssertTrue(holding)
        let light = model.snapshot.accessory(with: F.lightID)!
        XCTAssertTrue(model.isQuickControlBusy(light))
        XCTAssertEqual(isOn(model), false, "the state is not flipped before the device confirms it")
        XCTAssertEqual(
            AppleHomeTileText.state(of: light, quick: model.quickControl(for: light), pending: model.pendingValues[F.lightPowerID], isReading: false),
            AppleHomeControlText.pending(.bool(true), kind: .power),
            "shown as 'turning on…', not as on"
        )

        let second = await model.performQuickAction(for: F.lightID)
        let third = await model.performQuickAction(for: F.lightID)
        XCTAssertNil(second)
        XCTAssertNil(third)
        XCTAssertEqual(provider.writes.count, 1)

        provider.releaseWrite()
        let outcome = await first.value
        XCTAssertEqual(outcome, .confirmed)
        XCTAssertFalse(model.isQuickControlBusy(model.snapshot.accessory(with: F.lightID)!))
        XCTAssertEqual(isOn(model), true)
    }

    func testAFailedWriteKeepsTheReadStateAndShowsTheErrorOnTheTile() async {
        let (model, provider) = makeModel()
        provider.writeError = AppleHomeProviderError.timedOut

        let outcome = await model.performQuickAction(for: F.lightID)

        guard case .failed? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(isOn(model), false)
        let light = model.snapshot.accessory(with: F.lightID)!
        XCTAssertNotNil(AppleHomeTileText.problem(of: light, quick: model.quickControl(for: light), messages: model.controlMessages))
    }

    func testAFailedReadBackIsNotSuccessAndTheOldStateIsNoLongerShownAsCurrent() async {
        let (model, provider) = makeModel()
        provider.snapshotAfterWrite = { _ in F.ready([F.light(power: .bool(true))]) }
        provider.refreshError = AppleHomeProviderError.timedOut

        let outcome = await model.performQuickAction(for: F.lightID)

        guard case .unconfirmed? = outcome else { return XCTFail("\(String(describing: outcome))") }
        let light = model.snapshot.accessory(with: F.lightID)!
        XCTAssertEqual(model.quickControl(for: light), .needsStateCheck(AppleHomeCapabilities.controls(of: light)[0]), "neither the old 'off' nor the requested 'on'")
        XCTAssertNotNil(AppleHomeTileText.problem(of: light, quick: model.quickControl(for: light), messages: model.controlMessages))
        let control = AppleHomeCapabilities.controls(of: light)[0]
        XCTAssertNil(model.confirmedValue(of: control, accessoryID: F.lightID), "the detail screen's row shares this")

        // A later read (or notification) brings a current value back.
        provider.refreshError = nil
        provider.publish(F.ready([F.light(power: .bool(true), powerConfirmedAt: F.readAt.addingTimeInterval(30))]))
        XCTAssertEqual(isOn(model), true)
    }

    func testADeviceThatReportsTheOldStateIsNotSuccess() async {
        let (model, provider) = makeModel()
        provider.snapshotAfterWrite = { _ in F.ready([F.light(power: .bool(false), powerConfirmedAt: F.readAt.addingTimeInterval(5))]) }

        let outcome = await model.performQuickAction(for: F.lightID)

        guard case .unconfirmed? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(isOn(model), false, "the state the device reported back")
        XCTAssertNotNil(model.controlMessages[F.lightPowerID])
    }

    // MARK: - Disabled

    func testUnreachableOrBlockedDevicesAreNotControlled() async {
        for light in [F.light(reachable: false), F.light(blocked: true)] {
            let (model, provider) = makeModel(F.ready([light]))
            guard case .unavailable? = quick(model) else { return XCTFail("\(String(describing: quick(model)))") }
            XCTAssertEqual(AppleHomeTileAction.iconAction(for: light, quickControl: model.quickControl(for: light)), AppleHomeTileAction.none)
            let outcome = await model.performQuickAction(for: F.lightID)
            XCTAssertNil(outcome)
            XCTAssertTrue(provider.writes.isEmpty)
            XCTAssertEqual(provider.refreshCount, 0)
        }
    }

    func testWithoutAccessNothingIsControlled() async {
        let (model, provider) = makeModel()
        let stale = model.snapshot.accessory(with: F.lightID)!
        provider.publish(AppleHomeSnapshot(accessState: .denied))

        XCTAssertNil(model.snapshot.accessory(with: F.lightID))
        let outcome = await model.performQuickAction(for: F.lightID)
        XCTAssertNil(outcome)
        XCTAssertTrue(provider.writes.isEmpty)
        guard case .unavailable = model.quickControl(for: stale) else { return XCTFail("a tile still on screen must not offer control") }
    }

    func testReadOnlyDevicesOfferNoSwitch() async {
        let (model, provider) = makeModel()
        for id in [F.readOnlyLightID, F.sensorID, F.lockID] {
            XCTAssertEqual(quick(model, id), .readOnly, "\(id)")
            let outcome = await model.performQuickAction(for: id)
            XCTAssertNil(outcome)
        }
        XCTAssertTrue(provider.writes.isEmpty)
    }

    func testPOGOSensorsStayReadOnly() {
        let listing = DeviceDirectory.listing(pogo: MockSensorFixtures.previewSnapshot, isPogoStateVerified: true, appleHome: .off, links: [:])
        XCTAssertTrue(listing.visible.allSatisfy { $0.controls.isEmpty })
    }

    // MARK: - Two tap targets

    func testTheIconAndTheTileBodyAreSeparateActions() {
        let (model, _) = makeModel()
        for accessory in model.snapshot.accessories {
            let quick = model.quickControl(for: accessory)
            XCTAssertEqual(AppleHomeTileAction.bodyAction(for: accessory), .openDetail(.accessory(accessory.id)), "the body always opens the detail")
            let icon = AppleHomeTileAction.iconAction(for: accessory, quickControl: quick)
            if case .toggle = quick {
                XCTAssertNotEqual(icon, AppleHomeTileAction.bodyAction(for: accessory))
            }
            if case .send = icon {
                guard case .toggle = quick else { return XCTFail("only an unambiguous, read state sends a command") }
            }
        }
        let light = model.snapshot.accessory(with: F.lightID)!
        XCTAssertEqual(
            AppleHomeTileAction.iconAction(for: light, quickControl: model.quickControl(for: light)),
            .send(DeviceCommand(device: .appleHomeAccessory(F.lightID), controlID: F.lightPowerID, kind: .power, value: .bool(true)))
        )
    }
}
