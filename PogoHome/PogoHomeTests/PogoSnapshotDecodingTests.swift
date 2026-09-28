import XCTest
@testable import PogoHome

@MainActor
final class PogoSnapshotDecodingTests: XCTestCase {
    // MARK: - Real hardware fixtures

    func testDecodesRealSGP41AndPMS5003Snapshot() throws {
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: PogoAPIFixtures.fullSnapshotJSON())

        XCTAssertEqual(snapshot.modules.count, 2)

        let sgp41ID = ModuleIdentity.stableUUID(forRawIdentifier: PogoAPIFixtures.sgp41UUID)
        let pms5003ID = ModuleIdentity.stableUUID(forRawIdentifier: PogoAPIFixtures.pms5003UUID)

        guard let sgp41 = snapshot.modules.first(where: { $0.id == sgp41ID }) else {
            return XCTFail("SGP41 module missing")
        }
        guard let pms5003 = snapshot.modules.first(where: { $0.id == pms5003ID }) else {
            return XCTFail("PMS5003 module missing")
        }

        XCTAssertEqual(Set(sgp41.readings.map(\.kind)), [.vocRaw, .vocIndex, .noxRaw, .noxIndex])
        XCTAssertEqual(Set(pms5003.readings.map(\.kind)), [.pm1, .pm2_5, .pm10])
        XCTAssertTrue(sgp41.isOnline)
        XCTAssertTrue(pms5003.isOnline)
    }

    /// Decodes an exact, byte-for-byte capture of a real response from the Linux
    /// PogoHome API (see `PogoAPIFixtures.realCapturedSnapshotJSON`), including its
    /// `unit: null` fields and integer-formatted numeric values.
    func testDecodesRealCapturedAPIResponseByteForByte() throws {
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: PogoAPIFixtures.realCapturedSnapshotJSON)
        XCTAssertEqual(snapshot.modules.count, 2)

        let sgp41ID = ModuleIdentity.stableUUID(forRawIdentifier: PogoAPIFixtures.sgp41UUID)
        let sgp41 = try XCTUnwrap(snapshot.modules.first { $0.id == sgp41ID })
        // Product names follow the UI language (see ModuleIdentityAndCatalogTests).
        let sgp41Name = ModuleCatalog.descriptor(forRawIdentifier: PogoAPIFixtures.sgp41UUID, apiRole: nil).displayName
        XCTAssertEqual(sgp41.name, sgp41Name)
        XCTAssertEqual(sgp41.hardwareName, sgp41Name)
        XCTAssertEqual(sgp41.hardwareIdentifier, PogoAPIFixtures.sgp41UUID)
        XCTAssertTrue(sgp41.isOnline)
        XCTAssertEqual(Set(sgp41.readings.map(\.kind)), [.vocRaw, .vocIndex, .noxRaw, .noxIndex])
        XCTAssertEqual(sgp41.readings.first { $0.kind == .vocIndex }?.value, 98)
        XCTAssertTrue(sgp41.readings.allSatisfy { $0.status == .normal })

        let pms5003ID = ModuleIdentity.stableUUID(forRawIdentifier: PogoAPIFixtures.pms5003UUID)
        let pms5003 = try XCTUnwrap(snapshot.modules.first { $0.id == pms5003ID })
        XCTAssertEqual(pms5003.name, ModuleCatalog.descriptor(forRawIdentifier: PogoAPIFixtures.pms5003UUID, apiRole: nil).displayName)
        XCTAssertEqual(pms5003.hardwareIdentifier, PogoAPIFixtures.pms5003UUID)
        XCTAssertEqual(Set(pms5003.readings.map(\.kind)), [.pm1, .pm2_5, .pm10])
        XCTAssertEqual(pms5003.readings.first { $0.kind == .pm2_5 }?.value, 18)
    }

    func testAllTenSensorKindsMapCorrectly() throws {
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: PogoAPIFixtures.allTenKindsSnapshotJSON())
        guard let module = snapshot.modules.first else { return XCTFail("expected one module") }
        XCTAssertEqual(Set(module.readings.map(\.kind)), Set(SensorKind.allCases))
    }

    // MARK: - raw_value/scale/status/sample_seq preserved at the DTO layer

    func testDTODecodingPreservesRawValueScaleStatusAndSampleSeq() throws {
        let dto = try JSONDecoder().decode(PogoSnapshotDTO.self, from: PogoAPIFixtures.fullSnapshotJSON())
        guard let sgp41 = dto.modules.first(where: { $0.uuid == PogoAPIFixtures.sgp41UUID }) else {
            return XCTFail("SGP41 module missing from DTO")
        }
        guard let vocRaw = sgp41.readings.first(where: { $0.kindRaw == "voc_raw" }) else {
            return XCTFail("voc_raw reading missing")
        }
        XCTAssertEqual(vocRaw.rawValue, 24500)
        XCTAssertEqual(vocRaw.scale, 0.01)
        XCTAssertEqual(vocRaw.statusRaw, "ok")
        XCTAssertEqual(vocRaw.sampleSeq, 10)
        XCTAssertEqual(vocRaw.value, 245.0)
    }

    // MARK: - Status mapping

    func testStatusMapping() {
        XCTAssertEqual(readingDTO(status: "ok").mappedStatus, .normal)
        XCTAssertEqual(readingDTO(status: "conditioning").mappedStatus, .conditioning)
        XCTAssertEqual(readingDTO(status: "error").mappedStatus, .error)
        XCTAssertEqual(readingDTO(status: "some_future_status").mappedStatus, .unavailable)
    }

    func testModuleOnlineFalseMapsToOfflineIndependentOfReadingStatus() throws {
        let json = Data("""
        {
          "schema_version": 1,
          "generated_at_unix_ms": 1700000000000,
          "registry_generation": 1,
          "modules": [
            {
              "uuid": "0102030405060708",
              "online": false,
              "depth": 1,
              "role": "x",
              "sensor_bitmap": 0,
              "generation": 1,
              "last_seq": 1,
              "readings": [
                {"kind": "temperature", "raw_value": 220, "scale": 0.1, "value": 22.0, "unit": "c", "status": "ok", "sample_seq": 1}
              ]
            }
          ]
        }
        """.utf8)
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: json)
        let module = try XCTUnwrap(snapshot.modules.first)
        XCTAssertFalse(module.isOnline)
        // Module offline must not be conflated with reading status — the reading itself
        // is still reported as .normal since the server said "ok".
        XCTAssertEqual(module.readings.first?.status, .normal)
    }

    // MARK: - Hard failures: schema version, invalid/duplicate UUID, malformed JSON

    func testUnsupportedSchemaVersionThrowsClearError() {
        XCTAssertThrowsError(try PogoSnapshotMapper.decodeSnapshot(from: PogoAPIFixtures.snapshotJSON(schemaVersion: 2))) { error in
            XCTAssertEqual(error as? PogoAPIError, .unsupportedSchemaVersion(found: 2, expected: 1))
        }
    }

    func testInvalidModuleIdentifierThrowsClearError() {
        XCTAssertThrowsError(try PogoSnapshotMapper.decodeSnapshot(from: PogoAPIFixtures.snapshotJSON(moduleUUID: "not-a-hex-id!!"))) { error in
            guard case .invalidModuleIdentifier = error as? PogoAPIError else {
                return XCTFail("expected invalidModuleIdentifier, got \(error)")
            }
        }
    }

    func testDuplicateModuleIdentifierThrowsClearError() {
        XCTAssertThrowsError(try PogoSnapshotMapper.decodeSnapshot(from: PogoAPIFixtures.snapshotJSON(duplicateUUID: "aabbccddeeff0011"))) { error in
            guard case .duplicateModuleIdentifier = error as? PogoAPIError else {
                return XCTFail("expected duplicateModuleIdentifier, got \(error)")
            }
        }
    }

    func testMalformedJSONThrowsClearErrorWithoutCrashing() {
        XCTAssertThrowsError(try PogoSnapshotMapper.decodeSnapshot(from: PogoAPIFixtures.malformedJSON)) { error in
            guard case .malformedJSON = error as? PogoAPIError else {
                return XCTFail("expected malformedJSON, got \(error)")
            }
        }
    }

    // MARK: - Forward compatibility: unknown kind/status never fails the whole snapshot

    func testUnknownSensorKindAndStatusAreSkippedSafelyNotFatal() throws {
        let json = PogoAPIFixtures.snapshotJSON(unknownKind: "co2_ppm", unknownStatus: "warming_up_v2")
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: json)
        let module = try XCTUnwrap(snapshot.modules.first)

        // The unknown "co2_ppm" reading is dropped, not fatal.
        XCTAssertFalse(module.readings.contains { $0.kind.rawValue == "co2_ppm" })
        // The known "temperature" reading survives with its unknown status safely mapped.
        let temperature = try XCTUnwrap(module.readings.first { $0.kind == .temperature })
        XCTAssertEqual(temperature.status, .unavailable)
    }

    private func readingDTO(status: String) -> PogoReadingDTO {
        let json = Data("""
        {"kind": "temperature", "raw_value": 1, "scale": 1.0, "value": 1.0, "unit": "u", "status": "\(status)", "sample_seq": 1}
        """.utf8)
        return try! JSONDecoder().decode(PogoReadingDTO.self, from: json)
    }
}
