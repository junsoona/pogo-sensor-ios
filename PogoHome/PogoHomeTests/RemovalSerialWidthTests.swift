import Foundation
import XCTest
@testable import PogoHome

// The hub's `removal_serial` is a count of 32 bits, unsigned: 0...4294967295 (firmware
// repository, docs/pogohome-api-v1.md, "Removal routes"). `1.3.4` carried it in `Int`, and its
// range check converted `UInt32.max` to `Int`. On an Apple Watch with a 32-bit ABI (arm64_32:
// Series 7) `Int` is 32 bits and that conversion stops the program -- for every Base the hub can
// remove, whatever its serial is, as soon as the Watch reads its first snapshot. Now the number
// is 64 bits wide on every device, from the wire to the request.
//
// Everything here runs where `Int` is 64 bits (iPhone and Watch simulators, Mac). These tests say
// what the code does with the hub's numbers and that it holds them in a fixed width; `Int32` is
// used where a 32-bit `Int` has to be shown. None of this executes arm64_32 code: that the Watch
// binary no longer stops there is read from the arm64_32 build itself, and seen on the Watch.

enum Hub050Fixtures {
    /// The answer of a real Linux bridge 0.5.0 API server to `GET /api/v1/snapshot`, byte for byte
    /// (its host build on the Mac, 2026-10-11; made-up identities of that run): one Power Base it
    /// can remove, no removal asked of it yet, no sensor.
    static let snapshot = #"{"schema_version":1,"generated_at_unix_ms":1791726752591,"registry_generation":2,"power_bases":[{"uuid":"744dbdfffe65d357","online":true,"module_count":0,"online_module_count":0,"management":"supported","erase_confirmation":"manual","record":"04aee7411d6d4281f3ec492104245d79","removal_serial":0}],"modules":[],"power_base_removals":[],"power_base_forgets":[],"power_base_departures":[],"settings_api":1,"settings_state":"uninitialized","settings_revision":null,"snapshot_stream":"6d7150574a50e1b0087b9563e8d1191c","snapshot_sequence":1}"#

    static let base = "744dbdfffe65d357"
    static let record = "04aee7411d6d4281f3ec492104245d79"
    static let gasSensor = "744dbdfffe65d07a"
    static let dustSensor = "744dbdfffe65d07b"
    static let requestID = String(repeating: "5a", count: 16)

    /// That answer with the Base's `removal_serial` member replaced by `member` (`nil`: left out).
    static func snapshot(serialMember member: String?) -> Data {
        let field = #","removal_serial":0"#
        precondition(snapshot.contains(field))
        return Data(snapshot.replacingOccurrences(of: field, with: member.map { #","removal_serial":\#($0)"# } ?? "").utf8)
    }

    /// One sensor of that Base as the hub writes a module (docs/pogohome-api-v1.md).
    static func module(_ uuid: String, kind: String, value: Double, counters: String = #""generation":1,"last_seq":1"#, sampleSeq: String = "27") -> String {
        #"{"uuid":"\#(uuid)","power_base_uuid":"\#(base)","parent_uuid":"\#(base)","online":true,"depth":1,"role":"leaf","sensor_bitmap":6,\#(counters),"readings":[{"kind":"\#(kind)","raw_value":\#(value * 1000),"scale":1,"value":\#(value),"unit":"celsius","status":"ok","sample_seq":\#(sampleSeq)}]}"#
    }

    /// The same answer with the Base's two sensors listed (the home of the hardware test).
    static func home(serialMember member: String? = "0", temperature: Double = 23.4, humidity: Double = 41) -> Data {
        let modules = [module(gasSensor, kind: "temperature", value: temperature), module(dustSensor, kind: "humidity", value: humidity)]
        let text = String(decoding: snapshot(serialMember: member), as: UTF8.self)
            .replacingOccurrences(of: #""module_count":0,"online_module_count":0"#, with: #""module_count":2,"online_module_count":2"#)
            .replacingOccurrences(of: #""modules":[]"#, with: #""modules":[\#(modules.joined(separator: ","))]"#)
        precondition(text.contains(gasSensor) && text.contains(#""module_count":2"#))
        return Data(text.utf8)
    }

    static var temperatureID: HomeGlanceValueID { .pogo(module: ModuleIdentity.stableUUID(forRawIdentifier: gasSensor), kind: .temperature) }
    static var humidityID: HomeGlanceValueID { .pogo(module: ModuleIdentity.stableUUID(forRawIdentifier: dustSensor), kind: .humidity) }
}

// MARK: - From the wire to the model and into the request

final class RemovalSerialWidthTests: XCTestCase {
    private typealias H = Hub050Fixtures
    private typealias Transport = URLSessionPowerBaseRemovalTransport

    /// Every number the hub can say, and the first ones on either side that it cannot.
    private static let inRange: [Int64] = [0, 1, 2_147_483_647, 2_147_483_648, 4_294_967_295]
    private static let outOfRange: [Int64] = [-1, 4_294_967_296, .max, .min]

    private func listed(_ member: String?) throws -> PowerBase {
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: H.snapshot(serialMember: member))
        XCTAssertEqual(snapshot.powerBases.count, 1, "the Base is listed whatever its serial says")
        return try XCTUnwrap(snapshot.powerBases.first)
    }

    func testTheHubsCountIsHeldIn64BitsOnEveryDevice() throws {
        let dto = try XCTUnwrap(JSONDecoder().decode(PogoSnapshotDTO.self, from: H.snapshot(serialMember: "0")).powerBases?.first)
        let base = try listed("0")
        let binding = try XCTUnwrap(base.removalBinding)
        // `Int` is 32 bits on arm64_32: a count of 32 bits unsigned does not fit it.
        XCTAssertTrue(type(of: dto.removalSerial) == Int64?.self, "the wire form")
        XCTAssertTrue(type(of: base.removalSerial) == Int64?.self, "the model")
        XCTAssertTrue(type(of: binding.serial) == Int64.self, "what a request names")
        XCTAssertNil(Int32(exactly: UInt32.max), "what `Int(UInt32.max)` asks of a 32-bit Int: it has no such value, and the conversion stops the program")
        XCTAssertNil(Int32(exactly: 2_147_483_648 as Int64), "the upper half of the hub's range is beyond a 32-bit Int")
    }

    /// The answer of a real hub 0.5.0, as it is: the snapshot the Watch stopped on.
    func testTheAnswerOfAHubThatCanRemoveItsBaseIsReadWithItsSerial() throws {
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: Data(H.snapshot.utf8))
        let base = try XCTUnwrap(snapshot.powerBases.first)
        XCTAssertEqual(base.hardwareIdentifier, H.base)
        XCTAssertEqual(base.management, .supported)
        XCTAssertTrue(base.isOnline)
        XCTAssertEqual(base.removalSerial, 0)
        XCTAssertEqual(base.removalBinding, PowerBaseRemovalBinding(record: H.record, serial: 0))
        XCTAssertTrue(snapshot.reportsPowerBaseManagement)
        XCTAssertEqual(snapshot.delivery.hubOrder?.sequence, 1)
    }

    func testEveryNumberOfTheHubsRangeIsKeptAsItIs() throws {
        for serial in Self.inRange {
            let base = try listed(String(serial))
            XCTAssertEqual(base.removalSerial, serial, "\(serial)")
            let binding = try XCTUnwrap(base.removalBinding, "\(serial)")
            XCTAssertEqual(binding, PowerBaseRemovalBinding(record: H.record, serial: serial))
            XCTAssertTrue(binding.isValid, "\(serial)")
            XCTAssertTrue(PowerBaseRemovalBinding.isValidSerial(serial), "\(serial)")
        }
    }

    /// As before: such a number is no word about removals, and nothing else of the Base or of the
    /// snapshot is lost with it.
    func testANumberOutsideTheHubsRangeIsNoSerialAndTheBaseStaysListed() throws {
        for serial in Self.outOfRange {
            let base = try listed(String(serial))
            XCTAssertNil(base.removalSerial, "\(serial)")
            XCTAssertNil(base.removalBinding, "\(serial)")
            XCTAssertEqual(base.record, H.record, "\(serial)")
            XCTAssertEqual(base.management, .supported, "\(serial)")
            XCTAssertTrue(base.isOnline, "\(serial)")
            XCTAssertFalse(PowerBaseRemovalBinding.isValidSerial(serial), "\(serial)")
            XCTAssertFalse(PowerBaseRemovalBinding(record: H.record, serial: serial).isValid, "\(serial)")
        }
    }

    func testAHubThatDoesNotSayOrCannotRemoveGivesNoSerial() throws {
        // Linux bridge 0.4.2 and earlier: the member is not there. `null` says as little.
        for member in [nil, "null"] {
            let base = try listed(member)
            XCTAssertNil(base.removalSerial)
            XCTAssertNil(base.removalBinding)
            XCTAssertEqual(base.record, H.record)
        }
        // Said of a Base the hub cannot remove, also the largest count means nothing.
        for management in [#""management":"unsupported""#, #""management":"later""#] {
            let text = String(decoding: H.snapshot(serialMember: "4294967295"), as: UTF8.self)
                .replacingOccurrences(of: #""management":"supported""#, with: management)
            let base = try XCTUnwrap(PogoSnapshotMapper.decodeSnapshot(from: Data(text.utf8)).powerBases.first)
            XCTAssertNil(base.removalSerial, management)
            XCTAssertNil(base.removalBinding, management)
        }
    }

    /// As before: a member of the wrong JSON type, a fraction, or a number beyond 64 bits is an
    /// answer outside the contract. The snapshot is refused as malformed -- an error, never a stop.
    func testAMemberThatIsNoIntegerRefusesTheSnapshotAsMalformed() {
        for member in [#""0""#, "1.5", "true", "[0]", "{}", "9223372036854775808", "-9223372036854775809"] {
            XCTAssertThrowsError(try PogoSnapshotMapper.decodeSnapshot(from: H.snapshot(serialMember: member)), member) { error in
                guard case PogoAPIError.malformedJSON = error else { return XCTFail("\(member): \(error)") }
                XCTAssertEqual(WatchSyncEngine.classify(error), .badResponse, "what the Watch calls it")
            }
        }
    }

    /// The serial a request sends is the number the hub listed, digit for digit.
    func testTheRequestBodyCarriesTheListedSerialAcrossTheWholeRange() throws {
        for serial in Self.inRange {
            let binding = try XCTUnwrap(try listed(String(serial)).removalBinding, "\(serial)")
            let body = try Transport.requestBody(powerBaseIdentifier: H.base, binding: binding, requestID: H.requestID)
            XCTAssertEqual(
                String(decoding: body, as: UTF8.self),
                #"{"power_base_uuid":"\#(H.base)","record":"\#(H.record)","removal_serial":\#(serial),"request_id":"\#(H.requestID)"}"#
            )
            // Read back as any JSON reader would: the same four members, the same number.
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["power_base_uuid", "record", "removal_serial", "request_id"])
            XCTAssertEqual((object["removal_serial"] as? NSNumber)?.int64Value, serial)
            XCTAssertEqual((object["removal_serial"] as? NSNumber)?.uint32Value, UInt32(serial), "it fits the hub's 32 bits")
            // And once more through the app's own reading of a Base that lists it.
            let again = try listed(String(try XCTUnwrap((object["removal_serial"] as? NSNumber)?.int64Value)))
            XCTAssertEqual(again.removalBinding, binding)
        }
    }

    func testARequestWithANumberOutsideTheRangeNeverLeavesTheDevice() async {
        let transport = Transport()
        // Refused before anything is sent. Should that check ever be gone, the request goes to
        // this Mac's own discard port and nowhere else.
        let nowhere = URL(string: "http://127.0.0.1:9")!
        for serial in Self.outOfRange {
            do {
                _ = try await transport.request(
                    baseURL: nowhere, credential: RemovalFixtures.credential(), powerBaseIdentifier: H.base,
                    binding: PowerBaseRemovalBinding(record: H.record, serial: serial), requestID: H.requestID
                )
                XCTFail("\(serial) was sent")
            } catch {
                XCTAssertEqual(error as? PowerBaseRemovalError, .rejected("invalid_record"), "\(serial)")
            }
        }
    }

    // MARK: The hub's other counters

    /// `registry_generation` is 64 bits at the hub; a module's `generation` and `last_seq` and a
    /// reading's `sample_seq` are 32 bits unsigned. The app keeps them and uses none; held in
    /// `Int` they would refuse the whole snapshot on arm64_32 once one passed `Int32.max`.
    func testTheHubsCountersBeyondA32BitIntDoNotRefuseTheSnapshot() throws {
        let modules = [
            H.module(H.gasSensor, kind: "temperature", value: 23.4, counters: #""generation":4294967295,"last_seq":4294967295"#, sampleSeq: "4294967295"),
            H.module(H.dustSensor, kind: "humidity", value: 41, counters: #""generation":2147483648,"last_seq":2147483648"#, sampleSeq: "2147483648"),
        ]
        let text = H.snapshot
            .replacingOccurrences(of: #""registry_generation":2"#, with: #""registry_generation":1099511627776"#)
            .replacingOccurrences(of: #""modules":[]"#, with: #""modules":[\#(modules.joined(separator: ","))]"#)
        let dto = try JSONDecoder().decode(PogoSnapshotDTO.self, from: Data(text.utf8))
        XCTAssertEqual(dto.registryGeneration, 1_099_511_627_776)
        XCTAssertEqual(dto.modules.map(\.generation), [4_294_967_295, 2_147_483_648])
        XCTAssertEqual(dto.modules.map(\.lastSeq), [4_294_967_295, 2_147_483_648])
        XCTAssertEqual(dto.modules.map { $0.readings.first?.sampleSeq }, [4_294_967_295, 2_147_483_648])
        XCTAssertTrue(type(of: dto.registryGeneration) == Int64.self)
        XCTAssertTrue(type(of: dto.modules[0].generation) == Int64?.self)
        XCTAssertTrue(type(of: dto.modules[0].lastSeq) == Int64?.self)
        XCTAssertTrue(type(of: dto.modules[0].readings[0].sampleSeq) == Int64?.self)

        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: Data(text.utf8))
        XCTAssertEqual(snapshot.modules.count, 2)
        XCTAssertEqual(snapshot.modules.first?.readings.first?.value, 23.4)

        // What a 32-bit `Int` does with such a number: the decoder throws, and with it the snapshot.
        struct Narrow: Decodable { let value: Int32 }
        XCTAssertThrowsError(try JSONDecoder().decode(Narrow.self, from: Data(#"{"value":2147483648}"#.utf8)))
        XCTAssertEqual(try JSONDecoder().decode(Narrow.self, from: Data(#"{"value":2147483647}"#.utf8)).value, .max)
    }
}

// MARK: - The Watch's two ways to the hub

/// Reads the bridge's bytes as `WatchHubClient` (Watch app target) does: the same one call.
@MainActor
private final class BytesHub: WatchHubFetching {
    var answer: Data
    private(set) var fetchCount = 0

    init(_ answer: Data) { self.answer = answer }

    func fetchSnapshot(from baseURL: URL) async throws -> HomeSnapshot {
        fetchCount += 1
        return try PogoSnapshotMapper.decodeSnapshot(from: answer)
    }
}

@MainActor
final class WatchStartSnapshotTests: XCTestCase {
    private typealias H = Hub050Fixtures
    private typealias F = GlanceFixtures
    private typealias W = WatchFixtures

    private func settings() -> WatchSettings {
        W.settings(selection: [H.temperatureID, H.humidityID])
    }

    /// A Watch that was given its settings and is opened: its first round.
    private func startedWatch(hub: WatchHubFetching, phone: ScriptedPhone, now: Date) -> (WatchSyncEngine, InMemoryWatchStore) {
        let store = InMemoryWatchStore(WatchStoredState(glance: nil, settings: settings(), record: .empty))
        return (WatchSyncEngine(store: store, hub: hub, phone: phone, reloader: CountingWatchReloader(), language: .korean, now: { now }), store)
    }

    /// On the hub's network: the first snapshot of a hub 0.5.0 that lists a Base it can remove
    /// (`removal_serial` 0) -- the answer `1.3.4` stopped on -- confirms the state and brings
    /// both sensors. Whatever the serial says, the Watch reads the sensors.
    func testTheFirstDirectRoundReadsAHubThatListsARemovableBase() async throws {
        for member in ["0", "1", "2147483647", "2147483648", "4294967295", "-1", "4294967296", nil] {
            let now = F.t0.addingTimeInterval(60)
            let hub = BytesHub(H.home(serialMember: member))
            let phone = ScriptedPhone(reachable: true)
            let (sync, store) = startedWatch(hub: hub, phone: phone, now: now)

            let round = await sync.refresh()

            XCTAssertEqual(round?.direct, .confirmed, "\(member ?? "absent")")
            XCTAssertEqual(round?.confirmedBy, .direct, "\(member ?? "absent")")
            XCTAssertEqual(phone.requestCount, 0, "the hub answered: the iPhone is not asked")
            XCTAssertEqual(sync.glance?.sensor(with: H.temperatureID)?.value, 23.4, "\(member ?? "absent")")
            XCTAssertEqual(sync.glance?.sensor(with: H.humidityID)?.value, 41, "\(member ?? "absent")")
            XCTAssertEqual(sync.glance?.sensor(with: H.temperatureID)?.checkedAt, now)
            XCTAssertEqual(sync.glance?.pogo.state, .healthy, "\(member ?? "absent")")
            XCTAssertEqual(sync.connectionStatus, .confirmed(.direct, at: now))
            XCTAssertEqual(store.state, sync.state, "kept for the next start and the widgets")
        }
    }

    /// Closed and opened again: the kept state is there, and the next round brings new values.
    func testOpenedAgainTheWatchShowsWhatItKeptAndThenTheNewValues() async throws {
        let first = F.t0.addingTimeInterval(60)
        let (sync, store) = startedWatch(hub: BytesHub(H.home()), phone: ScriptedPhone(reachable: false), now: first)
        await sync.refresh()

        let later = first.addingTimeInterval(120)
        let again = WatchSyncEngine(
            store: store, hub: BytesHub(H.home(temperature: 25.5, humidity: 38)), phone: ScriptedPhone(reachable: false),
            reloader: CountingWatchReloader(), language: .korean, now: { later }
        )
        XCTAssertEqual(again.glance?.sensor(with: H.temperatureID)?.value, 23.4, "what was kept, before any round")
        XCTAssertEqual(again.glance?.sensor(with: H.temperatureID)?.checkedAt, first)

        let round = await again.refresh()

        XCTAssertEqual(round?.confirmedBy, .direct)
        XCTAssertEqual(again.glance?.sensor(with: H.temperatureID)?.value, 25.5)
        XCTAssertEqual(again.glance?.sensor(with: H.humidityID)?.value, 38)
        XCTAssertEqual(again.glance?.sensor(with: H.humidityID)?.checkedAt, later)
    }

    /// Away from the hub: the iPhone reads the same answer and hands the Watch what it shows,
    /// through the message form the two really exchange.
    func testThroughTheIPhoneTheSameAnswerReachesTheWatch() async throws {
        let now = F.t0.addingTimeInterval(60)
        let settings = settings()
        let responder = WatchRelayResponder(
            settings: { settings },
            liveGlance: { nil },
            lastGlance: { nil },
            applyConfiguration: { $0 },
            homeName: { "우리 집" },
            fetchSnapshot: { _ in try PogoSnapshotMapper.decodeSnapshot(from: H.home()) },
            now: { now }
        )
        let answered = await responder.reply()
        XCTAssertEqual(answered.outcome, .confirmed)
        // As WatchConnectivity carries it: a property-list message, written and read back.
        let message = try WatchSyncCoding.message(for: answered)
        let carried = try PropertyListSerialization.propertyList(
            from: PropertyListSerialization.data(fromPropertyList: message, format: .binary, options: 0), format: nil
        )
        let received = try XCTUnwrap(WatchSyncCoding.reply(from: try XCTUnwrap(carried as? [String: Any])))
        XCTAssertEqual(received, answered)

        let phone = ScriptedPhone(reachable: true, [.success(received)])
        let (sync, _) = startedWatch(hub: ScriptedHub([.failure(URLError(.cannotConnectToHost))]), phone: phone, now: now)

        let round = await sync.refresh()

        XCTAssertEqual(round, WatchSyncRound(at: now, direct: .failed(.hubUnreachable), phone: .confirmed))
        XCTAssertEqual(sync.glance?.sensor(with: H.temperatureID)?.value, 23.4)
        XCTAssertEqual(sync.glance?.sensor(with: H.humidityID)?.value, 41)
        XCTAssertEqual(sync.record.lastConfirmation, WatchConfirmation(path: .phone, at: now))
    }
}
