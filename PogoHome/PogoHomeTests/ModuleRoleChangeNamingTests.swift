import XCTest
@testable import PogoHome

@MainActor
final class ModuleRoleChangeNamingTests: XCTestCase {
    private let board = "744dbdfffe65d357"

    private func snapshot(
        uuid: String = "744dbdfffe65d357", bitmap: Int? = 6,
        kinds: [String] = ["temperature", "humidity"], online: Bool = true,
        status: String = "ok"
    ) throws -> HomeSnapshot {
        var module: [String: Any] = [
            "uuid": uuid, "online": online, "depth": 1, "role": "leaf",
            "readings": kinds.map { ["kind": $0, "value": 22.5, "status": status] }
        ]
        if let bitmap { module["sensor_bitmap"] = bitmap }
        let object: [String: Any] = ["schema_version": 1, "generated_at_unix_ms": 1,
                                     "registry_generation": 1, "modules": [module]]
        return try PogoSnapshotMapper.decodeSnapshot(from: JSONSerialization.data(withJSONObject: object))
    }

    func testSameBoardChangesFromGasToClimateToParticlesWithoutReidentifying() throws {
        let gas = try XCTUnwrap(snapshot(bitmap: 0x78, kinds: ["voc_raw", "voc_index", "nox_raw", "nox_index"]).modules.first)
        let climate = try XCTUnwrap(snapshot().modules.first)
        let particles = try XCTUnwrap(snapshot(bitmap: 0x380, kinds: ["pm1", "pm2_5", "pm10"]).modules.first)
        XCTAssertEqual(gas.id, climate.id)
        XCTAssertEqual(climate.id, particles.id)
        XCTAssertEqual(climate.hardwareIdentifier, board)
        XCTAssertEqual(gas.hardwareName, AppLanguage.current.string("VOC/NOx 가스 센서"))
        XCTAssertEqual(climate.hardwareName, AppLanguage.current.string("온습도 센서"))
        XCTAssertEqual(particles.hardwareName, AppLanguage.current.string("미세먼지 센서"))
        XCTAssertFalse(climate.name.contains("SGP41"))
        XCTAssertEqual(Set(climate.readings.map(\.kind)), [.temperature, .humidity])
    }

    func testFormerParticleBoardAndNewBoardCanBothBecomeClimateSensors() throws {
        for uuid in ["744dbdfffe65d07a", "0102030405060708", "744DBDFFFE65D357"] {
            let module = try XCTUnwrap(snapshot(uuid: uuid).modules.first)
            XCTAssertEqual(module.name, AppLanguage.current.string("온습도 센서"))
        }
    }

    func testOfflineModuleWithoutSamplesStillUsesItsAdvertisedCapabilities() throws {
        let module = try XCTUnwrap(snapshot(kinds: [], online: false).modules.first)
        XCTAssertEqual(module.name, AppLanguage.current.string("온습도 센서"))
        XCTAssertFalse(module.isOnline)
        XCTAssertTrue(module.readings.isEmpty)
    }

    func testConditioningAndErrorReadingsDoNotRenameTheModule() throws {
        for status in ["conditioning", "error", "not_available"] {
            let module = try XCTUnwrap(snapshot(status: status).modules.first)
            XCTAssertEqual(module.name, AppLanguage.current.string("온습도 센서"))
        }
    }

    func testOldHubWithoutBitmapUsesItsReadingKinds() throws {
        let module = try XCTUnwrap(snapshot(bitmap: nil).modules.first)
        XCTAssertEqual(module.name, AppLanguage.current.string("온습도 센서"))
    }

    func testUnknownReadingKindIsNotDiscardedWhenChoosingFallbackName() throws {
        let module = try XCTUnwrap(snapshot(bitmap: nil, kinds: ["temperature", "humidity", "future_kind"]).modules.first)
        XCTAssertEqual(module.name, AppLanguage.current.string("센서 모듈"))
        XCTAssertEqual(module.readings.count, 2, "known readings are still retained for display")
    }

    func testUnknownCapabilitiesDoNotReuseTheBoardOldGasName() throws {
        for bitmap in [0, -1, 0x8006, 0x387] {
            let module = try XCTUnwrap(snapshot(bitmap: bitmap).modules.first)
            XCTAssertEqual(module.name, AppLanguage.current.string("센서 모듈"))
            XCTAssertEqual(module.roleDescription, "leaf")
        }
    }

    func testCustomNameAndRoomSurviveAChangeOfSensorOnTheSameBoard() async throws {
        let initial = try snapshot(bitmap: 0x78, kinds: ["voc_raw", "voc_index", "nox_raw", "nox_index"])
        let store = InMemoryHomeConfigurationStore()
        let model = AppModel(dataSource: MockSensorDataSource(), initialSnapshot: initial, configurationStore: store)
        let id = try XCTUnwrap(initial.modules.first?.id)
        try await model.updateModule(id: id, customName: "내 창가 센서", roomID: HomeConfigurationDefaults.bedroom.id)
        let updated = try XCTUnwrap(model.applyingConfiguration(to: snapshot()).modules.first)
        XCTAssertEqual(updated.name, "내 창가 센서")
        XCTAssertEqual(updated.hardwareName, AppLanguage.current.string("온습도 센서"))
        XCTAssertEqual(updated.roomID, HomeConfigurationDefaults.bedroom.id)
        XCTAssertEqual(Set(updated.readings.map(\.kind)), [.temperature, .humidity])
    }

    func testEvenCustomNameMatchingAnOldProductIsNotRewritten() async throws {
        let initial = try snapshot(bitmap: 0x78, kinds: ["voc_raw", "voc_index", "nox_raw", "nox_index"])
        let store = InMemoryHomeConfigurationStore()
        let model = AppModel(dataSource: MockSensorDataSource(), initialSnapshot: initial, configurationStore: store)
        let id = try XCTUnwrap(initial.modules.first?.id)
        try await model.updateModule(id: id, customName: "SGP41 가스 센서", roomID: ModuleCatalog.unspecifiedRoomID)
        let updated = try XCTUnwrap(model.applyingConfiguration(to: snapshot()).modules.first)
        XCTAssertEqual(updated.name, "SGP41 가스 센서", "a user-saved name belongs to the user")
        XCTAssertEqual(updated.hardwareName, AppLanguage.current.string("온습도 센서"))
    }

    func testClearingCustomNameUsesTheNewHardwareCategory() async throws {
        let initial = try snapshot()
        let store = InMemoryHomeConfigurationStore()
        let model = AppModel(dataSource: MockSensorDataSource(), initialSnapshot: initial, configurationStore: store)
        let id = try XCTUnwrap(initial.modules.first?.id)
        try await model.updateModule(id: id, customName: "임시 이름", roomID: ModuleCatalog.unspecifiedRoomID)
        try await model.updateModule(id: id, customName: nil, roomID: ModuleCatalog.unspecifiedRoomID)
        XCTAssertEqual(model.module(with: id)?.name, AppLanguage.current.string("온습도 센서"))
    }
}
