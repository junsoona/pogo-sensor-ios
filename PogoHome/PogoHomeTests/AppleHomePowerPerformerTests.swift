import XCTest
@testable import PogoHome

/// A Control Center tap against HomeKit: resolved by id in a fresh HomeKit connection, the
/// device read before anything is written, and success only when a read-back reports the
/// requested state. Every other ending — no access, gone or changed target, no response,
/// failed write or read — is a failure that leaves no claimed state behind.
@MainActor
final class AppleHomePowerPerformerTests: XCTestCase {
    private typealias F = AppleHomeFixtures
    private typealias P = PowerControlFixtures

    private func gateway(_ accessories: [AppleHomeAccessory] = [F.light()], isOn: Bool? = false) -> ScriptedPowerGateway {
        ScriptedPowerGateway(accessories: accessories, deviceIsOn: isOn)
    }

    private func perform(
        _ gateway: ScriptedPowerGateway,
        target: AppleHomePowerTargetID = P.lightTarget,
        on: Bool = true,
        known: Bool = true
    ) async -> AppleHomePowerOutcome {
        var performer = AppleHomePowerPerformer(gateway: gateway)
        performer.sleep = { _ in }
        return await performer.perform(target: target, requestedOn: on, isShownStateKnown: known)
    }

    // MARK: - Success

    func testTurningOnIsConfirmedOnlyByTheReadBack() async {
        let homeKit = gateway(isOn: false)
        let outcome = await perform(homeKit, on: true)
        XCTAssertEqual(outcome, .confirmed(isOn: true, didWrite: true))
        XCTAssertEqual(homeKit.writes.map(\.isOn), [true])
        XCTAssertEqual(homeKit.writes.map(\.characteristicID), [F.lightPowerID], "the power characteristic by id, never brightness")
        XCTAssertEqual(homeKit.readCount, 2, "one read before writing, one after")
        XCTAssertEqual(homeKit.lookups.map(\.homeID), [F.homeID])
    }

    func testTurningOffAnOutlet() async {
        let homeKit = gateway([P.outlet()], isOn: true)
        let outcome = await perform(homeKit, target: P.outletTarget, on: false)
        XCTAssertEqual(outcome, .confirmed(isOn: false, didWrite: true))
        XCTAssertEqual(homeKit.writes.map(\.accessoryID), [P.outletID])
    }

    func testADeviceAlreadyInTheRequestedStateIsNotWrittenAgain() async {
        let homeKit = gateway(isOn: true)
        let outcome = await perform(homeKit, on: true)
        XCTAssertEqual(outcome, .confirmed(isOn: true, didWrite: false))
        XCTAssertTrue(homeKit.writes.isEmpty)
    }

    func testAnUnknownShownStateOnlyReadsTheDevice() async {
        let homeKit = gateway(isOn: true)
        let outcome = await perform(homeKit, on: true, known: false)
        XCTAssertEqual(outcome, .checked(isOn: true))
        XCTAssertFalse(outcome.isConfirmed)
        XCTAssertTrue(homeKit.writes.isEmpty)
    }

    func testALateReportIsWaitedForBriefly() async {
        let homeKit = gateway(isOn: false)
        homeKit.writeTakesEffect = false
        homeKit.queuedReads = [.success(false), .success(false), .success(true)]
        let outcome = await perform(homeKit, on: true)
        XCTAssertEqual(outcome, .confirmed(isOn: true, didWrite: true))
        XCTAssertEqual(homeKit.readCount, 3)
    }

    // MARK: - Failures after writing

    func testADeviceThatKeepsReportingTheOldStateIsAMismatch() async {
        let homeKit = gateway(isOn: false)
        homeKit.writeTakesEffect = false
        let outcome = await perform(homeKit, on: true)
        XCTAssertEqual(outcome, .failed(.mismatch, observedIsOn: false))
        XCTAssertEqual(homeKit.readCount, 1 + 3, "three read-backs before giving up")
    }

    func testAFailedReadBackIsUnconfirmedNotSuccess() async {
        let homeKit = gateway(isOn: false)
        homeKit.queuedReads = [.success(false), .failure(AppleHomePowerFailure.readFailed), .failure(AppleHomePowerFailure.readFailed), .failure(AppleHomePowerFailure.readFailed)]
        let outcome = await perform(homeKit, on: true)
        XCTAssertEqual(outcome, .failed(.unconfirmed, observedIsOn: nil))
        XCTAssertEqual(homeKit.writes.count, 1)
    }

    func testATimedOutReadBackIsNotRetried() async {
        let homeKit = gateway(isOn: false)
        homeKit.queuedReads = [.success(false), .failure(AppleHomePowerFailure.timedOut), .success(true)]
        let outcome = await perform(homeKit, on: true)
        XCTAssertEqual(outcome, .failed(.unconfirmed, observedIsOn: nil))
        XCTAssertEqual(homeKit.readCount, 2, "one read before writing, one read-back that timed out")
    }

    func testAFailedWriteIsAFailureEvenIfTheDeviceSwitched() async {
        let homeKit = gateway(isOn: false)
        homeKit.writeError = AppleHomePowerFailure.writeFailed
        homeKit.queuedReads = [.success(false), .success(true)]
        let outcome = await perform(homeKit, on: true)
        XCTAssertEqual(outcome, .failed(.writeFailed, observedIsOn: true), "what the device says now is kept for display, but it's not a success")
    }

    func testAWriteTimeoutAndAnUnreadableDeviceLeaveTheStateUnknown() async {
        let homeKit = gateway(isOn: false)
        homeKit.writeError = AppleHomePowerFailure.timedOut
        homeKit.queuedReads = [.success(false), .failure(AppleHomePowerFailure.timedOut)]
        let outcome = await perform(homeKit, on: true)
        XCTAssertEqual(outcome, .failed(.timedOut, observedIsOn: nil))
    }

    func testPermissionRevokedBetweenReadAndWrite() async {
        let homeKit = gateway(isOn: false)
        homeKit.writeError = AppleHomePowerFailure.notAuthorized
        homeKit.queuedReads = [.success(false), .failure(AppleHomePowerFailure.notAuthorized)]
        let outcome = await perform(homeKit, on: true)
        XCTAssertEqual(outcome, .failed(.notAuthorized, observedIsOn: nil))
    }

    func testPermissionRevokedBeforeTheReadBack() async {
        let homeKit = gateway(isOn: false)
        homeKit.queuedReads = [.success(false)] + Array(repeating: .failure(AppleHomePowerFailure.notAuthorized), count: 3)
        let outcome = await perform(homeKit, on: true)
        XCTAssertEqual(outcome, .failed(.notAuthorized, observedIsOn: nil))
    }

    // MARK: - Failures before writing

    func testNoAccessSendsNothing() async {
        for failure in [AppleHomePowerFailure.notAuthorized, .restricted, .homeKitUnavailable] {
            let homeKit = gateway()
            homeKit.prepareError = failure
            let outcome = await perform(homeKit)
            XCTAssertEqual(outcome, .failed(failure, observedIsOn: nil))
            XCTAssertTrue(homeKit.lookups.isEmpty)
            XCTAssertEqual(homeKit.readCount, 0)
            XCTAssertTrue(homeKit.writes.isEmpty)
        }
    }

    func testAnUnexpectedHomeKitErrorWhileLoadingIsUnavailable() async {
        let homeKit = gateway()
        homeKit.prepareError = NSError(domain: "HMErrorDomain", code: 52)
        let outcome1 = await perform(homeKit)
        XCTAssertEqual(outcome1, .failed(.homeKitUnavailable, observedIsOn: nil))
    }

    func testAMissingDeviceOrHomeSendsNothing() async {
        let removed = gateway([])
        let outcome2 = await perform(removed)
        XCTAssertEqual(outcome2, .failed(.targetMissing, observedIsOn: nil))

        let otherHome = gateway()
        let moved = AppleHomePowerTargetID(homeID: P.otherHomeID, accessoryID: F.lightID, characteristicID: F.lightPowerID)
        let outcome3 = await perform(otherHome, target: moved)
        XCTAssertEqual(outcome3, .failed(.targetMissing, observedIsOn: nil))
        XCTAssertTrue(removed.writes.isEmpty && otherHome.writes.isEmpty)
    }

    func testAChangedDeviceSendsNothing() async {
        // The same accessory id now has two outlets.
        let split = gateway([P.powerStrip(outletIDs: [F.lightPowerID, UUID()], id: F.lightID)])
        let outcome4 = await perform(split)
        XCTAssertEqual(outcome4, .failed(.targetChanged, observedIsOn: nil))

        // Its power is no longer writable.
        let readOnly = gateway([P.outlet(powerWritable: false)])
        let outcome5 = await perform(readOnly, target: P.outletTarget)
        XCTAssertEqual(outcome5, .failed(.targetChanged, observedIsOn: nil))

        // A different characteristic now carries the power state.
        let replaced = gateway([P.outlet()])
        let stale = AppleHomePowerTargetID(homeID: F.homeID, accessoryID: P.outletID, characteristicID: UUID())
        let outcome6 = await perform(replaced, target: stale)
        XCTAssertEqual(outcome6, .failed(.targetChanged, observedIsOn: nil))

        XCTAssertEqual(split.readCount + readOnly.readCount + replaced.readCount, 0)
        XCTAssertTrue(split.writes.isEmpty && readOnly.writes.isEmpty && replaced.writes.isEmpty)
    }

    func testANonRespondingDeviceSendsNothing() async {
        let unreachable = gateway([F.light(reachable: false)])
        let outcome7 = await perform(unreachable)
        XCTAssertEqual(outcome7, .failed(.notReachable, observedIsOn: nil))
        let blocked = gateway([F.light(blocked: true)])
        let outcome8 = await perform(blocked)
        XCTAssertEqual(outcome8, .failed(.notReachable, observedIsOn: nil))
        XCTAssertEqual(unreachable.readCount + blocked.readCount, 0)
    }

    func testAnUnreadableCurrentStateSendsNothing() async {
        let homeKit = gateway(isOn: nil)
        let outcome9 = await perform(homeKit)
        XCTAssertEqual(outcome9, .failed(.readFailed, observedIsOn: nil))
        XCTAssertTrue(homeKit.writes.isEmpty)

        let locked = gateway(isOn: nil)
        locked.readFailure = AppleHomePowerFailure.deviceLocked
        let outcome10 = await perform(locked)
        XCTAssertEqual(outcome10, .failed(.deviceLocked, observedIsOn: nil))

        let offline = gateway(isOn: nil)
        offline.readFailure = AppleHomePowerFailure.notReachable
        let outcome11 = await perform(offline)
        XCTAssertEqual(outcome11, .failed(.notReachable, observedIsOn: nil))
    }

    // MARK: - Runner (what the intent calls in the app)

    private func runner(
        _ homeKit: ScriptedPowerGateway,
        store: InMemoryPowerStore,
        reloader: CountingPowerReloader,
        enabled: Bool = true,
        gatewaysMade: GatewayCounter? = nil
    ) -> AppleHomePowerControlRunner {
        AppleHomePowerControlRunner(
            store: store,
            reloader: reloader,
            makeGateway: {
                gatewaysMade?.count += 1
                return homeKit
            },
            isAppleHomeEnabled: { enabled },
            now: { F.readAt.addingTimeInterval(500) },
            configurePerformer: { $0.sleep = { _ in } }
        )
    }

    func testAConfirmedTapIsStoredAndTheControlReloaded() async throws {
        let store = InMemoryPowerStore(P.catalog(states: [P.lightTarget: AppleHomePowerState(isOn: false, checkedAt: F.readAt)]))
        let reloader = CountingPowerReloader()
        let homeKit = gateway(isOn: false)

        try await runner(homeKit, store: store, reloader: reloader).perform(target: P.lightTarget, requestedOn: true, isShownStateKnown: true)

        let state = try XCTUnwrap(store.catalog?.state(P.lightTarget))
        XCTAssertEqual(state.isOn, true)
        XCTAssertEqual(state.checkedAt, F.readAt.addingTimeInterval(500))
        XCTAssertEqual(state.lastResult, .confirmed)
        XCTAssertEqual(reloader.count, 1)
    }

    func testAFailedTapThrowsAndForgetsTheOldState() async throws {
        let store = InMemoryPowerStore(P.catalog(states: [P.lightTarget: AppleHomePowerState(isOn: false, checkedAt: F.readAt)]))
        let reloader = CountingPowerReloader()
        let homeKit = gateway(isOn: false)
        homeKit.writeError = AppleHomePowerFailure.writeFailed
        homeKit.queuedReads = [.success(false), .failure(AppleHomePowerFailure.timedOut)]

        do {
            try await runner(homeKit, store: store, reloader: reloader).perform(target: P.lightTarget, requestedOn: true, isShownStateKnown: true)
            XCTFail("a failed write must not look like success")
        } catch {
            XCTAssertEqual(error as? AppleHomePowerFailure, .writeFailed)
        }
        let state = try XCTUnwrap(store.catalog?.state(P.lightTarget))
        XCTAssertNil(state.isOn, "the state from before the attempt is no longer known to be current")
        XCTAssertEqual(state.lastResult, .failed(.writeFailed))
        XCTAssertEqual(reloader.count, 1)
    }

    func testAStateCheckIsStoredWithoutWriting() async throws {
        let store = InMemoryPowerStore(P.catalog())
        let homeKit = gateway(isOn: true)
        try await runner(homeKit, store: store, reloader: CountingPowerReloader()).perform(target: P.lightTarget, requestedOn: true, isShownStateKnown: false)
        XCTAssertEqual(store.catalog?.state(P.lightTarget)?.isOn, true)
        XCTAssertEqual(store.catalog?.state(P.lightTarget)?.lastResult, .checked)
        XCTAssertTrue(homeKit.writes.isEmpty)
    }

    func testAppleHomeTurnedOffInPogoHomeNeverTouchesHomeKit() async {
        let store = InMemoryPowerStore(P.catalog())
        let made = GatewayCounter()
        let outcome = await runner(gateway(), store: store, reloader: CountingPowerReloader(), enabled: false, gatewaysMade: made)
            .run(target: P.lightTarget, requestedOn: true, isShownStateKnown: true)
        XCTAssertEqual(outcome, .failed(.appleHomeOff, observedIsOn: nil))
        XCTAssertEqual(made.count, 0)
    }

    func testANewTapWaitsForNothingWhileTheSameControlIsRunning() async {
        let store = InMemoryPowerStore(P.catalog())
        let homeKit = gateway(isOn: false)
        homeKit.holdsPrepare = true
        let runner = runner(homeKit, store: store, reloader: CountingPowerReloader())

        let first = Task { await runner.run(target: P.lightTarget, requestedOn: true, isShownStateKnown: true) }
        let holding = await waitUntil { homeKit.isHoldingPrepare }
        XCTAssertTrue(holding)
        let second = await runner.run(target: P.lightTarget, requestedOn: false, isShownStateKnown: true)
        XCTAssertEqual(second, .failed(.busy, observedIsOn: nil))
        homeKit.releasePrepare()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .confirmed(isOn: true, didWrite: true))
        XCTAssertEqual(homeKit.writes.map(\.isOn), [true])
    }

    func testNoTargetIsAFailure() async {
        let outcome = await runner(gateway(), store: InMemoryPowerStore(nil), reloader: CountingPowerReloader())
            .run(target: nil, requestedOn: true, isShownStateKnown: true)
        XCTAssertEqual(outcome, .failed(.targetMissing, observedIsOn: nil))
    }

    // MARK: - Publisher (the app keeping the catalog current)

    private func makeModel(_ snapshot: AppleHomeSnapshot, enabled: Bool = true) -> (AppleHomeModel, ScriptedAppleHomeProvider) {
        let provider = ScriptedAppleHomeProvider(snapshot: snapshot)
        let model = AppleHomeModel(provider: provider, defaults: makeIsolatedDefaults())
        if enabled { model.enable() }
        return (model, provider)
    }

    func testThePublisherWritesEligibleTargetsWithTheAppsConfirmedStates() throws {
        let (model, _) = makeModel(F.ready([F.light(power: .bool(true)), P.outlet(power: nil), F.sensor()]))
        let store = InMemoryPowerStore(nil)
        let reloader = CountingPowerReloader()
        let publisher = AppleHomePowerCatalogPublisher(appleHome: model, store: store, reloader: reloader, now: { F.readAt })

        publisher.publish()

        let catalog = try XCTUnwrap(store.catalog)
        XCTAssertEqual(catalog.targets.map(\.id), [P.lightTarget, P.outletTarget])
        XCTAssertEqual(catalog.state(P.lightTarget)?.isOn, true)
        XCTAssertNil(catalog.state(P.outletTarget), "never read by the app: unknown")
        XCTAssertEqual(reloader.count, 1)

        publisher.publish()
        XCTAssertEqual(store.saveCount, 1, "unchanged content isn't rewritten")
        XCTAssertEqual(reloader.count, 1)
    }

    func testThePublisherFollowsPermissionChanges() async throws {
        let (model, provider) = makeModel(F.ready([F.light()]))
        let store = InMemoryPowerStore(nil)
        let publisher = AppleHomePowerCatalogPublisher(appleHome: model, store: store, reloader: CountingPowerReloader(), debounce: .milliseconds(1))
        publisher.start()
        XCTAssertEqual(store.catalog?.availability, .ready)

        provider.publish(AppleHomeSnapshot(accessState: .denied))
        let cleared = await waitUntil { store.catalog?.availability == .denied }
        XCTAssertTrue(cleared)
        XCTAssertEqual(store.catalog?.targets, [])

        model.disable()
        let off = await waitUntil { store.catalog?.availability == .off }
        XCTAssertTrue(off)
    }

    func testThePublisherLeavesTheCatalogAloneBeforeAppleHomeStarts() {
        // A background launch for a control action: Apple Home is on, but the model hasn't
        // started in this process.
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: AppleHomeSettingsKeys.enabled)
        let model = AppleHomeModel(provider: ScriptedAppleHomeProvider(snapshot: F.ready([F.light()])), defaults: defaults)
        let existing = P.catalog(states: [P.lightTarget: AppleHomePowerState(isOn: true, checkedAt: F.readAt)])
        let store = InMemoryPowerStore(existing)
        AppleHomePowerCatalogPublisher(appleHome: model, store: store, reloader: CountingPowerReloader()).publish()
        XCTAssertEqual(store.catalog, existing)
        XCTAssertEqual(store.saveCount, 0)
    }
}

@MainActor
final class GatewayCounter {
    var count = 0
}
