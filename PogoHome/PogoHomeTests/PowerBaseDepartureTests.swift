import Foundation
import XCTest
@testable import PogoHome

// A Power Base that is out of the hub's list (firmware repository, docs/power-base-management.md,
// section 15; Linux bridge 0.4.2). `1.3.1` kept the sensors of a Base that was REMOVED -- the
// ordinary removal, completed by the board -- on a device that saw none of it: it was in the
// background, the hub showed the finished job for ten minutes, and when the device came back the
// list was empty and nothing in the snapshot said why. Now the hub names the Bases that are out of
// its list in every snapshot (`power_base_departures`) until they are registered again.
//
// Here: the hub's words are the JSON the hub writes, received through the real
// `LiveSensorDataSource`, `PogoSnapshotMapper` and `AppModel`. "Sixteen minutes later" is the
// snapshot the hub gives at that time -- without the job, which it no longer shows -- and not a
// wait; no real device, hub or clock is involved. The second iPhone is a second `AppModel`.

enum DepartureFixtures {
    /// One entry exactly as the hub writes it. `record`/`reason` are left out when the hub does
    /// not know them (a block an earlier hub stored).
    static func json(_ base: String = ForgetFixtures.base, record: String? = ForgetFixtures.record, reason: String? = "removed") -> String {
        let recordField = record.map { "\"record\":\"\($0)\"," } ?? ""
        let reasonField = reason.map { "\"reason\":\"\($0)\"," } ?? ""
        return "{\"power_base_uuid\":\"\(base)\",\(recordField)\(reasonField)\"since_unix_ms\":1790000100000}"
    }

    nonisolated(unsafe) private static var sequence: Int64 = 1000

    /// A snapshot as Linux bridge 0.4.2 writes it. `departures == nil`: a hub that does not name
    /// the Bases that are out of its list (0.4.1 and earlier: the field is absent).
    /// `minutesLater`: the hub's clock when it wrote this, counted from now.
    static func snapshot(
        bases: [String], modules: [String] = [], removals: [String]? = [], forgets: [String]? = [], departures: [String]? = [],
        minutesLater: Int64 = 0
    ) -> Data {
        sequence += 1
        let generatedAt = Int64(Date().timeIntervalSince1970 * 1000) + minutesLater * 60_000 + sequence
        let removalsField = removals.map { ",\"power_base_removals\":[\($0.joined(separator: ","))]" } ?? ""
        let forgetsField = forgets.map { ",\"power_base_forgets\":[\($0.joined(separator: ","))]" } ?? ""
        let departuresField = departures.map { ",\"power_base_departures\":[\($0.joined(separator: ","))]" } ?? ""
        return Data("""
        {"schema_version":1,"generated_at_unix_ms":\(generatedAt),"registry_generation":\(sequence),"power_bases":[\(bases.joined(separator: ","))],"modules":[\(modules.joined(separator: ","))]\(removalsField)\(forgetsField)\(departuresField)}
        """.utf8)
    }

    /// A removal job of `record`, as the hub writes it.
    static func job(_ state: String, id: String = RemovalFixtures.removalID, base: String = ForgetFixtures.base, record: String = ForgetFixtures.record) -> String {
        RemovalFixtures.json(state, id: id, base: base)
            .replacingOccurrences(of: "\"generation\":\"\(String(repeating: "7e", count: 16))\"", with: "\"generation\":\"\(record)\"")
    }
}

// MARK: - Wire format

final class PowerBaseDepartureWireTests: XCTestCase {
    private typealias F = ForgetFixtures
    private typealias D = DepartureFixtures

    func testTheHubsListIsReadEntryByEntry() throws {
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: D.snapshot(bases: [], departures: [
            D.json(F.base, record: F.record, reason: "removed"),
            D.json(F.otherBase, record: F.laterRecord, reason: "forgotten"),
        ]))
        XCTAssertTrue(snapshot.reportsPowerBaseDepartures)
        XCTAssertEqual(snapshot.powerBaseDepartures.map(\.powerBaseIdentifier), [F.base, F.otherBase])
        XCTAssertEqual(snapshot.powerBaseDepartures.map(\.record), [F.record, F.laterRecord])
        XCTAssertEqual(snapshot.powerBaseDepartures.map(\.reason), [.removed, .forgotten])
        XCTAssertEqual(snapshot.powerBaseDepartures.first?.since, Date(timeIntervalSince1970: 1_790_000_100))
    }

    func testAHubThatDoesNotSayItIsNotTakenToSayNone() throws {
        // Linux bridge 0.4.1: the snapshot ends with `power_base_forgets`.
        let earlier = try PogoSnapshotMapper.decodeSnapshot(from: D.snapshot(bases: [F.baseJSON()], departures: nil))
        XCTAssertFalse(earlier.reportsPowerBaseDepartures)
        XCTAssertTrue(earlier.powerBaseDepartures.isEmpty)
        XCTAssertTrue(earlier.reportsPowerBaseForget, "nothing else of the snapshot depends on the field")
        let none = try PogoSnapshotMapper.decodeSnapshot(from: D.snapshot(bases: [F.baseJSON()], departures: []))
        XCTAssertTrue(none.reportsPowerBaseDepartures)
        XCTAssertTrue(none.powerBaseDepartures.isEmpty)
    }

    func testWhatTheHubDoesNotKnowIsAbsentAndWhatThisAppCannotReadNamesNoBase() throws {
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: D.snapshot(bases: [F.baseJSON(F.otherBase)], departures: [
            D.json(F.base, record: nil, reason: nil),                               // a block an earlier hub stored
            D.json("00124b0001a2b3c6", record: "not-a-record", reason: "exploded"), // a newer hub's words
            D.json("not-a-base"),                                                   // no Base at all
            D.json("00124B0001A2B3C7"),                                             // upper case names the same Base
        ]))
        XCTAssertEqual(snapshot.powerBaseDepartures.map(\.powerBaseIdentifier), [F.base, "00124b0001a2b3c6", "00124b0001a2b3c7"])
        XCTAssertEqual(snapshot.powerBaseDepartures.map(\.record), [nil, nil, F.record])
        XCTAssertEqual(snapshot.powerBaseDepartures.map(\.reason), [nil, nil, .removed])
        XCTAssertEqual(snapshot.powerBases.map(\.hardwareIdentifier), [F.otherBase], "and the rest of the snapshot is read as before")
    }
}

// MARK: - What counts as "gone"

final class PowerBaseDepartureEvidenceTests: XCTestCase {
    private typealias F = ForgetFixtures
    private typealias D = DepartureFixtures

    private func mapped(_ json: Data) throws -> HomeSnapshot { try PogoSnapshotMapper.decodeSnapshot(from: json) }

    func testABaseTheHubNamesAsOutOfItsListIsGoneWithoutAnyJobOrRecord() throws {
        var evidence = PowerBaseReleaseEvidence()
        XCTAssertEqual(evidence.observe(try mapped(D.snapshot(bases: [F.baseJSON(), F.baseJSON(F.otherBase)]))), [])
        // No removal job, no list-removal record: only the hub's word about its list.
        XCTAssertEqual(evidence.observe(try mapped(D.snapshot(bases: [F.baseJSON(F.otherBase)], departures: [D.json()]))), [F.base])
        XCTAssertEqual(evidence.observe(try mapped(D.snapshot(bases: [], departures: [D.json()]))), [F.base], "the other Base's absence is not explained by it")
    }

    func testItIsSaidAnewInEverySnapshotAndNotRememberedFromAnEarlierOne() throws {
        var evidence = PowerBaseReleaseEvidence()
        _ = evidence.observe(try mapped(D.snapshot(bases: [F.baseJSON()])))
        XCTAssertEqual(evidence.observe(try mapped(D.snapshot(bases: [], departures: [D.json()]))), [F.base])
        // Registered again: listed, and the hub no longer names it.
        XCTAssertEqual(evidence.observe(try mapped(D.snapshot(bases: [F.baseJSON(record: F.laterRecord)]))), [])
        // The hub starts again: an empty list, and nothing named. What the hub said two
        // snapshots ago explains nothing now.
        XCTAssertEqual(evidence.observe(try mapped(D.snapshot(bases: []))), [], "an earlier departure is not carried over")
    }

    func testABaseThatIsListedIsListedWhateverElseTheSnapshotSays() throws {
        var evidence = PowerBaseReleaseEvidence()
        _ = evidence.observe(try mapped(D.snapshot(bases: [F.baseJSON()])))
        // A snapshot that should not exist (the hub never lists a Base it names as out).
        XCTAssertEqual(evidence.observe(try mapped(D.snapshot(bases: [F.baseJSON()], departures: [D.json()]))), [])
    }

    func testTheHubsWordDoesNotDependOnWhichRegistrationThisAppLastSaw() throws {
        var evidence = PowerBaseReleaseEvidence()
        // This app last saw the first registration. While it was away the Base was taken out of
        // the list, registered again and removed: the registration that ended last is another.
        _ = evidence.observe(try mapped(D.snapshot(bases: [F.baseJSON(record: F.record)])))
        XCTAssertEqual(evidence.observe(try mapped(D.snapshot(bases: [], departures: [D.json(record: F.laterRecord)]))), [F.base])
        // And without a registration at all (a block an earlier hub stored).
        var other = PowerBaseReleaseEvidence()
        _ = other.observe(try mapped(D.snapshot(bases: [F.baseJSON()])))
        XCTAssertEqual(other.observe(try mapped(D.snapshot(bases: [], departures: [D.json(record: nil, reason: nil)]))), [F.base])
    }

    func testAnEarlierRegistrationsFinishedJobNextToTheNewRegistrationIsStillHistory() throws {
        var evidence = PowerBaseReleaseEvidence()
        // Removed, registered again (another record), and the earlier job still shown: the Base
        // is listed and not named as out. Then the hub starts again and lists nothing for a moment.
        _ = evidence.observe(try mapped(D.snapshot(bases: [F.baseJSON(record: F.laterRecord)], removals: [D.job("completed")])))
        XCTAssertEqual(evidence.observe(try mapped(D.snapshot(bases: [], removals: [D.job("completed")]))), [], "the earlier job is spent; nothing names the Base as out")
    }
}

// MARK: - AppModel: what a device that was away puts on screen

@MainActor
final class AppModelPowerBaseDepartureTests: XCTestCase {
    private typealias F = ForgetFixtures
    private typealias D = DepartureFixtures

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

    /// An app following the hub, paired, connected, with the first snapshot in.
    private func startDevice(first: Data, store: InMemoryHomeConfigurationStore = InMemoryHomeConfigurationStore(language: .korean)) async throws -> Device {
        if settingsHub == nil { settingsHub = FakeSettingsHub() }
        let hub: FakeSettingsHub = settingsHub
        let credentials = InMemoryHubCredentialStore()
        let transport = ControllableSensorAPITransport { first }
        let model = AppModel(
            dataSource: LiveSensorDataSource(
                endpoint: PogoAPIEndpoint(baseURL: RemovalFixtures.url), transport: transport, sleeper: RecordingSleeper(),
                livenessIdleTimeout: 5, periodicRefreshInterval: nil
            ),
            sourceIdentity: .hub(id: hub.hubID),
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
        _ = hub.createCode()
        _ = try await model.sharedSettings.pair(code: "7KQM-3XWD-PA9T", deviceName: "Test \(devices.count)")
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

    /// The hub's answer to a removal request: the job, naming the registration it is about.
    private func answered(_ state: PowerBaseRemoval.State, id: String = RemovalFixtures.removalID, record: String = F.record) -> PowerBaseRemoval {
        var removal = RemovalFixtures.removal(state, id: id)
        removal.record = record
        return removal
    }

    /// One Base with two sensors: the only Base of the home, connected.
    private func home(record: String = F.record, removals: [String] = [], online: Bool = true) -> Data {
        D.snapshot(
            bases: [F.baseJSON(online: online, moduleCount: 2, record: record)],
            modules: [F.moduleJSON(Self.gasSensor, base: F.base, online: online), F.moduleJSON(Self.dustSensor, base: F.base, online: online)],
            removals: removals
        )
    }

    /// What the hub says once that Base's removal is long over: nothing listed, no job shown any
    /// more, the Base named as out of the list.
    private func longAfterTheRemoval(record: String = F.record, minutes: Int64 = 16) -> Data {
        D.snapshot(bases: [], departures: [D.json(record: record)], minutesLater: minutes)
    }

    private func assertNothingIsLeft(_ device: Device, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(device.model.snapshot.modules.isEmpty, "\(message): the sensors are gone", file: file, line: line)
        XCTAssertTrue(device.model.snapshot.powerBases.isEmpty, "\(message): so is the Base", file: file, line: line)
        XCTAssertFalse(device.model.isRegistryRecovering, "\(message): nothing is shown as recovering", file: file, line: line)
    }

    // MARK: The reported defect

    func testADeviceThatSawNothingOfTheRemovalDropsTheSensorsWithTheFirstSnapshotItGets() async throws {
        // B shows the sensors, then is in the background. A removes the last Base; the board
        // releases it and its receipt completes the job; ten minutes later the hub no longer
        // shows that job. B sees none of it and gets its first snapshot sixteen minutes on.
        let b = try await startDevice(first: home())
        XCTAssertEqual(b.model.snapshot.modules.count, 2)
        try await deliver(longAfterTheRemoval(), to: b)
        assertNothingIsLeft(b, "back after sixteen minutes")
        XCTAssertNil(b.removals.removal(for: F.base, in: b.model.snapshot), "and no job is shown for it")
        // The snapshots that follow say the same, and nothing comes back.
        try await deliver(longAfterTheRemoval(minutes: 17), to: b)
        try await deliver(longAfterTheRemoval(minutes: 300), to: b)
        assertNothingIsLeft(b, "hours later")
    }

    func testTheSameSnapshotWithoutTheHubsWordIsStillOnlyAnEmptyList() async throws {
        // What `1.3.1` got from Linux bridge 0.4.1, and what a hub that is starting again says:
        // nothing listed and no reason given. The sensors are kept, as recovering.
        let b = try await startDevice(first: home())
        try await deliver(D.snapshot(bases: [], departures: nil, minutesLater: 16), to: b)
        XCTAssertEqual(b.model.snapshot.modules.count, 2, "an earlier hub does not say why its list is empty")
        XCTAssertTrue(b.model.isRegistryRecovering)
        // A 0.4.2 hub that starts again with nothing out of its list says so too: `[]`.
        let c = try await startDevice(first: home())
        try await deliver(D.snapshot(bases: [], departures: []), to: c)
        XCTAssertEqual(c.model.snapshot.modules.count, 2, "an empty list with nothing named is a hub that is starting")
        XCTAssertTrue(c.model.isRegistryRecovering)
    }

    func testADeviceThatSawTheRemovalBeginAndNeverSawItEnd() async throws {
        // B saw the job pending and sent, then went away before `released` and `completed`.
        let b = try await startDevice(first: home())
        try await deliver(home(removals: [D.job("pending")]), to: b)
        try await deliver(home(removals: [D.job("sent")]), to: b)
        XCTAssertEqual(b.model.snapshot.modules.count, 2, "a command that is only sent removes nothing")
        XCTAssertEqual(b.removals.removal(for: F.base, in: b.model.snapshot)?.state, .sent)
        try await deliver(longAfterTheRemoval(), to: b)
        assertNothingIsLeft(b, "it never saw released or completed")
        XCTAssertNil(b.removals.removal(for: F.base, in: b.model.snapshot), "the job it knew as sent is not shown as anything")
        XCTAssertTrue(PowerBaseManagementPresentation.openRemovalsWithoutPowerBase(in: b.model.snapshot).isEmpty, "and is in no list of requests")
    }

    // MARK: Two devices, both ways round

    func testWhicheverDeviceRemovesTheOtherOneFindsOutWhenItComesBack() async throws {
        let first = try await startDevice(first: home())
        let second = try await startDevice(first: home())

        // Round one: the first device asks for the removal and follows it to the end. The second
        // is in the background the whole time.
        first.removalHub.scriptRequest(.success(answered(.pending)))
        first.removals.requestRemoval(of: F.base)
        try await waitUntil { first.removals.removal(for: F.base, in: first.model.snapshot)?.state == .pending }
        try await deliver(home(removals: [D.job("sent")]), to: first)
        try await deliver(D.snapshot(bases: [], removals: [D.job("released")], departures: [D.json()]), to: first)
        assertNothingIsLeft(first, "the device that removed, at released")
        try await deliver(D.snapshot(bases: [], removals: [D.job("completed")], departures: [D.json()]), to: first)
        assertNothingIsLeft(first, "the device that removed, at completed")
        XCTAssertEqual(second.model.snapshot.modules.count, 2, "(the second device has heard nothing yet)")
        try await deliver(longAfterTheRemoval(), to: second)
        assertNothingIsLeft(second, "the device that was away")
        try await deliver(longAfterTheRemoval(), to: first)
        assertNothingIsLeft(first, "and the first one, sixteen minutes on")

        // The Base is registered again; both devices see it with its sensors.
        try await deliver(home(record: F.laterRecord), to: first)
        try await deliver(home(record: F.laterRecord), to: second)
        XCTAssertEqual(first.model.snapshot.modules.count, 2)
        XCTAssertEqual(second.model.snapshot.modules.count, 2)
        XCTAssertFalse(second.model.isRegistryRecovering)

        // Round two, the other way round: the second device removes the new registration, the
        // first one is away.
        second.removalHub.scriptRequest(.success(answered(.pending, id: RemovalFixtures.otherRemovalID, record: F.laterRecord)))
        second.removals.requestRemoval(of: F.base)
        try await deliver(D.snapshot(
            bases: [], removals: [D.job("completed", id: RemovalFixtures.otherRemovalID, record: F.laterRecord)],
            departures: [D.json(record: F.laterRecord)]
        ), to: second)
        assertNothingIsLeft(second, "the device that removed this time")
        XCTAssertEqual(first.model.snapshot.modules.count, 2, "(the first device has heard nothing yet)")
        try await deliver(longAfterTheRemoval(record: F.laterRecord), to: first)
        assertNothingIsLeft(first, "the device that was away this time")
        XCTAssertNil(first.removals.removal(for: F.base, in: first.model.snapshot), "its own earlier request is not shown for a Base that is gone")
    }

    func testTheDeviceThatAskedAndThenSawNothingMore() async throws {
        // A asks, gets the hub's answer (pending), and is in the background from then on.
        let a = try await startDevice(first: home())
        a.removalHub.scriptRequest(.success(answered(.pending)))
        a.removals.requestRemoval(of: F.base)
        try await waitUntil { a.removals.removal(for: F.base, in: a.model.snapshot)?.state == .pending }
        try await deliver(longAfterTheRemoval(), to: a)
        assertNothingIsLeft(a, "the device that asked")
        XCTAssertTrue(PowerBaseManagementPresentation.openRemovalsWithoutPowerBase(in: a.model.snapshot).isEmpty, "no request is left in the list")
        // Registered again: the new registration is shown with nothing of the old request on it.
        try await deliver(home(record: F.laterRecord), to: a)
        XCTAssertEqual(a.model.snapshot.modules.count, 2)
        XCTAssertNil(a.removals.removal(for: F.base, in: a.model.snapshot), "the earlier registration's request is not the new one's")
    }

    // MARK: One of several Bases

    func testOnlyTheRemovedBaseLeavesAndTheOtherKeepsItsSensorsNamesAndRooms() async throws {
        func both(otherComplete: Bool = true) -> [String] {
            [F.moduleJSON(Self.gasSensor, base: F.base, online: true), F.moduleJSON(Self.dustSensor, base: F.base, online: true)]
                + [otherModule(complete: otherComplete)]
        }
        func otherModule(complete: Bool) -> String {
            // Online without a reading yet: the hub has just started and heard the topology only.
            complete ? F.moduleJSON(Self.otherSensor, base: F.otherBase, online: true)
                : F.moduleJSON(Self.otherSensor, base: F.otherBase, online: true).replacingOccurrences(
                    of: #""readings":\[.*\]"#, with: "\"readings\":[]", options: .regularExpression)
        }
        let store = InMemoryHomeConfigurationStore(language: .korean)
        let b = try await startDevice(
            first: D.snapshot(bases: [F.baseJSON(online: true, moduleCount: 2), F.baseJSON(F.otherBase, online: true, moduleCount: 1, record: F.laterRecord)], modules: both()),
            store: store
        )
        let kept = try XCTUnwrap(b.model.snapshot.modules.first { $0.hardwareIdentifier == Self.otherSensor })
        let room = try XCTUnwrap(b.model.editableRooms.first)
        try await b.model.updateModule(id: kept.id, customName: "창가 센서", roomID: room.id)
        XCTAssertEqual(b.model.snapshot.modules.count, 3)

        // Sixteen minutes later: one Base was removed while B was away.
        try await deliver(D.snapshot(
            bases: [F.baseJSON(F.otherBase, online: true, moduleCount: 1, record: F.laterRecord)], modules: [otherModule(complete: true)],
            departures: [D.json()], minutesLater: 16
        ), to: b)
        XCTAssertEqual(b.model.snapshot.modules.compactMap(\.hardwareIdentifier), [Self.otherSensor])
        XCTAssertEqual(b.model.snapshot.powerBases.map(\.hardwareIdentifier), [F.otherBase])
        XCTAssertEqual(b.model.snapshot.modules.first?.name, "창가 센서", "the other sensor keeps its name")
        XCTAssertEqual(b.model.snapshot.modules.first?.roomID, room.id, "and its room")
        XCTAssertFalse(b.model.isRegistryRecovering)

        // The same on a device whose first snapshot after the removal is an incomplete one (the
        // hub also started again: the other Base's sensor has no reading yet). The removed
        // Base's sensors leave; the other one is kept as it was, as recovering.
        let c = try await startDevice(first: D.snapshot(
            bases: [F.baseJSON(online: true, moduleCount: 2), F.baseJSON(F.otherBase, online: true, moduleCount: 1, record: F.laterRecord)], modules: both()
        ))
        try await deliver(D.snapshot(
            bases: [F.baseJSON(F.otherBase, online: true, moduleCount: 1, record: F.laterRecord)], modules: [otherModule(complete: false)],
            departures: [D.json()], minutesLater: 16
        ), to: c)
        XCTAssertEqual(c.model.snapshot.modules.compactMap(\.hardwareIdentifier), [Self.otherSensor], "only the removed Base's sensors left")
        XCTAssertFalse(try XCTUnwrap(c.model.snapshot.modules.first).readings.isEmpty, "the other sensor still shows its last readings")
        XCTAssertTrue(c.model.isRegistryRecovering, "while the hub has not delivered a reading for it again")
        XCTAssertEqual(c.model.snapshot.powerBases.map(\.hardwareIdentifier), [F.otherBase])
        XCTAssertEqual(c.model.snapshot.powerBaseDepartures.map(\.powerBaseIdentifier), [F.base], "what the hub says about its list is not held back with the sensors")
    }

    // MARK: What must NOT be taken for a removal

    func testAHubThatStartsAgainAfterTheBaseWasRegisteredAgainRemovesNothing() async throws {
        // Removed and registered again while B was away; B then sees the new registration.
        let b = try await startDevice(first: home())
        try await deliver(longAfterTheRemoval(), to: b)
        assertNothingIsLeft(b, "(the removal)")
        try await deliver(home(record: F.laterRecord), to: b)
        XCTAssertEqual(b.model.snapshot.modules.count, 2, "(registered again, with its sensors)")

        // The hub starts again: it lists the Base from its registration alone, no sensor yet --
        // and names nothing as out of its list. The earlier departure is not remembered.
        try await deliver(D.snapshot(bases: [F.baseJSON(moduleCount: 0, record: F.laterRecord)], departures: []), to: b)
        XCTAssertEqual(b.model.snapshot.modules.count, 2, "the sensors of the new registration are kept")
        XCTAssertTrue(b.model.isRegistryRecovering, "as recovering, like after any restart of the hub")
        // And with the earlier registration's finished job still in the hub's list.
        try await deliver(D.snapshot(bases: [F.baseJSON(moduleCount: 0, record: F.laterRecord)], removals: [D.job("completed")], departures: []), to: b)
        XCTAssertEqual(b.model.snapshot.modules.count, 2, "an earlier registration's job does not remove the new one's sensors")
        // The sensors report again.
        try await deliver(home(record: F.laterRecord), to: b)
        XCTAssertEqual(b.model.snapshot.modules.count, 2)
        XCTAssertFalse(b.model.isRegistryRecovering)
    }

    func testAnOrdinaryStartOfTheHubWithAnEmptyListRemovesNothing() async throws {
        let b = try await startDevice(first: home())
        // Nothing listed; the hub names ANOTHER Base as out of its list (one removed long ago).
        try await deliver(D.snapshot(bases: [], departures: [D.json("00124b0001a2b3c9", record: F.laterRecord, reason: "forgotten")]), to: b)
        XCTAssertEqual(b.model.snapshot.modules.count, 2, "another Base being out of the list says nothing about this one")
        XCTAssertTrue(b.model.isRegistryRecovering)
        // The Base's sensors come back as the hub hears them again.
        try await deliver(home(), to: b)
        XCTAssertEqual(b.model.snapshot.modules.count, 2)
        XCTAssertFalse(b.model.isRegistryRecovering)
    }

    func testABaseThatIsListedInTheSameSnapshotIsNotRemoved() async throws {
        let b = try await startDevice(first: home())
        // The hub never writes this; if it did, the list wins.
        try await deliver(D.snapshot(
            bases: [F.baseJSON(online: true, moduleCount: 2)],
            modules: [F.moduleJSON(Self.gasSensor, base: F.base, online: true), F.moduleJSON(Self.dustSensor, base: F.base, online: true)],
            departures: [D.json()]
        ), to: b)
        XCTAssertEqual(b.model.snapshot.modules.count, 2)
        XCTAssertFalse(b.model.isRegistryRecovering)
    }

    // MARK: List removal, registered again, then removed

    func testTakenOutOfTheListThenRegisteredAgainThenRemovedAllUnseen() async throws {
        // B last saw the first registration. While it was away: taken out of the list
        // (forgotten), registered again, removed the ordinary way, and sixteen minutes passed.
        let b = try await startDevice(first: home())
        try await deliver(D.snapshot(bases: [], departures: [D.json(record: F.laterRecord, reason: "removed")], minutesLater: 16), to: b)
        assertNothingIsLeft(b, "the registration that ended last is not the one this device saw")

        // A device that followed along sees the same end.
        let a = try await startDevice(first: home())
        try await deliver(D.snapshot(bases: [], forgets: [F.json()], departures: [D.json(reason: "forgotten")]), to: a)
        assertNothingIsLeft(a, "taken out of the list")
        try await deliver(home(record: F.laterRecord), to: a)
        XCTAssertEqual(a.model.snapshot.modules.count, 2, "registered again: the sensors of the new registration")
        try await deliver(D.snapshot(
            bases: [], removals: [D.job("completed", record: F.laterRecord)], forgets: [], departures: [D.json(record: F.laterRecord)]
        ), to: a)
        assertNothingIsLeft(a, "the new registration removed")
        try await deliver(D.snapshot(bases: [], departures: [D.json(record: F.laterRecord)], minutesLater: 16), to: a)
        assertNothingIsLeft(a, "sixteen minutes on")
    }

    // MARK: Nothing is kept of it

    func testOnceTheBaseIsListedAgainNothingOfTheDepartureIsLeft() async throws {
        let b = try await startDevice(first: home())
        try await deliver(longAfterTheRemoval(), to: b)
        assertNothingIsLeft(b, "(removed)")
        XCTAssertEqual(b.model.snapshot.powerBaseDepartures.map(\.powerBaseIdentifier), [F.base], "the screen's snapshot says what the hub said")
        // Listed again: shown at once, and the snapshot on screen names nothing as out.
        try await deliver(home(record: F.laterRecord), to: b)
        XCTAssertEqual(b.model.snapshot.modules.count, 2)
        XCTAssertTrue(b.model.snapshot.powerBaseDepartures.isEmpty)
        XCTAssertFalse(b.model.isRegistryRecovering)
    }
}
