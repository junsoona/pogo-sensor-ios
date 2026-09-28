import AppIntents
import XCTest
@testable import PogoHome

/// The Control Center power toggle's shared parts: which devices may be chosen, how targets
/// are identified, what the stored catalog holds, what the control shows from it, and how the
/// intent is declared (app process only, unlocked iPhone).
@MainActor
final class AppleHomePowerControlTests: XCTestCase {
    private typealias F = AppleHomeFixtures
    private typealias P = PowerControlFixtures

    // MARK: - Eligibility

    func testDimmableLightIsEligibleByItsSinglePowerControlNotBrightness() {
        XCTAssertEqual(AppleHomePowerEligibility.evaluate(F.light()), .eligible(characteristicID: F.lightPowerID, kind: .light))
        XCTAssertEqual(AppleHomePowerEligibility.targetID(of: F.light()), P.lightTarget)
    }

    func testOutletsAndSwitchesAreEligible() {
        XCTAssertEqual(AppleHomePowerEligibility.evaluate(P.outlet()), .eligible(characteristicID: P.outletPowerID, kind: .outlet))
        XCTAssertEqual(AppleHomePowerEligibility.evaluate(P.wallSwitch()), .eligible(characteristicID: P.switchPowerID, kind: .switch))
    }

    func testPowerThatIsNotWritableIsNotEligible() {
        XCTAssertEqual(AppleHomePowerEligibility.evaluate(F.readOnlyLight()), .notEligible(.noOnOffControl))
        XCTAssertEqual(AppleHomePowerEligibility.evaluate(P.outlet(powerWritable: false)), .notEligible(.noOnOffControl))
    }

    func testSensorsAndLocksAreNeverEligible() {
        XCTAssertEqual(AppleHomePowerEligibility.evaluate(F.sensor()), .notEligible(.noOnOffControl))
        XCTAssertEqual(AppleHomePowerEligibility.evaluate(F.lock()), .notEligible(.noOnOffControl))
    }

    func testSeveralOnOffControlsAreNotEligible() {
        XCTAssertEqual(AppleHomePowerEligibility.evaluate(P.powerStrip()), .notEligible(.multipleOnOffControls(2)))
    }

    func testFansAndAirPurifiersAreNotEligible() {
        XCTAssertEqual(AppleHomePowerEligibility.evaluate(P.fan()), .notEligible(.unsupportedService))
        XCTAssertEqual(AppleHomePowerEligibility.evaluate(P.airPurifier()), .notEligible(.unsupportedService))
    }

    func testAnUnreachableDeviceStaysSelectable() {
        XCTAssertEqual(AppleHomePowerEligibility.targetID(of: P.outlet(reachable: false)), P.outletTarget)
        XCTAssertEqual(AppleHomePowerEligibility.targetID(of: F.light(blocked: true)), P.lightTarget)
    }

    // MARK: - Identifiers

    func testTargetIDRoundTripsThroughItsString() {
        let id = P.lightTarget
        XCTAssertEqual(AppleHomePowerTargetID(stringValue: id.stringValue), id)
        XCTAssertTrue(id.stringValue.hasPrefix("appleHomePower/"))
    }

    func testTargetIDRejectsNamesAndOtherIdentifiers() {
        XCTAssertNil(AppleHomePowerTargetID(stringValue: "거실 조명"))
        XCTAssertNil(AppleHomePowerTargetID(stringValue: HomeGlanceValueID.appleHome(accessory: F.lightID, characteristic: F.lightPowerID).stringValue))
        XCTAssertNil(AppleHomePowerTargetID(stringValue: "appleHomePower/\(F.homeID)/\(F.lightID)"))
        XCTAssertNil(AppleHomePowerTargetID(stringValue: "appleHomePower/\(F.homeID)/\(F.lightID)/not-a-uuid"))
    }

    func testTwoDevicesWithTheSameNameAreDifferentTargets() {
        let a = F.light(name: "조명")
        let b = P.outlet()
        let renamed = AppleHomeAccessory(id: b.id, homeID: b.homeID, name: "조명", isReachable: true, services: b.services)
        XCTAssertNotEqual(AppleHomePowerEligibility.targetID(of: a), AppleHomePowerEligibility.targetID(of: renamed))
    }

    // MARK: - Catalog

    private func build(
        _ snapshot: AppleHomeSnapshot,
        isEnabled: Bool = true,
        previous: AppleHomePowerCatalog? = nil,
        confirmed: [UUID: AppleHomePowerCatalogBuilder.ConfirmedPower] = [:]
    ) -> AppleHomePowerCatalog? {
        AppleHomePowerCatalogBuilder.build(
            isEnabled: isEnabled,
            snapshot: snapshot,
            confirmedPower: { _, characteristicID in confirmed[characteristicID] },
            previous: previous,
            now: F.readAt.addingTimeInterval(100)
        )
    }

    func testCatalogListsOnlyEligibleDevicesWithTheirIDsAndPlace() throws {
        let snapshot = F.ready([F.light(), F.readOnlyLight(), F.sensor(), F.lock(), P.outlet(), P.powerStrip(), P.fan()])
        let catalog = try XCTUnwrap(build(snapshot))
        XCTAssertEqual(catalog.availability, .ready)
        XCTAssertEqual(catalog.targets.map(\.id), [P.lightTarget, P.outletTarget])
        XCTAssertEqual(catalog.targets.first, AppleHomePowerTarget(id: P.lightTarget, name: "거실 조명", roomName: "거실", homeName: "우리 집", kind: .light))
        XCTAssertEqual(catalog.knownNames[P.outletTarget.stringValue], "전기포트 플러그")
    }

    func testCatalogTakesTheAppsReadWhenItIsNewer() throws {
        let stored = P.catalog(states: [P.lightTarget: AppleHomePowerState(isOn: false, checkedAt: F.readAt, lastResult: .confirmed, resultAt: F.readAt)])
        let catalog = try XCTUnwrap(build(F.ready([F.light()]), previous: stored, confirmed: [F.lightPowerID: .init(isOn: true, at: F.readAt.addingTimeInterval(10))]))
        let state = try XCTUnwrap(catalog.state(P.lightTarget))
        XCTAssertEqual(state.isOn, true)
        XCTAssertEqual(state.checkedAt, F.readAt.addingTimeInterval(10))
        XCTAssertEqual(state.lastResult, .confirmed, "the last action's result is kept")
    }

    func testCatalogKeepsANewerStateFromTheToggle() throws {
        let toggled = AppleHomePowerState(isOn: true, checkedAt: F.readAt.addingTimeInterval(50), lastResult: .confirmed, resultAt: F.readAt.addingTimeInterval(50))
        let stored = P.catalog(states: [P.lightTarget: toggled])
        let catalog = try XCTUnwrap(build(F.ready([F.light()]), previous: stored, confirmed: [F.lightPowerID: .init(isOn: false, at: F.readAt)]))
        XCTAssertEqual(catalog.state(P.lightTarget), toggled)
    }

    func testAnUnknownValueInTheAppDoesNotInventOrEraseAState() throws {
        XCTAssertNil(try XCTUnwrap(build(F.ready([F.light()]))).state(P.lightTarget))
        let stored = P.catalog(states: [P.lightTarget: AppleHomePowerState(isOn: true, checkedAt: F.readAt)])
        XCTAssertEqual(try XCTUnwrap(build(F.ready([F.light()]), previous: stored)).state(P.lightTarget)?.isOn, true)
    }

    func testCatalogDropsStatesOfDevicesThatAreGone() throws {
        let stored = P.catalog(targets: [P.lightEntry, P.outletEntry], states: [
            P.lightTarget: AppleHomePowerState(isOn: true, checkedAt: F.readAt),
            P.outletTarget: AppleHomePowerState(isOn: true, checkedAt: F.readAt),
        ], knownNames: [P.outletTarget.stringValue: "전기포트 플러그"])
        let catalog = try XCTUnwrap(build(F.ready([F.light()]), previous: stored))
        XCTAssertEqual(catalog.targets.map(\.id), [P.lightTarget])
        XCTAssertNil(catalog.state(P.outletTarget))
        XCTAssertEqual(catalog.knownNames[P.outletTarget.stringValue], "전기포트 플러그", "a configured control keeps its label")
    }

    func testLosingAccessClearsTargetsAndStates() throws {
        let stored = P.catalog(states: [P.lightTarget: AppleHomePowerState(isOn: true, checkedAt: F.readAt)], knownNames: [P.lightTarget.stringValue: "거실 조명"])
        for (state, expected) in [(AppleHomeAccessState.denied, AppleHomePowerAvailability.denied), (.restricted, .restricted), (.noHome, .noHome)] {
            let catalog = try XCTUnwrap(build(AppleHomeSnapshot(accessState: state), previous: stored))
            XCTAssertEqual(catalog.availability, expected)
            XCTAssertEqual(catalog.targets, [])
            XCTAssertEqual(catalog.states, [:])
            XCTAssertEqual(catalog.knownNames, [P.lightTarget.stringValue: "거실 조명"])
        }
    }

    func testTurningAppleHomeOffInPogoHomeClearsTheCatalog() throws {
        let catalog = try XCTUnwrap(build(.off, isEnabled: false, previous: P.catalog()))
        XCTAssertEqual(catalog.availability, .off)
        XCTAssertEqual(catalog.targets, [])
    }

    func testNothingIsWrittenWhileAppleHomeIsUnsettled() {
        XCTAssertNil(build(AppleHomeSnapshot(accessState: .loading)))
        // Enabled but not started in this process (e.g. a background launch for a control).
        XCTAssertNil(build(.off, isEnabled: true))
    }

    // MARK: - Target query

    func testOnlyEligibleTargetsOfAReadableAppleHomeAreOffered() {
        let ready = AppleHomePowerStore.LoadResult.catalog(P.catalog(targets: [P.lightEntry, P.outletEntry]))
        let offered = AppleHomePowerTargetQuery.selectable(in: ready)
        XCTAssertEqual(offered.map(\.id), [P.lightTarget.stringValue, P.outletTarget.stringValue])
        XCTAssertEqual(offered.first?.name, "거실 조명")
        XCTAssertEqual(AppleHomePowerTargetQuery.selectable(in: .catalog(P.catalog(availability: .denied))).map(\.id), [])
        XCTAssertEqual(AppleHomePowerTargetQuery.selectable(in: .missing).map(\.id), [])
    }

    func testAConfiguredTargetStillResolvesAfterItIsGone() {
        let gone = AppleHomePowerStore.LoadResult.catalog(P.catalog(targets: [], knownNames: [P.outletTarget.stringValue: "전기포트 플러그"]))
        let entities = AppleHomePowerTargetQuery.entities(for: [P.outletTarget.stringValue, "not-a-target"], in: gone)
        XCTAssertEqual(entities.map(\.id), [P.outletTarget.stringValue])
        XCTAssertEqual(entities.first?.name, "전기포트 플러그")
        XCTAssertEqual(entities.first?.targetID, P.outletTarget)
    }

    // MARK: - Store

    func testStoreRoundTripsAndRejectsAnotherSchema() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AppleHomePowerStore-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppleHomePowerStore(directory: directory)
        XCTAssertEqual(store.load(), .missing)

        let catalog = P.catalog(states: [P.lightTarget: AppleHomePowerState(isOn: true, checkedAt: F.readAt, lastResult: .failed(.mismatch), resultAt: F.readAt)])
        try store.save(catalog)
        XCTAssertEqual(AppleHomePowerStore(directory: directory).load(), .catalog(catalog))

        let other = AppleHomePowerCatalog(writtenAt: F.readAt, availability: .ready, targets: [], states: [:], knownNames: [:], schemaVersion: 99)
        try store.save(other)
        XCTAssertEqual(store.load(), .unreadable)
    }

    func testTheStoreLivesInTheAppGroupNextToTheGlance() throws {
        let store = try XCTUnwrap(AppleHomePowerStore.shared())
        let glance = try XCTUnwrap(HomeGlanceStore.shared())
        XCTAssertEqual(store.fileURL.deletingLastPathComponent(), glance.fileURL.deletingLastPathComponent())
    }

    // MARK: - What the control shows

    private func display(
        _ catalog: AppleHomePowerCatalog?,
        target: AppleHomePowerTargetID? = P.lightTarget,
        at now: Date = F.readAt.addingTimeInterval(30)
    ) -> AppleHomePowerControlDisplay {
        AppleHomePowerControlDisplay.make(targetID: target, configuredName: "설정된 이름", load: catalog.map { .catalog($0) } ?? .missing, now: now)
    }

    func testARecentReadIsShownAsTheState() {
        let on = display(P.catalog(states: [P.lightTarget: AppleHomePowerState(isOn: true, checkedAt: F.readAt)]))
        XCTAssertEqual(on.state, .on)
        XCTAssertTrue(on.isOn)
        XCTAssertTrue(on.isStateKnown)
        XCTAssertEqual(on.title, "거실 조명")
        XCTAssertEqual(on.kind, .light)
        XCTAssertEqual(on.valueText, String(localized: "켜짐", comment: "Apple Home: on"))
        XCTAssertEqual(on.actionHint, String(localized: "끄기", comment: "Control Center action hint: turn off"))

        let off = display(P.catalog(states: [P.lightTarget: AppleHomePowerState(isOn: false, checkedAt: F.readAt)]))
        XCTAssertEqual(off.state, .off)
        XCTAssertFalse(off.isOn)
        XCTAssertEqual(off.actionHint, String(localized: "켜기", comment: "Control Center action hint: turn on"))
    }

    func testAnOldReadIsShownAsLastSeenNotAsCurrent() {
        let old = display(
            P.catalog(states: [P.lightTarget: AppleHomePowerState(isOn: true, checkedAt: F.readAt)]),
            at: F.readAt.addingTimeInterval(HomeGlanceFreshness.staleAfter + 1)
        )
        XCTAssertEqual(old.state, .lastSeen(isOn: true))
        XCTAssertNotEqual(old.valueText, String(localized: "켜짐", comment: "Apple Home: on"))
        XCTAssertTrue(old.isStateKnown, "a tap re-reads the device before writing anything")
    }

    func testANeverReadStateIsUnknownAndItsTapOnlyChecks() {
        let unknown = display(P.catalog())
        XCTAssertEqual(unknown.state, .unknown)
        XCTAssertFalse(unknown.isStateKnown)
        XCTAssertFalse(unknown.isOn)
        XCTAssertEqual(unknown.actionHint, String(localized: "상태 확인", comment: "Control Center action hint: read the state only"))
        XCTAssertEqual(unknown.pendingText(requestedOn: true), String(localized: "확인 중…", comment: "Control Center value: reading the state"))
    }

    func testAFailedActionLeavesTheStateUnknownAndSaysWhy() {
        let failed = AppleHomePowerState(isOn: nil, checkedAt: F.readAt, lastResult: .failed(.notReachable), resultAt: F.readAt)
        let shown = display(P.catalog(states: [P.lightTarget: failed]))
        XCTAssertEqual(shown.state, .unknown)
        XCTAssertEqual(shown.status, AppleHomePowerFailure.notReachable.message)
        XCTAssertNil(display(P.catalog(states: [P.lightTarget: failed]), at: F.readAt.addingTimeInterval(AppleHomePowerControlDisplay.statusWindow + 1)).status)
    }

    func testWhileATapIsRunningTheControlSaysSoInsteadOfTheNewState() {
        let off = display(P.catalog(states: [P.lightTarget: AppleHomePowerState(isOn: false, checkedAt: F.readAt)]))
        XCTAssertEqual(off.pendingText(requestedOn: true), String(localized: "켜는 중…", comment: "Control Center value: turning on, not confirmed yet"))
        XCTAssertEqual(off.pendingText(requestedOn: false), String(localized: "끄는 중…", comment: "Control Center value: turning off, not confirmed yet"))
    }

    func testUnavailableTargetsAreSaidToBeUnavailable() {
        XCTAssertEqual(display(P.catalog(availability: .off)).state, .unavailable(.appleHomeOff))
        XCTAssertEqual(display(P.catalog(availability: .denied)).state, .unavailable(.noAccess))
        XCTAssertEqual(display(P.catalog(availability: .restricted)).state, .unavailable(.noAccess))
        XCTAssertEqual(display(P.catalog(targets: [P.outletEntry])).state, .unavailable(.targetGone))
        XCTAssertFalse(display(P.catalog(availability: .denied)).isStateKnown)
    }

    func testNotConfiguredAndNothingStored() {
        XCTAssertEqual(display(P.catalog(), target: nil).state, .notConfigured)
        let missing = display(nil)
        XCTAssertEqual(missing.state, .unknown)
        XCTAssertEqual(missing.title, "설정된 이름")
    }

    // MARK: - Intent declaration

    func testTheToggleRunsOnlyInTheAppInTheBackgroundAfterUnlock() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("allowedExecutionTargets needs iOS 27") }
        XCTAssertEqual(SetAppleHomePowerIntent.allowedExecutionTargets, .main)
        XCTAssertFalse(SetAppleHomePowerIntent.allowedExecutionTargets.contains(.widgetKitExtension))
        XCTAssertEqual(SetAppleHomePowerIntent.authenticationPolicy, .requiresAuthentication)
        XCTAssertEqual(SetAppleHomePowerIntent.supportedModes, .background)
        XCTAssertFalse(SetAppleHomePowerIntent.isDiscoverable)
    }

    // MARK: - Localization

    /// Korean keys of every string the control can show, in the app and in the widget extension.
    private var controlKeys: [String] {
        AppleHomePowerFailure.allCases.map { $0.messageResource.key } + [
            "조명", "콘센트", "스위치", "켜짐", "꺼짐", "마지막 확인: 켜짐", "마지막 확인: 꺼짐", "상태 모름", "사용할 수 없음",
            "기기를 선택하세요", "상태 확인", "끄기", "켜기", "확인 중…", "켜는 중…", "끄는 중…", "Apple 홈 전원 기기",
            "현재 상태를 확인했습니다", "Apple 홈 기기 선택", "대상 기기", "Apple 홈 기기 켜기/끄기", "Apple 홈 기기 전원",
            "제어 센터에서 켜고 끌 조명, 콘센트 또는 스위치를 고릅니다.",
            "선택한 조명, 콘센트 또는 스위치를 켜고 끕니다. 기기가 새 상태를 보고해야 완료로 표시됩니다.",
        ]
    }

    func testEveryControlStringIsTranslatedInTheAppAndTheWidgetExtension() throws {
        let widgets = try XCTUnwrap(Bundle.main.builtInPlugInsURL.flatMap { Bundle(url: $0.appending(path: "PogoHomeWidgets.appex")) })
        for bundle in [Bundle.main, widgets] {
            for language in ["en", "es"] {
                let path = try XCTUnwrap(bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language), "\(bundle.bundleURL.lastPathComponent) \(language)")
                let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
                for key in controlKeys {
                    let value = try XCTUnwrap(table[key], "\(bundle.bundleURL.lastPathComponent) \(language): \(key)")
                    XCTAssertNotEqual(value, key, "\(language): \(key)")
                }
            }
        }
    }
}
