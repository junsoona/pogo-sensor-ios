import Foundation
import XCTest
@testable import PogoHomeWatch

/// The Watch's own way to the hub, with the Watch app's real client (`WatchHubClient`: its
/// `URLSession`, the snapshot route, `PogoSnapshotMapper`) over real HTTP on the Mac's loopback.
///
/// `1.3.4` stopped on an Apple Watch with a 32-bit ABI (arm64_32) while it read the first
/// snapshot of a hub that lists a Power Base it can remove (`removal_serial`). A Watch simulator
/// is 64 bits wide: these tests run the same calls with the same answers, and they do not show
/// what an arm64_32 Watch does.
///
/// Skipped unless `TEST_RUNNER_POGO_WATCH_DIRECT_DIR` names a directory with `direct.json`:
/// `{"hub":"http://127.0.0.1:<port>","stub":"http://127.0.0.1:<port>"}` -- `hub` a real Linux
/// bridge API server, `stub` a server that answers `<stub>/serial/<member>/api/v1/snapshot` with
/// that hub's answer, the Base's two sensors listed and its `removal_serial` set to `<member>`
/// (`absent`: left out).
@MainActor
final class WatchDirectHubTests: XCTestCase {
    private static let gasSensor = "744dbdfffe65d07a"
    private static let dustSensor = "744dbdfffe65d07b"
    private static var temperatureID: HomeGlanceValueID { .pogo(module: ModuleIdentity.stableUUID(forRawIdentifier: gasSensor), kind: .temperature) }
    private static var humidityID: HomeGlanceValueID { .pogo(module: ModuleIdentity.stableUUID(forRawIdentifier: dustSensor), kind: .humidity) }

    private final class NoPhone: WatchPhoneRelaying {
        private(set) var requestCount = 0
        var isPhoneReachable: Bool { true }
        func requestRefresh() async throws -> WatchRelayReply {
            requestCount += 1
            throw WatchPhoneRelayError.unreachable
        }
    }

    private final class NoReload: WatchWidgetReloading { func reloadWidgets() {} }

    private struct Servers: Decodable {
        let hub: String
        let stub: String
    }

    private func servers() throws -> Servers {
        guard let directory = ProcessInfo.processInfo.environment["POGO_WATCH_DIRECT_DIR"] else {
            throw XCTSkip("POGO_WATCH_DIRECT_DIR is not set: no hub on the loopback to read")
        }
        return try JSONDecoder().decode(Servers.self, from: Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("direct.json")))
    }

    /// A Watch that was given its settings and is opened, with the app's real hub client.
    private func startedWatch(hubURL: String, phone: NoPhone, now: Date) -> WatchSyncEngine {
        let sync = WatchSyncEngine(store: nil, hub: WatchHubClient(), phone: phone, reloader: NoReload(), now: { now })
        sync.receivePush(WatchSyncPayload(
            sentAt: now,
            glance: nil,
            settings: WatchSettings(
                updatedAt: .distantPast, dataSourceMode: .live, hubBaseURL: hubURL,
                selectedValueIDs: [Self.temperatureID.stringValue, Self.humidityID.stringValue], moduleLabels: []
            )
        ))
        return sync
    }

    /// The answer of a real hub 0.5.0 that lists a Base it can remove, no removal asked yet.
    func testTheRealHubsAnswerIsReadWithItsRemovableBase() async throws {
        let hub = try XCTUnwrap(URL(string: try servers().hub))

        let snapshot = try await WatchHubClient().fetchSnapshot(from: hub)

        let base = try XCTUnwrap(snapshot.powerBases.first)
        XCTAssertEqual(snapshot.powerBases.count, 1)
        XCTAssertEqual(base.management, .supported)
        XCTAssertEqual(base.removalSerial, 0)
        XCTAssertEqual(base.removalBinding?.serial, 0)
        XCTAssertTrue(snapshot.reportsPowerBaseManagement)

        // The round the app makes when it is opened: the hub answered, so the iPhone is not asked.
        let phone = NoPhone()
        let round = await startedWatch(hubURL: hub.absoluteString, phone: phone, now: Date()).refresh()
        XCTAssertNotNil(round)
        XCTAssertNotEqual(round?.direct, .failed(.badResponse))
        XCTAssertNotEqual(round?.direct, .failed(.hubUnreachable))
        XCTAssertEqual(phone.requestCount, 0)
    }

    /// The same answer with the Base's two sensors: the first round confirms the state and brings
    /// both values, whatever the Base's serial says.
    func testTheFirstRoundBringsBothSensorsWhateverTheSerialSays() async throws {
        let stub = try servers().stub
        for member in ["0", "1", "2147483647", "2147483648", "4294967295", "-1", "4294967296", "absent"] {
            let now = Date()
            let phone = NoPhone()
            let sync = startedWatch(hubURL: "\(stub)/serial/\(member)", phone: phone, now: now)

            let round = await sync.refresh()

            XCTAssertEqual(round?.direct, .confirmed, member)
            XCTAssertEqual(round?.confirmedBy, .direct, member)
            XCTAssertEqual(phone.requestCount, 0, member)
            XCTAssertEqual(sync.glance?.sensor(with: Self.temperatureID)?.value, 23.4, member)
            XCTAssertEqual(sync.glance?.sensor(with: Self.humidityID)?.value, 41, member)
            XCTAssertEqual(sync.glance?.sensor(with: Self.temperatureID)?.checkedAt, now, member)
            XCTAssertEqual(sync.connectionStatus, .confirmed(.direct, at: now), member)
        }
    }

    /// A serial that is no integer is an answer outside the contract: a bad response, not a stop,
    /// and the iPhone is asked instead.
    func testAnAnswerOutsideTheContractIsABadResponse() async throws {
        let stub = try servers().stub
        let phone = NoPhone()
        let round = await startedWatch(hubURL: "\(stub)/serial/1.5", phone: phone, now: Date()).refresh()
        XCTAssertEqual(round?.direct, .failed(.badResponse))
        XCTAssertEqual(phone.requestCount, 1)
    }
}
