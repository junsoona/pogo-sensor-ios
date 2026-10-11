import Foundation
import XCTest
@testable import PogoHome

// An older snapshot must not be applied after a newer one (firmware repository,
// docs/power-base-management.md, section 16; Linux bridge 0.5.0). The app follows the hub over
// two connections at once -- answers to `GET /api/v1/snapshot` and events on `GET /api/v1/events`
// -- so what arrives later is not always what the hub said later. `1.3.2` applied whatever
// arrived: an answer that was on its way while the hub removed a Base and somebody registered it
// again, delivered after the event that showed the new registration, took the screen back.
//
// Here: the hub is `OrderedHub`, which numbers its snapshots as the bridge does (one stream id
// per run, one number per snapshot in the order it MAKES them). Its words reach the app through
// the real `LiveSensorDataSource` (its connect `GET`, its event stream, `AppModel`'s periodic
// `GET`), `PogoSnapshotMapper` and `AppModel`. "An answer that arrives late" is a `GET` the test
// holds back and then answers with a snapshot the hub made earlier; no clock is involved and
// nothing is waited for. No real hub, network or device.

/// A hub that numbers its snapshots (Linux bridge 0.5.0): `snapshot_stream` per run,
/// `snapshot_sequence` per snapshot, in the order they are made.
actor OrderedHub {
    private var stream: String
    private var sequence: Int64 = 0
    /// What the hub lists now, as a snapshot body without the two order fields.
    private var state: Data
    /// `false`: a hub that does not say where its snapshots stand (0.4.2 and earlier).
    private let numbers: Bool
    private var holdsNext = 0
    private var held: [CheckedContinuation<Data, Never>] = []
    private(set) var answeredCount = 0

    init(state: Data, stream: String = String(repeating: "5a", count: 16), numbers: Bool = true) {
        self.state = state
        self.stream = stream
        self.numbers = numbers
    }

    func setState(_ json: Data) { state = json }

    /// The hub is started again: another stream, and the numbers start at 1.
    func restart(state json: Data, stream new: String = String(repeating: "5b", count: 16)) {
        state = json
        stream = new
        sequence = 0
    }

    /// A snapshot of the present state, made NOW: it has the next number, whenever it is delivered.
    func make() -> Data { number(state) }

    private func number(_ json: Data) -> Data {
        guard numbers else { return json }
        sequence += 1
        var text = String(decoding: json, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(text.hasSuffix("}"), "a JSON object")
        text.removeLast()
        return Data((text + ",\"snapshot_stream\":\"\(stream)\",\"snapshot_sequence\":\(sequence)}").utf8)
    }

    /// The next `count` `GET`s are not answered until `release(with:)`.
    func holdNext(_ count: Int = 1) { holdsNext += count }
    var heldCount: Int { held.count }

    /// The answer to one `GET`: made when it is answered -- unless the test holds it back.
    func answerGET() async -> Data {
        if holdsNext > 0 {
            holdsNext -= 1
            return await withCheckedContinuation { held.append($0) }
        }
        answeredCount += 1
        return make()
    }

    /// The `GET`s that are waiting are answered with `answer`: a snapshot this hub made earlier.
    func release(with answer: Data) {
        let waiting = held
        held = []
        answeredCount += waiting.count
        waiting.forEach { $0.resume(returning: answer) }
    }
}

// MARK: - The rule

final class HubSnapshotOrderingTests: XCTestCase {
    private let runA = String(repeating: "5a", count: 16)
    private let runB = String(repeating: "5b", count: 16)
    private let runC = String(repeating: "5c", count: 16)

    private func delivered(_ stream: String?, _ sequence: Int64 = 1, asked: UInt64? = nil) -> SnapshotDelivery {
        SnapshotDelivery(hubOrder: stream.map { HubSnapshotOrder(stream: $0, sequence: sequence) }, requestOrdinal: asked)
    }

    func testWithinOneRunOnlyALargerNumberIsApplied() {
        var ordering = HubSnapshotOrdering()
        XCTAssertTrue(ordering.admits(delivered(runA, 3, asked: 1), now: 1), "the first snapshot is applied, whatever its number")
        XCTAssertTrue(ordering.admits(delivered(runA, 4, asked: 2), now: 2))
        XCTAssertTrue(ordering.admits(delivered(runA, 9, asked: 2), now: 3), "numbers may be skipped: other clients got those")
        XCTAssertFalse(ordering.admits(delivered(runA, 8, asked: 4), now: 4), "an older one that arrives later -- however late it was asked for")
        XCTAssertFalse(ordering.admits(delivered(runA, 9, asked: 5), now: 5), "the same one again")
        XCTAssertFalse(ordering.admits(delivered(runA, 1, asked: 6), now: 6))
        XCTAssertTrue(ordering.admits(delivered(runA, 10, asked: 1), now: 7), "the order is the hub's number, not when it was asked for")
        XCTAssertEqual(ordering.highestSequence, 10)
        XCTAssertEqual(ordering.stream, runA)
    }

    func testAHubThatDoesNotSayIsFollowedInTheOrderItsSnapshotsArrive() {
        var ordering = HubSnapshotOrdering()
        for ordinal in UInt64(1)...4 {
            XCTAssertTrue(ordering.admits(delivered(nil, asked: ordinal), now: ordinal), "nothing to decide from: applied as it comes")
        }
        XCTAssertNil(ordering.stream)
        // Also after a run that did say: a hub that was put back to an earlier version.
        XCTAssertTrue(ordering.admits(delivered(runA, 7, asked: 5), now: 5))
        XCTAssertTrue(ordering.admits(delivered(nil, asked: 6), now: 6))
        XCTAssertFalse(ordering.admits(delivered(runA, 6, asked: 7), now: 7), "what was said of that run still holds for its snapshots")
    }

    func testAnotherRunIsFollowedWhenItWasAskedForAfterThePresentOneWasSeen() {
        var ordering = HubSnapshotOrdering()
        XCTAssertTrue(ordering.admits(delivered(runA, 40, asked: 1), now: 1))
        // The hub was started again; the app reconnects (request 2) and gets run B's first snapshot.
        XCTAssertTrue(ordering.admits(delivered(runB, 1, asked: 2), now: 2), "a smaller number of another run is not an older snapshot")
        XCTAssertEqual(ordering.stream, runB)
        XCTAssertTrue(ordering.admits(delivered(runB, 2, asked: 3), now: 3))
        XCTAssertFalse(ordering.admits(delivered(runB, 2, asked: 4), now: 4))
    }

    func testAnAnswerAskedForBeforeThePresentRunWasSeenIsNotApplied() {
        var ordering = HubSnapshotOrdering()
        XCTAssertTrue(ordering.admits(delivered(runA, 40, asked: 1), now: 1))
        // Request 2 (a poll) is on its way when the hub is started again. Request 3 (the
        // reconnect) is answered by run B first.
        XCTAssertTrue(ordering.admits(delivered(runB, 1, asked: 3), now: 3))
        XCTAssertFalse(ordering.admits(delivered(runA, 41, asked: 2), now: 3), "run A's answer to request 2 arrives now: asked for before run B was seen")
        XCTAssertEqual(ordering.stream, runB, "and the app still follows run B")
        XCTAssertTrue(ordering.admits(delivered(runB, 2, asked: 4), now: 4))
        // An event of the old run's stream that was still in a buffer.
        XCTAssertFalse(ordering.admits(delivered(runA, 42, asked: 1), now: 4))
    }

    func testNothingLocksTheAppOut() {
        var ordering = HubSnapshotOrdering()
        XCTAssertTrue(ordering.admits(delivered(runA, 5, asked: 1), now: 1))
        XCTAssertTrue(ordering.admits(delivered(runB, 1, asked: 2), now: 2))
        // A third run answers a request that was started before run B was seen (it took long to
        // connect): not applied -- it cannot be told from an earlier run's answer.
        XCTAssertFalse(ordering.admits(delivered(runC, 1, asked: 2), now: 3))
        // The very next request is a later one, and run C is followed from there.
        XCTAssertTrue(ordering.admits(delivered(runC, 2, asked: 4), now: 4))
        XCTAssertEqual(ordering.stream, runC)
        // And should the app ever have taken the wrong run for the present one, the live run's
        // next answer to a later request puts that right.
        XCTAssertTrue(ordering.admits(delivered(runB, 9, asked: 5), now: 5))
        XCTAssertEqual(ordering.stream, runB)
    }

    func testASnapshotThatCameFromNoRequestIsTakenAsItComes() {
        var ordering = HubSnapshotOrdering()
        XCTAssertTrue(ordering.admits(delivered(runA, 5), now: 0))
        XCTAssertTrue(ordering.admits(delivered(runB, 1), now: 0), "no ordinal: nothing says it was asked for before")
        XCTAssertFalse(ordering.admits(delivered(runB, 1), now: 0), "within a run the hub's number still decides")
    }

    @MainActor
    func testTheRequestClockOnlyCountsUp() {
        let before = SnapshotRequestClock.now
        let first = SnapshotRequestClock.next()
        let second = SnapshotRequestClock.next()
        XCTAssertGreaterThan(first, before)
        XCTAssertGreaterThan(second, first)
        XCTAssertEqual(SnapshotRequestClock.now, second, "what was handed out last: every later request has a larger one")
    }
}

// MARK: - Wire format

final class SnapshotOrderWireTests: XCTestCase {
    private typealias F = ForgetFixtures
    private typealias D = DepartureFixtures

    private func snapshot(appending fields: String) throws -> HomeSnapshot {
        var text = String(decoding: D.snapshot(bases: [F.baseJSON()]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        text.removeLast()
        return try PogoSnapshotMapper.decodeSnapshot(from: Data((text + fields + "}").utf8))
    }

    func testTheHubsTwoFieldsAreReadFromTheEndOfTheSnapshot() throws {
        let stream = String(repeating: "5a", count: 16)
        let read = try snapshot(appending: ",\"settings_api\":1,\"settings_state\":\"ready\",\"settings_revision\":\"r-1\",\"snapshot_stream\":\"\(stream)\",\"snapshot_sequence\":41")
        XCTAssertEqual(read.delivery.hubOrder, HubSnapshotOrder(stream: stream, sequence: 41))
        XCTAssertNil(read.delivery.requestOrdinal, "the mapper knows nothing of requests")
        XCTAssertEqual(read.hubSettings?.revision, "r-1", "and the rest is read as before")
        XCTAssertEqual(read.requested(at: 7).delivery.requestOrdinal, 7)
        XCTAssertEqual(read.requested(at: 7).delivery.hubOrder, read.delivery.hubOrder)
    }

    func testAHubThatDoesNotSayAndAWordThatIsNoOrderAreTheSame() throws {
        XCTAssertNil(try snapshot(appending: "").delivery.hubOrder, "Linux bridge 0.4.2 and earlier")
        let stream = String(repeating: "5a", count: 16)
        for fields in [
            ",\"snapshot_stream\":\"\(stream)\"",                                  // no number
            ",\"snapshot_sequence\":3",                                              // no stream
            ",\"snapshot_stream\":\"not-a-stream\",\"snapshot_sequence\":3",
            ",\"snapshot_stream\":\"\(stream.uppercased())\",\"snapshot_sequence\":3",
            ",\"snapshot_stream\":\"\(stream)\",\"snapshot_sequence\":0",
            ",\"snapshot_stream\":\"\(stream)\",\"snapshot_sequence\":-4",
        ] {
            XCTAssertNil(try snapshot(appending: fields).delivery.hubOrder, fields)
        }
        XCTAssertThrowsError(try snapshot(appending: ",\"snapshot_stream\":\"\(stream)\",\"snapshot_sequence\":\"3\""), "a number that is a string is not this API")
    }

    /// How a snapshot arrived is not part of what it says: the screen is not redrawn, and two
    /// snapshots are not different, because one of them has a later number.
    func testHowASnapshotArrivedTakesNoPartInComparingIt() throws {
        let stream = String(repeating: "5a", count: 16)
        let json = D.snapshot(bases: [F.baseJSON()])
        func read(_ sequence: Int) throws -> HomeSnapshot {
            var text = String(decoding: json, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            text.removeLast()
            return try PogoSnapshotMapper.decodeSnapshot(from: Data((text + ",\"snapshot_stream\":\"\(stream)\",\"snapshot_sequence\":\(sequence)}").utf8))
        }
        let first = try read(1), second = try read(2).requested(at: 99)
        XCTAssertNotEqual(first.delivery.hubOrder, second.delivery.hubOrder)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.hashValue, second.hashValue)
        XCTAssertEqual(first, try PogoSnapshotMapper.decodeSnapshot(from: json), "nor whether the hub said it at all")
    }
}

// MARK: - Which request brought a snapshot

@MainActor
final class LiveSourceRequestOrdinalTests: XCTestCase {
    private typealias F = ForgetFixtures
    private typealias D = DepartureFixtures

    /// Every snapshot the live source hands on says which of this app's requests brought it:
    /// the connect `GET`, the event stream (one ordinal for all of its events, taken when the
    /// stream was opened), a poll -- in the order those requests were STARTED.
    func testEverySnapshotCarriesTheOrdinalOfTheRequestThatBroughtIt() async throws {
        let hub = OrderedHub(state: D.snapshot(bases: [F.baseJSON()]))
        let transport = ControllableSensorAPITransport { await hub.answerGET() }
        let source = LiveSensorDataSource(
            endpoint: PogoAPIEndpoint(baseURL: RemovalFixtures.url), transport: transport, sleeper: RecordingSleeper(),
            livenessIdleTimeout: 5, periodicRefreshInterval: nil
        )
        let before = SnapshotRequestClock.now
        var received: [HomeSnapshot] = []
        let reading = Task { @MainActor in
            for await snapshot in source.updates() { received.append(snapshot) }
        }
        defer { reading.cancel() }
        try await waitUntil { received.count == 1 }
        try await waitUntil { await transport.hasOpenEventStream }
        for _ in 0..<2 {
            let made = await hub.make()
            await transport.sendLines(PogoAPIFixtures.sseSnapshotEvent(json: made))
        }
        try await waitUntil { received.count == 3 }
        let polled = try await source.currentSnapshot()

        let connect = try XCTUnwrap(received[0].delivery.requestOrdinal)
        let firstEvent = try XCTUnwrap(received[1].delivery.requestOrdinal)
        let secondEvent = try XCTUnwrap(received[2].delivery.requestOrdinal)
        let poll = try XCTUnwrap(polled.delivery.requestOrdinal)
        XCTAssertGreaterThan(connect, before, "the connect GET was started after everything before it")
        XCTAssertGreaterThan(firstEvent, connect, "the event stream was opened after the connect GET was asked")
        XCTAssertEqual(firstEvent, secondEvent, "every event of one stream was asked for when the stream was opened")
        XCTAssertGreaterThan(poll, firstEvent, "a poll that is asked later has a larger ordinal")
        XCTAssertEqual(received.map(\.delivery.hubOrder?.sequence), [1, 2, 3], "and each carries the hub's own number")
        XCTAssertEqual(polled.delivery.hubOrder?.sequence, 4)
    }

    /// The ordinal is the request's START: a poll that was asked before an event stream was
    /// opened keeps the smaller ordinal, however late its answer arrives.
    func testAnAnswerThatArrivesLateKeepsTheOrdinalOfWhenItWasAsked() async throws {
        let hub = OrderedHub(state: D.snapshot(bases: [F.baseJSON()]))
        let transport = ControllableSensorAPITransport { await hub.answerGET() }
        let source = LiveSensorDataSource(
            endpoint: PogoAPIEndpoint(baseURL: RemovalFixtures.url), transport: transport, sleeper: RecordingSleeper(),
            livenessIdleTimeout: 5, periodicRefreshInterval: nil
        )
        await hub.holdNext()
        let slow = Task { @MainActor in try await source.currentSnapshot() }
        try await waitUntil { await hub.heldCount == 1 }
        let later = try await source.currentSnapshot()
        let old = await hub.make()
        await hub.release(with: old)
        let late = try await slow.value
        let askedFirst = try XCTUnwrap(late.delivery.requestOrdinal), askedSecond = try XCTUnwrap(later.delivery.requestOrdinal)
        XCTAssertLessThan(askedFirst, askedSecond, "asked first, answered last: still the earlier request")
    }
}

// MARK: - The real receive path

@MainActor
final class AppModelSnapshotOrderTests: XCTestCase {
    private typealias F = ForgetFixtures
    private typealias D = DepartureFixtures

    private static let gasSensor = "744dbdfffe65d357"
    private static let dustSensor = "744dbdfffe65d07a"
    /// Fast enough that a poll is always "about to be asked"; the tests never wait for a time.
    private static let pollInterval = 0.02

    private final class Device {
        let hub: OrderedHub
        let transport: ControllableSensorAPITransport
        let model: AppModel
        init(hub: OrderedHub, transport: ControllableSensorAPITransport, model: AppModel) {
            self.hub = hub
            self.transport = transport
            self.model = model
        }
    }

    private var devices: [Device] = []

    override func tearDown() async throws {
        devices.forEach { $0.model.stop() }
        devices = []
    }

    private func source(_ hub: OrderedHub, polls: Bool) -> (ControllableSensorAPITransport, LiveSensorDataSource) {
        let transport = ControllableSensorAPITransport { await hub.answerGET() }
        return (transport, LiveSensorDataSource(
            endpoint: PogoAPIEndpoint(baseURL: RemovalFixtures.url), transport: transport, sleeper: RecordingSleeper(),
            livenessIdleTimeout: 5, periodicRefreshInterval: polls ? Self.pollInterval : nil
        ))
    }

    /// An app following `hub`: connected (its connect `GET` answered, its event stream open), and
    /// -- with `polls` -- asking for a snapshot again and again besides.
    private func startDevice(_ hub: OrderedHub, polls: Bool = true, identity: SensorSourceIdentity = .hub(id: String(repeating: "a", count: 32))) async throws -> Device {
        let (transport, live) = source(hub, polls: polls)
        let model = AppModel(
            dataSource: live, sourceIdentity: identity, sourceAddress: RemovalFixtures.url,
            configurationStore: InMemoryHomeConfigurationStore(language: .korean), language: .korean
        )
        let device = Device(hub: hub, transport: transport, model: model)
        devices.append(device)
        model.start()
        try await waitUntil { model.lastSyncAt != nil }
        try await waitUntil { await transport.hasOpenEventStream }
        await transport.sendLine(": heartbeat")
        try await waitUntil { model.connectionStatus == .connected }
        return device
    }

    /// The hub's state changes and it says so on the event stream: a snapshot made now.
    private func event(_ device: Device, state: Data, expecting condition: @escaping @MainActor () -> Bool) async throws {
        await device.hub.setState(state)
        let made = await device.hub.make()
        await device.transport.sendLines(PogoAPIFixtures.sseSnapshotEvent(json: made))
        try await waitUntil(condition)
    }

    /// The next poll is asked and not answered yet. Returns once it is on its way. The app asks
    /// one poll at a time, so until it is released nothing but the events a test sends reaches
    /// the app: the order in which things arrive is the test's, not a race.
    private func holdAPoll(_ device: Device) async throws {
        await device.hub.holdNext()
        try await waitUntil { await device.hub.heldCount == 1 }
    }

    /// The poll that was held back is answered -- with `answer`, which the hub made earlier --
    /// and the app has dealt with it.
    private func release(_ device: Device, with answer: Data, leftOut: Int) async throws {
        await device.hub.release(with: answer)
        try await waitUntil { device.model.staleSnapshotCount == leftOut }
    }

    /// The polls that follow were asked, answered and applied.
    private func letPollsThrough(_ device: Device) async throws {
        let answered = await device.hub.answeredCount
        try await waitUntil { await device.hub.answeredCount >= answered + 3 }
    }

    // One Base with two sensors, registered under `record`.
    private func home(record: String = F.record, sensors: [String] = [gasSensor, dustSensor], removals: [String] = [], settings: String? = nil) -> Data {
        withSettings(D.snapshot(
            bases: [F.baseJSON(online: true, moduleCount: sensors.count, record: record)],
            modules: sensors.map { F.moduleJSON($0, base: F.base, online: true) }, removals: removals
        ), settings)
    }

    /// The Base is out of the list: its registration `record` ended and it was not registered again.
    private func removed(record: String = F.record, removals: [String] = []) -> Data {
        D.snapshot(bases: [], removals: removals, departures: [D.json(record: record)])
    }

    private func withSettings(_ json: Data, _ revision: String?) -> Data {
        guard let revision else { return json }
        var text = String(decoding: json, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        text.removeLast()
        return Data((text + ",\"settings_api\":1,\"settings_state\":\"ready\",\"settings_revision\":\"\(revision)\"}").utf8)
    }

    private func assertShowsTheHome(_ device: Device, record: String, sensors: Int = 2, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(device.model.snapshot.powerBases.map(\.record), [record], "\(message): the Base, under that registration", file: file, line: line)
        XCTAssertEqual(device.model.snapshot.modules.count, sensors, "\(message): its sensors", file: file, line: line)
        XCTAssertFalse(device.model.isRegistryRecovering, "\(message): nothing is shown as recovering", file: file, line: line)
    }

    // MARK: The reviewed order

    /// The review's order (`repro_departure_order.swift`), through the path the app really takes:
    /// the Base is removed, somebody registers it again, an event shows the new registration --
    /// and then the answer to a poll arrives that the hub made BEFORE the new registration: "not
    /// listed, the earlier registration is out of the list". `1.3.2` judged the new
    /// registration's Base removed.
    func testAnOldAnswerAfterTheEventOfANewRegistrationDoesNotTakeTheBaseAway() async throws {
        let hub = OrderedHub(state: home(record: F.record))
        let device = try await startDevice(hub)
        assertShowsTheHome(device, record: F.record, "at first")
        // A poll is asked, and its answer is slow.
        try await holdAPoll(device)
        try await event(device, state: removed()) { device.model.snapshot.powerBases.isEmpty }
        XCTAssertTrue(device.model.snapshot.modules.isEmpty, "the removal is on screen")
        // The hub answers that poll now: what is so at this moment...
        let old = await hub.make()
        // ...and before the answer arrives the Base is registered again, and an event says so.
        try await event(device, state: home(record: F.laterRecord)) { device.model.snapshot.modules.count == 2 }
        assertShowsTheHome(device, record: F.laterRecord, "the new registration")
        XCTAssertEqual(device.model.staleSnapshotCount, 0, "so far everything arrived in the order it was made")

        try await release(device, with: old, leftOut: 1)
        assertShowsTheHome(device, record: F.laterRecord, "after the old answer arrived")
        try await letPollsThrough(device)
        assertShowsTheHome(device, record: F.laterRecord, "and with the polls that follow")
        XCTAssertEqual(device.model.staleSnapshotCount, 1, "exactly the one old answer was left out")
    }

    /// What the review printed, step by step, with its own JSON (no sensors, the fields in its
    /// order) -- numbered as a hub makes them and delivered through the app.
    func testTheReviewsOwnSnapshotsInTheReviewsOrder() async throws {
        func reviewed(listed: Bool, record: String, departure: Bool, time: Int64 = 1_790_000_000_000) -> Data {
            let bases = listed ? "{\"uuid\":\"\(F.base)\",\"online\":true,\"module_count\":0,\"online_module_count\":0,\"management\":\"supported\",\"record\":\"\(record)\"}" : ""
            let departures = departure ? "{\"power_base_uuid\":\"\(F.base)\",\"record\":\"\(record)\",\"reason\":\"removed\",\"since_unix_ms\":1790000000000}" : ""
            return Data("{\"schema_version\":1,\"generated_at_unix_ms\":\(time),\"registry_generation\":1,\"power_bases\":[\(bases)],\"modules\":[],\"power_base_removals\":[],\"power_base_forgets\":[],\"power_base_departures\":[\(departures)]}".utf8)
        }
        let old = String(repeating: "1", count: 32), new = String(repeating: "2", count: 32)
        var listed: Bool { !(devices.last?.model.snapshot.powerBases.isEmpty ?? true) }

        let hub = OrderedHub(state: reviewed(listed: true, record: old, departure: false))
        let device = try await startDevice(hub)
        XCTAssertTrue(listed)
        try await holdAPoll(device)
        // "missed removal, sixteen minutes later: removed=true"
        try await event(device, state: reviewed(listed: false, record: old, departure: true, time: 1_790_000_000_000 + 16 * 60_000)) { device.model.snapshot.powerBases.isEmpty }
        // The delayed GET is answered by the hub now: before the re-registration.
        let delayed = await hub.make()
        // "new registration: removed=false"
        try await event(device, state: reviewed(listed: true, record: new, departure: false)) { device.model.snapshot.powerBases.first?.record == new }
        // "old GET after new registration SSE: new registration marked removed=..." -- false now.
        try await release(device, with: delayed, leftOut: 1)
        XCTAssertEqual(device.model.snapshot.powerBases.map(\.record), [new], "the new registration is not taken for removed")
        // "next current snapshot: removed=false"
        try await letPollsThrough(device)
        XCTAssertEqual(device.model.snapshot.powerBases.map(\.record), [new])
    }

    // MARK: The other orders

    func testAnOldAnswerAfterANewerEventChangesNothingOnScreen() async throws {
        let hub = OrderedHub(state: home())
        let device = try await startDevice(hub)
        try await holdAPoll(device)
        let old = await hub.make()   // two sensors
        // One sensor is taken off the Base; the hub says so at once.
        try await event(device, state: home(sensors: [Self.gasSensor])) { device.model.snapshot.modules.count == 1 }
        try await release(device, with: old, leftOut: 1)
        assertShowsTheHome(device, record: F.record, sensors: 1, "the sensor that was taken off is not back")
    }

    func testAnOldListAfterTheSnapshotOfACompletedRemovalDoesNotBringTheBaseBack() async throws {
        let hub = OrderedHub(state: home())
        let device = try await startDevice(hub)
        try await holdAPoll(device)
        let old = await hub.make()   // the Base and its sensors, listed
        try await event(device, state: removed(removals: [D.job("completed")])) { device.model.snapshot.powerBases.isEmpty }
        try await release(device, with: old, leftOut: 1)
        XCTAssertTrue(device.model.snapshot.powerBases.isEmpty, "the removed Base is not listed again")
        XCTAssertTrue(device.model.snapshot.modules.isEmpty, "nor its sensors")
        XCTAssertEqual(device.model.snapshot.powerBaseRemovals.map(\.state), [.completed], "and the job is as the newer snapshot said")
        XCTAssertFalse(device.model.isRegistryRecovering)
    }

    func testTheSameHubIsFollowedAcrossAReconnect() async throws {
        let hub = OrderedHub(state: home())
        let device = try await startDevice(hub, polls: false)
        try await event(device, state: home(sensors: [Self.gasSensor])) { device.model.snapshot.modules.count == 1 }
        // The event stream ends; the app connects again: a `GET`, then a new stream. The hub is
        // the same run, and goes on counting.
        let streams = await device.transport.eventStreamOpenCount
        await hub.setState(home())
        await device.transport.finishCurrentEventStream()
        try await waitUntil { await device.transport.hasOpenEventStream(after: streams) }
        try await waitUntil { device.model.snapshot.modules.count == 2 }
        try await event(device, state: home(sensors: [Self.dustSensor])) { device.model.snapshot.modules.count == 1 }
        XCTAssertEqual(device.model.staleSnapshotCount, 0, "nothing of a reconnect to the same run is left out")
    }

    func testARestartedHubIsFollowedAndTheEarlierRunsLateAnswerIsNot() async throws {
        let hub = OrderedHub(state: home())
        let device = try await startDevice(hub)
        try await letPollsThrough(device)   // the run's numbers are well past 1
        // A poll is on its way when the hub is started again.
        try await holdAPoll(device)
        let earlierRun = await hub.make()   // the earlier run: the Base and two sensors
        XCTAssertEqual(device.model.staleSnapshotCount, 0, "(polls alone arrive in the order they were made)")
        let streams = await device.transport.eventStreamOpenCount
        await hub.restart(state: home(sensors: [Self.gasSensor]))
        await device.transport.finishCurrentEventStream()
        // The app connects again and gets the new run's first snapshot: number 1.
        try await waitUntil { await device.transport.hasOpenEventStream(after: streams) }
        try await waitUntil { device.model.snapshot.modules.count == 1 }
        XCTAssertEqual(device.model.staleSnapshotCount, 0, "a smaller number of another run is not an older snapshot")

        try await release(device, with: earlierRun, leftOut: 1)
        assertShowsTheHome(device, record: F.record, sensors: 1, "the earlier run's answer was asked for before the new run was seen")
        // And the new run is followed from there: its polls, and its events.
        try await letPollsThrough(device)
        try await event(device, state: home()) { device.model.snapshot.modules.count == 2 }
        assertShowsTheHome(device, record: F.record, "the new run's later word")
    }

    func testAnotherHubStartsFromNothing() async throws {
        let stream = String(repeating: "5a", count: 16)
        let first = OrderedHub(state: home(), stream: stream)
        let device = try await startDevice(first, polls: false)
        for _ in 0..<5 {
            let before = device.model.lastSyncAt
            try await event(device, state: home()) { device.model.lastSyncAt != before }
        }
        // Another hub -- by chance (in this test: on purpose) with the same stream id, and its
        // numbers start at 1. What was learned of the first hub says nothing about it.
        let second = OrderedHub(state: home(sensors: [Self.gasSensor]), stream: stream)
        let (transport, live) = source(second, polls: false)
        device.model.replace(dataSource: live, identity: .hub(id: String(repeating: "b", count: 32)), address: RemovalFixtures.url)
        try await waitUntil { device.model.snapshot.modules.count == 1 }
        try await waitUntil { await transport.hasOpenEventStream }
        XCTAssertEqual(device.model.staleSnapshotCount, 0, "the other hub's first snapshot is applied")
    }

    func testASnapshotInWhichOnlyTheSettingsChangedIsApplied() async throws {
        let hub = OrderedHub(state: home(settings: "r-1"))
        let device = try await startDevice(hub)
        XCTAssertEqual(device.model.sensorSnapshot.hubSettings?.revision, "r-1")
        try await holdAPoll(device)
        let old = await hub.make()   // revision r-1
        XCTAssertEqual(device.model.staleSnapshotCount, 0)
        // Another device saves the shared settings: nothing else of the snapshot changes.
        try await event(device, state: home(settings: "r-2")) { device.model.sensorSnapshot.hubSettings?.revision == "r-2" }
        assertShowsTheHome(device, record: F.record, "the sensors are as they were")
        try await release(device, with: old, leftOut: 1)
        XCTAssertEqual(device.model.sensorSnapshot.hubSettings?.revision, "r-2", "the old answer does not put the earlier revision back")
        try await event(device, state: home(settings: "r-3")) { device.model.sensorSnapshot.hubSettings?.revision == "r-3" }
    }

    /// The limit that stays: a hub that does not number its snapshots (Linux bridge 0.4.2 and
    /// earlier). There is nothing to decide from, so its snapshots are applied as they arrive --
    /// and the reviewed order still takes the Base away until the next snapshot.
    func testAHubThatDoesNotSayIsFollowedAsBeforeWithItsKnownLimit() async throws {
        let hub = OrderedHub(state: home(record: F.record), numbers: false)
        let device = try await startDevice(hub)
        try await event(device, state: removed()) { device.model.snapshot.powerBases.isEmpty }
        try await holdAPoll(device)
        let old = await hub.make()
        try await event(device, state: home(record: F.laterRecord)) { device.model.snapshot.modules.count == 2 }
        await hub.release(with: old)
        try await waitUntil { device.model.snapshot.powerBases.isEmpty }
        XCTAssertTrue(device.model.snapshot.modules.isEmpty, "with an earlier hub the old answer is still applied: its known limit")
        XCTAssertEqual(device.model.staleSnapshotCount, 0, "nothing is left out, and nothing is guessed from a time")
        try await waitUntil { device.model.snapshot.modules.count == 2 }
        assertShowsTheHome(device, record: F.laterRecord, "the next snapshot puts it right")
    }

    // MARK: What must keep working

    func testADeviceThatWasAwayThroughTheWholeRemovalStillDropsTheSensors() async throws {
        let hub = OrderedHub(state: home())
        let device = try await startDevice(hub, polls: false)
        assertShowsTheHome(device, record: F.record, "before")
        // The app is in the background. The Base is removed; the hub shows the finished job for
        // ten minutes and then no more. Sixteen minutes on (the hub's clock) the app is back.
        device.model.stop()
        await hub.setState(D.snapshot(bases: [], departures: [D.json()], minutesLater: 16))
        device.model.start()
        try await waitUntil { device.model.snapshot.powerBases.isEmpty }
        XCTAssertTrue(device.model.snapshot.modules.isEmpty, "the old sensors are gone with the first snapshot")
        XCTAssertFalse(device.model.isRegistryRecovering, "and not kept as recovering")
        XCTAssertEqual(device.model.staleSnapshotCount, 0)
    }

    func testARemovalARegistrationAndSensorUpdatesAreAllApplied() async throws {
        let hub = OrderedHub(state: home())
        let device = try await startDevice(hub, polls: false)
        let firstSeen = device.model.snapshot.modules.first?.lastSeen
        try await event(device, state: home(removals: [D.job("pending")])) { device.model.snapshot.powerBaseRemovals.first?.state == .pending }
        try await event(device, state: home(removals: [D.job("sent")])) { device.model.snapshot.powerBaseRemovals.first?.state == .sent }
        try await event(device, state: removed(removals: [D.job("released")])) { device.model.snapshot.powerBases.isEmpty }
        try await event(device, state: removed(removals: [D.job("completed")])) { device.model.snapshot.powerBaseRemovals.first?.state == .completed }
        try await event(device, state: home(record: F.laterRecord, removals: [D.job("completed")])) { device.model.snapshot.modules.count == 2 }
        assertShowsTheHome(device, record: F.laterRecord, "the Base that was registered again")
        // Samples keep arriving: every snapshot is a later one.
        for _ in 0..<3 {
            let before = device.model.lastSyncAt
            try await event(device, state: home(record: F.laterRecord)) { device.model.lastSyncAt != before }
        }
        let lastSeen = device.model.snapshot.modules.first?.lastSeen
        XCTAssertNotNil(lastSeen)
        XCTAssertNotEqual(lastSeen, firstSeen, "the sensors' values are the latest ones")
        XCTAssertEqual(device.model.staleSnapshotCount, 0, "nothing of an orderly sequence is left out")
    }
}
