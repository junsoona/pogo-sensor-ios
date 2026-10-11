import XCTest
@testable import PogoHome

/// "허브 목록에서 제거", all the way: the hub's JSON through the real `LiveSensorDataSource` and
/// `PogoSnapshotMapper` into the real `AppModel` (with rooms configured, as on every device), the
/// real `PowerBaseRemovalController`, and the sheet's state read the way `PowerBaseManagementSheet`
/// reads it. The hub's answers to requests are scripted (`FakeRemovalHub`); its snapshots are the
/// JSON the real hub writes.
///
/// A second app (another `AppModel` and controller on the same scripted hub) stands for the second
/// iPhone: what one device does reaches the other only through the hub's snapshot.
@MainActor
final class AppModelPowerBaseForgetTests: XCTestCase {
    private typealias P = PowerBaseManagementPresentation
    private typealias F = ForgetFixtures

    private static let gasSensor = "744dbdfffe65d357"
    private static let dustSensor = "744dbdfffe65d07a"
    private static let otherSensor = "0011223344556677"

    /// One running app: its connection to the hub, its model and its removal controller.
    private final class Device {
        let transport: ControllableSensorAPITransport
        let model: AppModel
        let removalHub: FakeRemovalHub
        let removals: PowerBaseRemovalController

        init(transport: ControllableSensorAPITransport, model: AppModel, removalHub: FakeRemovalHub, removals: PowerBaseRemovalController) {
            self.transport = transport
            self.model = model
            self.removalHub = removalHub
            self.removals = removals
        }
    }

    private var settingsHub: FakeSettingsHub!
    private var devices: [Device] = []

    override func tearDown() async throws {
        devices.forEach { $0.model.stop() }
        devices = []
        settingsHub = nil
    }

    /// An app following the hub picked in "허브 찾기", paired, connected, with the first snapshot in.
    private func startDevice(first: Data, hubID: String? = nil, store: InMemoryHomeConfigurationStore = InMemoryHomeConfigurationStore(language: .korean)) async throws -> Device {
        if settingsHub == nil { settingsHub = FakeSettingsHub() }
        let hub: FakeSettingsHub = settingsHub
        let credentials = InMemoryHubCredentialStore()
        let transport = ControllableSensorAPITransport { first }
        let model = AppModel(
            dataSource: LiveSensorDataSource(
                endpoint: PogoAPIEndpoint(baseURL: RemovalFixtures.url), transport: transport, sleeper: RecordingSleeper(),
                livenessIdleTimeout: 5, periodicRefreshInterval: nil
            ),
            sourceIdentity: .hub(id: hubID ?? hub.hubID),
            sourceAddress: RemovalFixtures.url,
            configurationStore: store,
            sharedSettings: SharedSettingsController(
                transport: hub, credentials: credentials, cache: InMemorySharedSettingsCache(), language: .korean, retryInterval: .zero
            ),
            language: .korean
        )
        let removalHub = FakeRemovalHub()
        let device = Device(transport: transport, model: model, removalHub: removalHub, removals: PowerBaseRemovalController(transport: removalHub, credentials: credentials))
        devices.append(device)
        model.start()
        try await waitUntil { model.lastSyncAt != nil }
        try await waitUntil { await transport.hasOpenEventStream }
        await transport.sendLine(": heartbeat")
        try await waitUntil { model.connectionStatus == .connected }
        if hubID == nil {
            _ = hub.createCode()
            _ = try await model.sharedSettings.pair(code: "7KQM-3XWD-PA9T", deviceName: "Test \(devices.count)")
        }
        report(device)
        return device
    }

    /// The hub's next snapshot on the open connection, received whether or not it is put on screen.
    private func deliver(_ json: Data, to device: Device) async throws {
        let before = device.model.lastSyncAt
        await device.transport.setSnapshotProvider { json }
        await device.transport.sendLines(PogoAPIFixtures.sseSnapshotEvent(json: json))
        try await waitUntil { device.model.lastSyncAt != before }
        report(device)
    }

    /// What `DevicesView` hands the controller for the first snapshot and for every change.
    private func report(_ device: Device) {
        device.removals.targetDidChange(PowerBaseHubTarget(appModel: device.model))
        device.removals.sourceDidReport(
            device.model.snapshot.powerBaseRemovals, forgets: device.model.snapshot.powerBaseForgets,
            powerBases: device.model.snapshot.powerBases, from: device.model.sourceIdentity
        )
    }

    /// The sheet's state, read as `PowerBaseManagementSheet.state` reads it.
    private func sheetState(_ device: Device, _ identifier: String = ForgetFixtures.base) -> P.State {
        P.state(
            identifier: identifier, snapshot: device.model.snapshot, target: device.removals.target,
            removal: device.removals.removal(for: identifier, in: device.model.snapshot),
            action: device.removals.action(for: identifier),
            isCurrentStateVerified: device.model.isPowerBaseStateVerified,
            forgetAction: device.removals.forgetAction(for: identifier)
        )
    }

    private func carriedOut(_ hub: FakeRemovalHub) {
        hub.scriptForget { base, record, requestID in .success(ForgetFixtures.forget(requestID: requestID, base: base, record: record)) }
    }

    private func sentRequestID(_ device: Device, _ index: Int = 0) throws -> String {
        guard case let .forget(_, _, _, _, _, requestID) = try XCTUnwrap(device.removalHub.forgets.dropFirst(index).first) else { throw XCTSkip("no list removal was sent") }
        return requestID
    }

    /// One offline Base with two sensors: the last Base of the home.
    private func offlineHome(record: String = ForgetFixtures.record, removals: [String] = [], forgets: [String]? = []) -> Data {
        F.snapshot(
            bases: [F.baseJSON(moduleCount: 2, record: record)],
            modules: [F.moduleJSON(Self.gasSensor, base: F.base), F.moduleJSON(Self.dustSensor, base: F.base)],
            removals: removals, forgets: forgets
        )
    }

    // MARK: - One device

    func testTheLastOfflineBaseIsTakenOutOfTheListAndTheScreenIsEmptyAtOnce() async throws {
        let device = try await startDevice(first: offlineHome())
        var state = sheetState(device)
        XCTAssertEqual(state.forgetOffer, P.ForgetOffer(record: F.record, removalEffect: .none))
        XCTAssertEqual(state.sensorCount, 2)

        // "허브 목록에서 제거", confirmed.
        carriedOut(device.removalHub)
        device.removals.forgetPowerBase(F.base, record: try XCTUnwrap(state.forgetOffer).record)
        try await waitUntil { device.removals.completionEvents.count == 1 }
        XCTAssertEqual(device.removals.completionEvents.first?.completion.kind, .removedFromHubList)
        guard case let .forget(_, _, _, base, record, requestID) = try XCTUnwrap(device.removalHub.recorded.first) else { return XCTFail() }
        XCTAssertEqual([base, record], [F.base, F.record])

        // The hub's next snapshot: no Base, no sensor, no removal job -- and its record of why.
        try await deliver(F.snapshot(bases: [], forgets: [F.json(requestID: requestID)]), to: device)
        XCTAssertTrue(device.model.snapshot.powerBases.isEmpty)
        XCTAssertTrue(device.model.snapshot.modules.isEmpty, "the sensors left the screen with the Base: an empty list that the hub explained is not held back")
        XCTAssertFalse(device.model.isRegistryRecovering)
        XCTAssertEqual(device.model.dataWait, .noModulesYet)
        state = sheetState(device)
        XCTAssertNil(state.base)
        XCTAssertNil(state.removal, "nothing is shown as a removal: not waiting, not released, not completed")
        XCTAssertNil(state.forgetOffer)
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: device.model.snapshot).isEmpty, "and no request row is left behind")
        XCTAssertNil(P.badge(for: device.model.snapshot.removal(forPowerBase: F.base)))
        // Told once, with its own words.
        XCTAssertEqual(device.removals.completionEvents.count, 1)
        let notice = PowerBaseRemovalCompletionNotice.text(for: try XCTUnwrap(device.removals.notices.waiting.first))
        XCTAssertEqual(notice, PowerBaseManagementText.forgetNotice(label: P.label(forIdentifier: F.base)))
        XCTAssertNotEqual(notice, PowerBaseManagementText.completionNotice(label: P.label(forIdentifier: F.base)))
        XCTAssertEqual(device.removalHub.recorded.count, 1, "one request; no removal, no cancel, no receipt")
    }

    func testAnEmptyListTheHubDidNotExplainIsStillHeldBack() async throws {
        // The same empty list without the hub's record: a hub that is starting again.
        let device = try await startDevice(first: offlineHome())
        try await deliver(F.snapshot(bases: [], forgets: []), to: device)
        XCTAssertEqual(device.model.snapshot.modules.count, 2, "silence is not a list removal")
        XCTAssertTrue(device.model.isRegistryRecovering)
    }

    func testAHubThatDoesNotSayItCanIsNeverAsked() async throws {
        // 1.2.x's hub: management, no `record`, no `power_base_forgets`.
        let old = F.snapshot(
            bases: [F.baseJSON(moduleCount: 1, record: nil)], modules: [F.moduleJSON(Self.gasSensor, base: F.base)], forgets: nil
        )
        let device = try await startDevice(first: old)
        let state = sheetState(device)
        XCTAssertFalse(device.model.snapshot.reportsPowerBaseForget)
        XCTAssertNil(state.forgetOffer, "not offered")
        // That hub's removal takes the Base's id alone, which names no registration: since 1.3.3
        // the app does not send such a request, and says the hub has to be updated.
        XCTAssertEqual(state.availability, .hubUnsupported, "a removal is not asked of a hub that cannot be told which registration")
        XCTAssertTrue(device.removalHub.recorded.isEmpty)
    }

    func testABaseRegisteredTheEarlierWayIsTakenOutWhileItsRemovalStaysUnsupported() async throws {
        let earlier = F.snapshot(
            bases: [F.baseJSON(moduleCount: 1, management: "unsupported")], modules: [F.moduleJSON(Self.gasSensor, base: F.base)]
        )
        let device = try await startDevice(first: earlier)
        let state = sheetState(device)
        XCTAssertEqual(state.availability, .powerBaseUnsupported)
        XCTAssertEqual(state.forgetOffer?.record, F.record)
        carriedOut(device.removalHub)
        device.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { device.removals.completionEvents.count == 1 }
        try await deliver(F.snapshot(bases: [], forgets: [F.json(requestID: try sentRequestID(device))]), to: device)
        XCTAssertTrue(device.model.snapshot.modules.isEmpty)
    }

    func testTheOtherBaseItsSensorsNamesAndRoomsStayAsTheyWere() async throws {
        let store = InMemoryHomeConfigurationStore(language: .korean)
        func home(withFirstBase: Bool, forgets: [String]) -> Data {
            F.snapshot(
                bases: (withFirstBase ? [F.baseJSON(moduleCount: 1)] : []) + [F.baseJSON(F.otherBase, online: true, moduleCount: 2, record: F.laterRecord)],
                modules: (withFirstBase ? [F.moduleJSON(Self.gasSensor, base: F.base)] : [])
                    // The dust sensor was docked on the first Base before; it is on the other one now.
                    + [F.moduleJSON(Self.dustSensor, base: F.otherBase, online: true), F.moduleJSON(Self.otherSensor, base: F.otherBase, online: true)],
                forgets: forgets
            )
        }
        let device = try await startDevice(first: home(withFirstBase: true, forgets: []), store: store)
        let model = device.model
        let moved = try XCTUnwrap(model.snapshot.modules.first { $0.hardwareIdentifier == Self.dustSensor })
        let room = try XCTUnwrap(model.editableRooms.first)
        try await model.updateModule(id: moved.id, customName: "창가 먼지 센서", roomID: room.id)
        XCTAssertEqual(sheetState(device).forgetOffer?.record, F.record)
        XCTAssertNil(sheetState(device, F.otherBase).forgetOffer, "the Base the hub hears is not offered")

        carriedOut(device.removalHub)
        device.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { device.removals.completionEvents.count == 1 }
        try await deliver(home(withFirstBase: false, forgets: [F.json(requestID: try sentRequestID(device))]), to: device)

        XCTAssertEqual(model.snapshot.powerBases.map(\.hardwareIdentifier), [F.otherBase])
        XCTAssertEqual(Set(model.snapshot.modules.compactMap(\.hardwareIdentifier)), [Self.dustSensor, Self.otherSensor])
        let kept = try XCTUnwrap(model.snapshot.modules.first { $0.hardwareIdentifier == Self.dustSensor })
        XCTAssertEqual(kept.name, "창가 먼지 센서", "the moved sensor keeps the name the user gave it")
        XCTAssertEqual(kept.roomID, room.id, "and its room")
        XCTAssertTrue(kept.isOnline)
        XCTAssertEqual(model.snapshot.powerBases.first?.record, F.laterRecord)
        XCTAssertEqual(sheetState(device, F.otherBase).availability, .available)
    }

    func testAPendingRemovalIsSaidToBeCancelledAndIsNotLeftBehind() async throws {
        let device = try await startDevice(first: offlineHome(removals: [RemovalFixtures.json("pending")]))
        var state = sheetState(device)
        XCTAssertEqual(state.removal?.presentation, .waitingForPowerBase)
        XCTAssertEqual(state.forgetOffer?.removalEffect, .cancelsPendingRemoval)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [.cancel], "the stored request can still be cancelled as before")

        device.removalHub.scriptForget { base, record, requestID in
            .success(ForgetFixtures.forget(requestID: requestID, base: base, record: record, cancelled: RemovalFixtures.removalID))
        }
        device.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { device.removals.completionEvents.count == 1 }
        try await deliver(F.snapshot(
            bases: [], removals: [RemovalFixtures.json("cancelled")],
            forgets: [F.json(requestID: try sentRequestID(device), cancelled: RemovalFixtures.removalID)]
        ), to: device)
        state = sheetState(device)
        XCTAssertNil(state.base)
        XCTAssertTrue(device.model.snapshot.modules.isEmpty)
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: device.model.snapshot).isEmpty, "a cancelled request is no row")
        XCTAssertEqual(device.removals.completionEvents.map(\.completion.kind), [.removedFromHubList], "and nothing was announced as a completed removal")
    }

    func testARemovalWhoseCommandWentOutStaysVisibleAsWhatItIs() async throws {
        let unknown = RemovalFixtures.json("sent").replacingOccurrences(of: "\"result_unknown\":false", with: "\"result_unknown\":true")
        let device = try await startDevice(first: offlineHome(removals: [unknown]))
        XCTAssertEqual(sheetState(device).removal?.presentation, .resultUnknown)
        XCTAssertEqual(sheetState(device).forgetOffer?.removalEffect, .keepsSentRemoval)

        device.removalHub.scriptForget { base, record, requestID in
            .success(ForgetFixtures.forget(requestID: requestID, base: base, record: record, kept: RemovalFixtures.removalID))
        }
        device.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { device.removals.completionEvents.count == 1 }
        try await deliver(F.snapshot(
            bases: [], removals: [unknown], forgets: [F.json(requestID: try sentRequestID(device), kept: RemovalFixtures.removalID)]
        ), to: device)
        XCTAssertTrue(device.model.snapshot.modules.isEmpty, "the Base and its sensors are out of the list")
        XCTAssertEqual(P.openRemovalsWithoutPowerBase(in: device.model.snapshot).map(\.presentation), [.removedFromListUnconfirmed],
                       "the removal whose command may be with the Power Base is still shown, as what it is now: out of the list, the erase not confirmed -- not cancelled, not done")
        let kept = try XCTUnwrap(P.openRemovalsWithoutPowerBase(in: device.model.snapshot).first)
        XCTAssertEqual(kept.state, .sent, "the hub's job is exactly what it was")
        XCTAssertTrue(kept.powerBaseListRemoved)
        XCTAssertEqual(device.removals.completionEvents.map(\.completion.kind), [.removedFromHubList])
        XCTAssertNotEqual(PowerBaseManagementText.removalTitle(kept.presentation), PowerBaseManagementText.removalTitle(.completed))

        // The hub's own word for it (0.4.1), without the list removal's record (it is dropped
        // after a while): the same thing on screen.
        let marked = RemovalFixtures.json("sent", extra: ",\"list_removed\":true").replacingOccurrences(of: "\"result_unknown\":false", with: "\"result_unknown\":true")
        XCTAssertTrue(marked.contains("list_removed"))
        try await deliver(F.snapshot(bases: [], removals: [marked], forgets: []), to: device)
        XCTAssertEqual(P.openRemovalsWithoutPowerBase(in: device.model.snapshot).map(\.presentation), [.removedFromListUnconfirmed])
        XCTAssertTrue(device.model.snapshot.modules.isEmpty)

        // Registered again: the hub ends that job as superseded and lists the new registration.
        let superseded = RemovalFixtures.json("superseded")
        try await deliver(F.snapshot(
            bases: [F.baseJSON(online: true, moduleCount: 1, record: F.laterRecord)],
            modules: [F.moduleJSON(Self.gasSensor, base: F.base, online: true)], removals: [superseded], forgets: []
        ), to: device)
        var state = sheetState(device)
        XCTAssertEqual(state.availability, .available, "the new registration can be removed: the earlier job is not in its way")
        XCTAssertNil(state.removal)
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: device.model.snapshot).isEmpty)

        // And should a hub still list the earlier job as it was (not superseded yet) next to the
        // new registration: it names another registration, so it is not this Base's job.
        try await deliver(F.snapshot(
            bases: [F.baseJSON(online: true, moduleCount: 1, record: F.laterRecord)],
            modules: [F.moduleJSON(Self.gasSensor, base: F.base, online: true)], removals: [marked], forgets: []
        ), to: device)
        state = sheetState(device)
        XCTAssertEqual(state.availability, .available)
        XCTAssertNil(state.removal, "a job of the earlier registration is never shown as the listed Base's")
        XCTAssertNil(P.badge(for: device.removals.removal(for: F.base, in: device.model.snapshot)))
    }

    // MARK: - A list that is behind the hub's records (the 2026-10-10 review, finding 1)

    /// What a hub before 0.4.1 could send when another request was carried out between its copy
    /// of the Registry and its reading of its records: the Base and its sensors, still listed --
    /// without a registration, because it has none any more -- and the record that took them out.
    private func behindSnapshot(forget: String) -> Data {
        F.snapshot(
            bases: [F.baseJSON(moduleCount: 2, management: "unsupported", record: nil)],
            modules: [F.moduleJSON(Self.gasSensor, base: F.base), F.moduleJSON(Self.dustSensor, base: F.base)],
            forgets: [forget]
        )
    }

    func testAListThatIsBehindTheRecordDoesNotKeepTheRemovedSensorsOnScreenForGood() async throws {
        // Another device takes the Base out of the list; this one only follows the hub.
        let device = try await startDevice(first: offlineHome())
        XCTAssertEqual(device.model.snapshot.modules.count, 2)
        let record = F.json()

        try await deliver(behindSnapshot(forget: record), to: device)
        XCTAssertEqual(device.model.snapshot.modules.count, 2, "the hub still lists them in this snapshot")
        XCTAssertNil(sheetState(device).forgetOffer, "nothing is offered for a Base the hub lists without a registration")

        // The list catches up: empty, with the same record.
        try await deliver(F.snapshot(bases: [], forgets: [record]), to: device)
        XCTAssertTrue(device.model.snapshot.powerBases.isEmpty)
        XCTAssertTrue(device.model.snapshot.modules.isEmpty, "the sensors left the screen: the record seen with the Base still listed was not used up")
        XCTAssertFalse(device.model.isRegistryRecovering, "and nothing is shown as recovering")
        XCTAssertEqual(device.model.dataWait, .noModulesYet)
        XCTAssertNil(sheetState(device).base)
        XCTAssertTrue(device.removals.completionEvents.isEmpty, "no notice: this device did not ask")

        // Still so on every later snapshot.
        try await deliver(F.snapshot(bases: [], forgets: [record]), to: device)
        XCTAssertTrue(device.model.snapshot.modules.isEmpty)
    }

    func testTheSameWhenThisDeviceAskedAndWhenTheSnapshotThatIsBehindIsTheFirstOneItSees() async throws {
        // This device asked; the answer and the snapshot that is behind cross.
        let device = try await startDevice(first: offlineHome())
        carriedOut(device.removalHub)
        device.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { device.removals.completionEvents.count == 1 }
        let own = F.json(requestID: try sentRequestID(device))
        try await deliver(behindSnapshot(forget: own), to: device)
        try await deliver(F.snapshot(bases: [], forgets: [own]), to: device)
        XCTAssertTrue(device.model.snapshot.modules.isEmpty)
        XCTAssertFalse(device.model.isRegistryRecovering)
        XCTAssertEqual(device.removals.completionEvents.count, 1, "told once")

        // An app that connects for the first time while the hub's list is behind.
        let late = try await startDevice(first: behindSnapshot(forget: own))
        XCTAssertEqual(late.model.snapshot.modules.count, 2)
        try await deliver(F.snapshot(bases: [], forgets: [own]), to: late)
        XCTAssertTrue(late.model.snapshot.modules.isEmpty, "the first snapshot being the one that is behind changes nothing")
        XCTAssertFalse(late.model.isRegistryRecovering)
        XCTAssertTrue(late.removals.completionEvents.isEmpty)
    }

    func testAnEarlierRecordNextToANewRegistrationStillKeepsTheNewSensors() async throws {
        // The other half: the record of an earlier registration, the Base registered again.
        let old = F.json()
        let device = try await startDevice(first: F.snapshot(
            bases: [F.baseJSON(online: true, moduleCount: 2, record: F.laterRecord)],
            modules: [F.moduleJSON(Self.gasSensor, base: F.base, online: true), F.moduleJSON(Self.dustSensor, base: F.base, online: true)],
            forgets: [old]
        ))
        XCTAssertEqual(device.model.snapshot.modules.count, 2)
        // The hub starts again and lists nothing for a moment; the old record is still there.
        try await deliver(F.snapshot(bases: [], forgets: [old]), to: device)
        XCTAssertEqual(device.model.snapshot.modules.count, 2, "the earlier record does not explain the new registration's absence: the sensors stay")
        XCTAssertTrue(device.model.isRegistryRecovering)
        // And they are there again when the hub has heard from the Base.
        try await deliver(F.snapshot(
            bases: [F.baseJSON(online: true, moduleCount: 2, record: F.laterRecord)],
            modules: [F.moduleJSON(Self.gasSensor, base: F.base, online: true), F.moduleJSON(Self.dustSensor, base: F.base, online: true)],
            forgets: [old]
        ), to: device)
        XCTAssertEqual(device.model.snapshot.modules.count, 2)
        XCTAssertFalse(device.model.isRegistryRecovering)
    }

    func testAnotherHubStartsFromNothingAlsoAfterASnapshotThatWasBehind() async throws {
        let device = try await startDevice(first: offlineHome())
        try await deliver(behindSnapshot(forget: F.json()), to: device)
        // The user switches to another hub that lists the same identifier under its own
        // registration: what the first hub said is not carried over.
        let otherHub = try PogoSnapshotMapper.decodeSnapshot(from: F.snapshot(
            bases: [F.baseJSON(online: true, moduleCount: 1, record: F.laterRecord)], modules: [F.moduleJSON(Self.gasSensor, base: F.base, online: true)]
        ))
        var evidence = PowerBaseReleaseEvidence()
        XCTAssertEqual(evidence.observe(otherHub), [], "a new source starts with new evidence (AppModel.clearSourceData)")
        device.removals.targetDidChange(RemovalFixtures.target(hubID: RemovalFixtures.hubB))
        device.removals.sourceDidReport(otherHub.powerBaseRemovals, forgets: otherHub.powerBaseForgets, powerBases: otherHub.powerBases, from: .hub(id: RemovalFixtures.hubB))
        XCTAssertNil(device.removals.forgetAction(for: F.base))
        XCTAssertTrue(device.removals.completionEvents.isEmpty)
    }

    // MARK: - A request without an answer, and what becomes of its registration

    func testALostAnswerEndsWhenAnotherDeviceRemovesThatRegistrationAndNeverComesBack() async throws {
        let first = try await startDevice(first: offlineHome())
        let second = try await startDevice(first: offlineHome())
        // The first device's request gets no answer.
        first.removalHub.scriptForget(.failure(.unreachable("timeout")))
        first.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { first.removals.forgetAction(for: F.base) == .resultUnknown }
        XCTAssertEqual(sheetState(first).forgetAction, .resultUnknown)

        // The second device's request is the one the hub carries out.
        carriedOut(second.removalHub)
        second.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { second.removals.completionEvents.count == 1 }
        let done = F.json(requestID: try sentRequestID(second))
        try await deliver(F.snapshot(bases: [], forgets: [done]), to: second)
        try await deliver(F.snapshot(bases: [], forgets: [done]), to: first)
        XCTAssertTrue(first.model.snapshot.modules.isEmpty)
        XCTAssertNil(first.removals.forgetAction(for: F.base), "the open question is over: that registration left the list")
        XCTAssertTrue(first.removals.completionEvents.isEmpty, "and it is not told as this device's doing")

        // The board is registered again and goes offline.
        let again = F.snapshot(
            bases: [F.baseJSON(moduleCount: 1, record: F.laterRecord)], modules: [F.moduleJSON(Self.gasSensor, base: F.base)], forgets: [done]
        )
        try await deliver(again, to: first)
        var state = sheetState(first)
        XCTAssertNil(state.forgetAction, "nothing of the earlier request shows on the new registration")
        XCTAssertEqual(state.forgetOffer?.record, F.laterRecord, "the list removal is offered for the new registration")
        XCTAssertEqual(state.availability, .available, "and its removal is not blocked")
        first.removals.retryForget(of: F.base)
        XCTAssertEqual(first.removalHub.forgets.count, 1, "there is nothing left to send again")

        // A new confirmation is a new request for the new registration.
        carriedOut(first.removalHub)
        first.removals.forgetPowerBase(F.base, record: F.laterRecord)
        try await waitUntil { first.removals.completionEvents.count == 1 }
        guard case let .forget(_, _, _, _, record, requestID) = try XCTUnwrap(first.removalHub.forgets.last) else { return XCTFail() }
        XCTAssertEqual(record, F.laterRecord)
        XCTAssertNotEqual(requestID, try sentRequestID(first, 0))
        state = sheetState(first)
        XCTAssertNil(state.forgetAction)
    }

    func testALateAnswerToARequestThatIsOverChangesNothing() async throws {
        let device = try await startDevice(first: offlineHome())
        // The request is on its way (no answer yet) when the hub already lists another registration.
        device.removalHub.hold()
        device.removalHub.scriptForget(.failure(.staleRecord))
        device.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { device.removalHub.heldCount == 1 }
        XCTAssertEqual(sheetState(device).forgetAction, .requesting)
        let again = F.snapshot(bases: [F.baseJSON(moduleCount: 1, record: F.laterRecord)], modules: [F.moduleJSON(Self.gasSensor, base: F.base)])
        try await deliver(again, to: device)
        XCTAssertNil(sheetState(device).forgetAction, "the Base is listed under another registration: that request is over")
        device.removalHub.release()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(device.removals.forgetAction(for: F.base), "its answer, arriving late, is nobody's")
        XCTAssertTrue(device.removals.completionEvents.isEmpty)
        XCTAssertEqual(sheetState(device).forgetOffer?.record, F.laterRecord)
    }

    func testALostAnswerAlsoEndsWhenThatRegistrationIsReleasedByARemoval() async throws {
        let device = try await startDevice(first: offlineHome())
        device.removalHub.scriptForget(.failure(.unreachable("timeout")))
        device.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { device.removals.forgetAction(for: F.base) == .resultUnknown }
        // The Base came back, and a removal of that registration was carried out (by anyone).
        try await deliver(F.snapshot(bases: [], removals: [RemovalFixtures.json("released")], forgets: []), to: device)
        XCTAssertNil(device.removals.forgetAction(for: F.base))
        XCTAssertTrue(device.model.snapshot.modules.isEmpty)
    }

    func testALostAnswerStaysAnOpenQuestionWhileTheHubSaysNothingAboutIt() async throws {
        let device = try await startDevice(first: offlineHome())
        device.removalHub.scriptForget(.failure(.unreachable("timeout")))
        device.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { device.removals.forgetAction(for: F.base) == .resultUnknown }
        let asked = try sentRequestID(device)
        // The hub starts again: an empty list, no record. Nothing is known.
        try await deliver(F.snapshot(bases: [], forgets: []), to: device)
        XCTAssertEqual(device.removals.forgetAction(for: F.base), .resultUnknown, "silence settles nothing")
        // The same registration is listed again: it was not taken out, and the question is as open as before.
        try await deliver(offlineHome(), to: device)
        XCTAssertEqual(sheetState(device).forgetAction, .resultUnknown)
        device.removalHub.scriptForget { base, record, requestID in .success(ForgetFixtures.forget(requestID: requestID, base: base, record: record)) }
        device.removals.retryForget(of: F.base)
        try await waitUntil { device.removals.completionEvents.count == 1 }
        XCTAssertEqual(try sentRequestID(device, 1), asked, "sent again exactly as it was: the hub carries one request out once")
    }

    func testTheSnapshotAndTheAnswerOfOneRequestInEitherOrderTellItOnce() async throws {
        let device = try await startDevice(first: offlineHome())
        device.removalHub.hold()
        carriedOut(device.removalHub)
        device.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { device.removalHub.heldCount == 1 }
        // The hub's snapshot with this request's record arrives before its answer.
        try await deliver(F.snapshot(bases: [], forgets: [F.json(requestID: try sentRequestID(device))]), to: device)
        XCTAssertEqual(device.removals.completionEvents.map(\.completion.kind), [.removedFromHubList])
        XCTAssertNil(device.removals.forgetAction(for: F.base))
        device.removalHub.release()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(device.removals.completionEvents.count, 1, "the answer that follows is not a second one")
        XCTAssertNil(device.removals.forgetAction(for: F.base))
        // A second tap while nothing is open sends nothing for a Base that is not listed.
        XCTAssertNil(sheetState(device).forgetOffer)
    }

    func testARefusalIsShownUntilReadAlsoOnTheRegistrationThatReplacedItAndEndsWhenTheBaseIsGone() async throws {
        let device = try await startDevice(first: offlineHome())
        device.removalHub.scriptForget(.failure(.staleRecord))
        device.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { device.removals.forgetAction(for: F.base) == .failed(.request(.staleRecord)) }
        let again = F.snapshot(bases: [F.baseJSON(moduleCount: 1, record: F.laterRecord)], modules: [F.moduleJSON(Self.gasSensor, base: F.base)])
        try await deliver(again, to: device)
        XCTAssertEqual(sheetState(device).forgetAction, .failed(.request(.staleRecord)), "what it tells is exactly this: registered again meanwhile")
        XCTAssertEqual(sheetState(device).availability, .available, "it does not stand in the way of removing the Base")
        // The Base leaves the list (another device took the new registration out).
        try await deliver(F.snapshot(bases: [], forgets: [F.json(record: F.laterRecord)]), to: device)
        XCTAssertNil(device.removals.forgetAction(for: F.base))
        // Registered once more: the old refusal does not come back.
        try await deliver(again, to: device)
        XCTAssertNil(sheetState(device).forgetAction)
        XCTAssertEqual(sheetState(device).forgetOffer?.record, F.laterRecord)
    }

    func testARefusalHidesNothingAndALostAnswerIsAnOpenQuestion() async throws {
        let device = try await startDevice(first: offlineHome())
        // The Base came back just then.
        device.removalHub.scriptForget(.failure(.online))
        device.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { device.removals.forgetAction(for: F.base) != .requesting }
        var state = sheetState(device)
        XCTAssertEqual(state.forgetAction, .failed(.request(.online)))
        XCTAssertNotNil(state.base)
        XCTAssertEqual(device.model.snapshot.modules.count, 2, "nothing left the list")
        XCTAssertTrue(device.removals.completionEvents.isEmpty)
        device.removals.dismissForgetFailure(for: F.base)

        // The answer is lost.
        device.removalHub.scriptForget(.failure(.unreachable("timeout")))
        device.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { device.removals.forgetAction(for: F.base) == .resultUnknown }
        state = sheetState(device)
        XCTAssertEqual(state.forgetAction, .resultUnknown)
        XCTAssertEqual(device.model.snapshot.modules.count, 2)
        XCTAssertTrue(device.removals.completionEvents.isEmpty, "not told as done")

        // "다시 확인": the same request; this time the answer arrives.
        carriedOut(device.removalHub)
        device.removals.retryForget(of: F.base)
        try await waitUntil { device.removals.completionEvents.count == 1 }
        XCTAssertEqual(try sentRequestID(device, 1), try sentRequestID(device, 2), "the same request id as the one that got no answer")
        XCTAssertNotEqual(try sentRequestID(device, 0), try sentRequestID(device, 1), "the refused one was another request")
    }

    func testTheHubsWordSettlesALostAnswerAlsoWhileTheSheetIsClosedOrAnotherTabIsShown() async throws {
        let device = try await startDevice(first: offlineHome())
        device.removalHub.scriptForget(.failure(.unreachable("timeout")))
        device.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { device.removals.forgetAction(for: F.base) == .resultUnknown }
        // No sheet, no tab: only the snapshot, as `DevicesView` hands it on for every change.
        try await deliver(F.snapshot(bases: [], forgets: [F.json(requestID: try sentRequestID(device))]), to: device)
        XCTAssertNil(device.removals.forgetAction(for: F.base))
        XCTAssertTrue(device.model.snapshot.modules.isEmpty)
        XCTAssertEqual(device.removals.completionEvents.map(\.completion.kind), [.removedFromHubList])
        XCTAssertEqual(device.removals.notices.waiting.count, 1, "kept for when the tab is on screen")
        XCTAssertTrue(device.removals.notices.shown.isEmpty)
    }

    // MARK: - Registered again

    func testAnEarlierListRemovalNeverHidesOrBlocksTheBaseRegisteredAgain() async throws {
        let device = try await startDevice(first: offlineHome())
        carriedOut(device.removalHub)
        device.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { device.removals.completionEvents.count == 1 }
        let record = F.json(requestID: try sentRequestID(device))
        try await deliver(F.snapshot(bases: [], forgets: [record]), to: device)
        XCTAssertTrue(device.model.snapshot.modules.isEmpty)

        // Registered again: the hub lists it with a new record, and still lists the old list removal.
        let again = F.snapshot(
            bases: [F.baseJSON(online: true, moduleCount: 1, record: F.laterRecord)],
            modules: [F.moduleJSON(Self.gasSensor, base: F.base, online: true)], forgets: [record]
        )
        try await deliver(again, to: device)
        var state = sheetState(device)
        XCTAssertEqual(state.base?.isOnline, true)
        XCTAssertEqual(state.sensorCount, 1)
        XCTAssertEqual(state.availability, .available, "the new registration can be removed like any other: no old state stands in the way")
        XCTAssertNil(state.removal)
        XCTAssertNil(state.forgetOffer, "and it is heard, so nothing else is offered")
        XCTAssertNil(P.badge(for: device.removals.removal(for: F.base, in: device.model.snapshot)))
        XCTAssertEqual(device.removals.completionEvents.count, 1, "nothing is told again")

        // It goes offline: the offer names the NEW registration.
        try await deliver(F.snapshot(
            bases: [F.baseJSON(moduleCount: 1, record: F.laterRecord)], modules: [F.moduleJSON(Self.gasSensor, base: F.base)], forgets: [record]
        ), to: device)
        state = sheetState(device)
        XCTAssertEqual(state.forgetOffer?.record, F.laterRecord)

        // The hub lists nothing for a moment (it is starting again) while the old record is
        // still in its list: that record does not explain the empty list.
        try await deliver(F.snapshot(bases: [], forgets: [record]), to: device)
        XCTAssertEqual(device.model.snapshot.modules.count, 1, "the sensor of the new registration stays")
        XCTAssertTrue(device.model.isRegistryRecovering)
    }

    // MARK: - The app started again, another hub

    func testAnAppStartedAfterwardsShowsWhatTheHubListsAndTellsNothing() async throws {
        // The hub's state after a list removal some device asked for earlier.
        let device = try await startDevice(first: F.snapshot(bases: [], forgets: [F.json()]))
        XCTAssertTrue(device.model.snapshot.powerBases.isEmpty)
        XCTAssertTrue(device.model.snapshot.modules.isEmpty)
        XCTAssertFalse(device.model.isRegistryRecovering)
        XCTAssertNil(sheetState(device).forgetAction)
        XCTAssertTrue(device.removals.completionEvents.isEmpty, "an earlier list removal is no news to an app that did not ask for it in this run")
        XCTAssertTrue(device.removals.notices.waiting.isEmpty)
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: device.model.snapshot).isEmpty)
    }

    func testAnotherHubShowsNothingOfTheRequestAndItsLateAnswer() async throws {
        let device = try await startDevice(first: offlineHome())
        device.removalHub.hold()
        carriedOut(device.removalHub)
        device.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { device.removalHub.heldCount == 1 }
        XCTAssertEqual(sheetState(device).forgetAction, .requesting)

        // The user switches to another hub, which lists a Base with the same identifier and its own
        // registration of it. (`DevicesView` hands the new target and that hub's snapshot on.)
        let otherHub = try PogoSnapshotMapper.decodeSnapshot(from: F.snapshot(
            bases: [F.baseJSON(online: true, moduleCount: 1, record: F.laterRecord)], modules: [F.moduleJSON(Self.gasSensor, base: F.base, online: true)]
        ))
        device.removals.targetDidChange(RemovalFixtures.target(hubID: RemovalFixtures.hubB))
        device.removals.sourceDidReport(otherHub.powerBaseRemovals, forgets: otherHub.powerBaseForgets, from: .hub(id: RemovalFixtures.hubB))
        XCTAssertNil(device.removals.forgetAction(for: F.base))

        device.removalHub.release()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(device.removals.forgetAction(for: F.base), "the first hub's answer is not this hub's")
        XCTAssertTrue(device.removals.completionEvents.isEmpty)
        XCTAssertTrue(device.removals.notices.waiting.isEmpty)
        // What the sheet would show for that Base on the other hub: its own state, nothing carried over.
        let state = P.state(
            identifier: F.base, snapshot: otherHub, target: device.removals.target,
            removal: device.removals.removal(for: F.base, in: otherHub), action: device.removals.action(for: F.base),
            isCurrentStateVerified: true, forgetAction: device.removals.forgetAction(for: F.base)
        )
        XCTAssertEqual(state.base?.record, F.laterRecord)
        XCTAssertNil(state.forgetAction)
        XCTAssertNil(state.removal)
    }

    // MARK: - Two devices on one hub

    func testWhatOneDeviceDoesReachesTheOtherThroughTheHubAndIsNewsOnlyWhereItWasAsked() async throws {
        let first = try await startDevice(first: offlineHome())
        let second = try await startDevice(first: offlineHome())
        XCTAssertEqual(sheetState(second).forgetOffer?.record, F.record, "both devices read the same record")

        carriedOut(first.removalHub)
        first.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { first.removals.completionEvents.count == 1 }
        let after = F.snapshot(bases: [], forgets: [F.json(requestID: try sentRequestID(first))])
        try await deliver(after, to: first)
        // The other device has its management sheet open on that Base: it follows the hub.
        try await deliver(after, to: second)
        XCTAssertTrue(second.model.snapshot.modules.isEmpty)
        XCTAssertNil(sheetState(second).base)
        XCTAssertNil(sheetState(second).forgetOffer)
        XCTAssertTrue(second.removals.completionEvents.isEmpty, "no notice on the device that did not ask")
        XCTAssertTrue(second.removalHub.recorded.isEmpty, "and it sent nothing")
    }

    func testTheOtherDevicesOldConfirmationCannotRemoveTheNewRegistration() async throws {
        let first = try await startDevice(first: offlineHome())
        let second = try await startDevice(first: offlineHome())
        // The second device opened its confirmation for the registration it saw.
        let confirmed = try XCTUnwrap(sheetState(second).forgetOffer).record

        // Meanwhile the first device took the Base out, and the board was registered again.
        carriedOut(first.removalHub)
        first.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { first.removals.completionEvents.count == 1 }
        let again = F.snapshot(
            bases: [F.baseJSON(moduleCount: 1, record: F.laterRecord)], modules: [F.moduleJSON(Self.gasSensor, base: F.base)],
            forgets: [F.json(requestID: try sentRequestID(first))]
        )
        try await deliver(again, to: first)

        // The second device, still on its old screen, confirms: its request names the earlier
        // registration, and the hub refuses exactly that.
        second.removalHub.scriptForget(.failure(.staleRecord))
        second.removals.forgetPowerBase(F.base, record: confirmed)
        try await waitUntil { second.removals.forgetAction(for: F.base) != .requesting }
        guard case let .forget(_, _, _, _, record, _) = try XCTUnwrap(second.removalHub.recorded.first) else { return XCTFail() }
        XCTAssertEqual(record, F.record, "what left the device is the registration its user was shown")
        try await deliver(again, to: second)
        let state = sheetState(second)
        XCTAssertEqual(state.forgetAction, .failed(.request(.staleRecord)))
        XCTAssertEqual(state.base?.record, F.laterRecord, "the new registration is listed, untouched")
        XCTAssertEqual(second.model.snapshot.modules.count, 1)
        XCTAssertTrue(second.removals.completionEvents.isEmpty)
    }

    func testEachDeviceAsksWithItsOwnCredentialAndRequestID() async throws {
        let first = try await startDevice(first: offlineHome())
        let second = try await startDevice(first: offlineHome())
        carriedOut(first.removalHub)
        second.removalHub.scriptForget(.failure(.notListed))
        first.removals.forgetPowerBase(F.base, record: F.record)
        second.removals.forgetPowerBase(F.base, record: F.record)
        try await waitUntil { first.removals.completionEvents.count == 1 }
        try await waitUntil { second.removals.forgetAction(for: F.base) != .requesting }
        guard case let .forget(_, firstToken, _, _, _, firstRequest) = try XCTUnwrap(first.removalHub.recorded.first),
              case let .forget(_, secondToken, _, _, _, secondRequest) = try XCTUnwrap(second.removalHub.recorded.first) else { return XCTFail() }
        XCTAssertNotEqual(firstToken, secondToken, "each device's own token")
        XCTAssertNotEqual(firstRequest, secondRequest, "and its own request id: the hub carries out one of them")
        XCTAssertEqual(second.removals.forgetAction(for: F.base), .failed(.request(.notListed)))
        XCTAssertTrue(second.removals.completionEvents.isEmpty, "the device whose request found the Base already gone tells nothing as its own doing")
    }
}
