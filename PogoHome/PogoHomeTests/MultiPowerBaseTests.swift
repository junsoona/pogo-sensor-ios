import XCTest
@testable import PogoHome

/// Multi-Power-Base milestone: two Bases in one bridge snapshot, their modules kept apart,
/// one Base going offline and back, SSE/app reconnects, saved names and rooms surviving all of
/// it, and older single-Base bridges still decoding exactly as before.
enum MultiPowerBaseFixtures {
    static let baseA = "a0a0a0fffe000001"
    static let baseB = "b0b0b0fffe000002"
    /// Same sensor kinds on both Bases: an SHT45 on each, a PMS5003 behind each SHT45.
    static let aSHT = "744dbdfffe650a01"
    static let aPMS = "744dbdfffe650a02"
    static let bSHT = "744dbdfffe650b01"
    static let bPMS = "744dbdfffe650b02"

    struct Module {
        let uuid: String
        let base: String
        let parent: String
        let online: Bool
        let depth: Int
        var withReadings = true
    }

    static func module(_ m: Module) -> String {
        let readings = !m.withReadings ? "" : m.uuid.hasSuffix("01")
            ? #"{"kind":"temperature","raw_value":23400,"scale":1,"value":23.400,"unit":"celsius","status":"ok","sample_seq":7}"#
            : #"{"kind":"pm2_5","raw_value":7,"scale":3,"value":7,"unit":"ug/m3","status":"ok","sample_seq":7}"#
        return """
        {"uuid":"\(m.uuid)","power_base_uuid":"\(m.base)","parent_uuid":"\(m.parent)","online":\(m.online),"depth":\(m.depth),"role":"leaf","sensor_bitmap":6,"generation":1,"last_seq":1,"readings":[\(readings)]}
        """
    }

    static func base(_ uuid: String, online: Bool, modules: Int, onlineModules: Int) -> String {
        #"{"uuid":"\#(uuid)","online":\#(online),"module_count":\#(modules),"online_module_count":\#(onlineModules)}"#
    }

    static func snapshot(bases: [String], modules: [Module]) -> Data {
        Data("""
        {"schema_version":1,"generated_at_unix_ms":1732000000000,"registry_generation":9,"power_bases":[\(bases.joined(separator: ","))],"modules":[\(modules.map(module).joined(separator: ","))]}
        """.utf8)
    }

    static func twoBases(baseAOnline: Bool = true) -> Data {
        snapshot(
            bases: [
                base(baseA, online: baseAOnline, modules: 2, onlineModules: baseAOnline ? 2 : 0),
                base(baseB, online: true, modules: 2, onlineModules: 2),
            ],
            modules: [
                Module(uuid: aSHT, base: baseA, parent: baseA, online: baseAOnline, depth: 1),
                Module(uuid: aPMS, base: baseA, parent: aSHT, online: baseAOnline, depth: 2),
                Module(uuid: bSHT, base: baseB, parent: baseB, online: true, depth: 1),
                Module(uuid: bPMS, base: baseB, parent: bSHT, online: true, depth: 2),
            ]
        )
    }
}

final class MultiPowerBaseDecodingTests: XCTestCase {
    typealias F = MultiPowerBaseFixtures

    func testTwoBasesDecodeWithTheirOwnModules() throws {
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: F.twoBases())

        XCTAssertTrue(snapshot.reportsPowerBases)
        XCTAssertEqual(snapshot.powerBases.map(\.hardwareIdentifier), [F.baseA, F.baseB])
        XCTAssertEqual(snapshot.modules.count, 4)
        XCTAssertEqual(Set(snapshot.modules.map(\.id)).count, 4, "same-kind modules on two Bases never share an id")

        let baseA = try XCTUnwrap(snapshot.powerBases.first)
        let baseB = try XCTUnwrap(snapshot.powerBases.last)
        XCTAssertEqual(snapshot.modules(on: baseA).compactMap(\.hardwareIdentifier), [F.aSHT, F.aPMS])
        XCTAssertEqual(snapshot.modules(on: baseB).compactMap(\.hardwareIdentifier), [F.bSHT, F.bPMS])
        XCTAssertTrue(snapshot.modulesWithoutPowerBase.isEmpty)
        XCTAssertNotEqual(baseA.id, baseB.id)
        XCTAssertEqual(baseA.shortLabel, "Power Base ··0001")
    }

    func testChainRelationsComeFromParentLinks() throws {
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: F.twoBases())
        let pmsB = try XCTUnwrap(snapshot.modules.first { $0.hardwareIdentifier == F.bPMS })
        let shtB = try XCTUnwrap(snapshot.modules.first { $0.hardwareIdentifier == F.bSHT })

        XCTAssertTrue(shtB.isDirectlyOnPowerBase)
        XCTAssertFalse(pmsB.isDirectlyOnPowerBase)
        XCTAssertEqual(snapshot.parentModule(of: pmsB)?.hardwareIdentifier, F.bSHT, "B's PMS is behind B's SHT, not A's")
        XCTAssertNil(snapshot.parentModule(of: shtB))
    }

    func testChainOrderFollowsParentsNotListOrderOrDepth() throws {
        // Listed leaf-first, and with a depth that contradicts the parent link on purpose.
        let data = F.snapshot(
            bases: [F.base(F.baseA, online: true, modules: 2, onlineModules: 2)],
            modules: [
                .init(uuid: F.aPMS, base: F.baseA, parent: F.aSHT, online: true, depth: 1),
                .init(uuid: F.aSHT, base: F.baseA, parent: F.baseA, online: true, depth: 2),
            ]
        )
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: data)
        let base = try XCTUnwrap(snapshot.powerBases.first)
        XCTAssertEqual(snapshot.chainOrderedModules(on: base).compactMap(\.hardwareIdentifier), [F.aSHT, F.aPMS])
    }

    func testModulesOfAnOfflineBaseSayWhy() throws {
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: F.twoBases(baseAOnline: false))
        let shtA = try XCTUnwrap(snapshot.modules.first { $0.hardwareIdentifier == F.aSHT })
        let shtB = try XCTUnwrap(snapshot.modules.first { $0.hardwareIdentifier == F.bSHT })

        XCTAssertFalse(shtA.isOnline)
        XCTAssertTrue(snapshot.isOfflineBecausePowerBaseIsOffline(shtA))
        XCTAssertTrue(shtB.isOnline)
        XCTAssertFalse(snapshot.isOfflineBecausePowerBaseIsOffline(shtB))
        XCTAssertEqual(snapshot.powerBases.first?.onlineModuleCount, 0)
    }

    func testABaseWithNoModulesYetIsStillListed() throws {
        let data = F.snapshot(bases: [F.base(F.baseB, online: true, modules: 0, onlineModules: 0)], modules: [])
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: data)
        XCTAssertEqual(snapshot.powerBases.map(\.hardwareIdentifier), [F.baseB])
        XCTAssertTrue(snapshot.modules.isEmpty)
    }

    func testSingleBaseBridgeWithoutPowerBaseFieldsDecodesAsBefore() throws {
        let legacy = try PogoSnapshotMapper.decodeSnapshot(from: PogoAPIFixtures.realCapturedSnapshotJSON)

        XCTAssertFalse(legacy.reportsPowerBases, "a missing power_bases field means unknown, not zero Bases")
        XCTAssertTrue(legacy.powerBases.isEmpty)
        XCTAssertEqual(legacy.modules.count, 2)
        XCTAssertTrue(legacy.modules.allSatisfy { $0.powerBaseIdentifier == nil && $0.parentIdentifier == nil })
        XCTAssertEqual(legacy.modulesWithoutPowerBase.count, 2)
        XCTAssertEqual(
            legacy.modules.map(\.id),
            [PogoAPIFixtures.sgp41UUID, PogoAPIFixtures.pms5003UUID].map(ModuleIdentity.stableUUID(forRawIdentifier:)),
            "module ids — the key for saved names and rooms — are unchanged"
        )
    }

    func testTheSameModuleKeepsItsIdWhateverBaseItIsOn() throws {
        let onA = try PogoSnapshotMapper.decodeSnapshot(from: F.twoBases())
        let moved = F.snapshot(
            bases: [F.base(F.baseB, online: true, modules: 1, onlineModules: 1)],
            modules: [.init(uuid: F.aSHT, base: F.baseB, parent: F.baseB, online: true, depth: 1)]
        )
        let onB = try PogoSnapshotMapper.decodeSnapshot(from: moved)
        XCTAssertEqual(
            onA.modules.first { $0.hardwareIdentifier == F.aSHT }?.id,
            onB.modules.first?.id
        )
        XCTAssertEqual(onB.modules.first?.powerBaseIdentifier, F.baseB)
    }

    func testInvalidOrDuplicatePowerBaseIdentifiersAreRejected() {
        let invalid = F.snapshot(bases: [F.base("not-hex", online: true, modules: 0, onlineModules: 0)], modules: [])
        XCTAssertThrowsError(try PogoSnapshotMapper.decodeSnapshot(from: invalid)) {
            XCTAssertEqual($0 as? PogoAPIError, .invalidPowerBaseIdentifier("not-hex"))
        }
        let duplicate = F.snapshot(
            bases: [
                F.base(F.baseA, online: true, modules: 0, onlineModules: 0),
                F.base(F.baseA, online: false, modules: 0, onlineModules: 0),
            ],
            modules: []
        )
        XCTAssertThrowsError(try PogoSnapshotMapper.decodeSnapshot(from: duplicate)) {
            XCTAssertEqual($0 as? PogoAPIError, .duplicatePowerBaseIdentifier(F.baseA))
        }
    }

    func testDiscoveryReportsOnlyBasesThatAppearedAfterTheBaseline() throws {
        let before = try PogoSnapshotMapper.decodeSnapshot(
            from: F.snapshot(bases: [F.base(F.baseA, online: true, modules: 0, onlineModules: 0)], modules: [])
        )
        let discovery = PowerBaseDiscovery(baseline: before)
        XCTAssertTrue(discovery.newPowerBases(in: before).isEmpty)

        let after = try PogoSnapshotMapper.decodeSnapshot(from: F.twoBases())
        XCTAssertEqual(discovery.newPowerBases(in: after).map(\.hardwareIdentifier), [F.baseB])

        let legacy = try PogoSnapshotMapper.decodeSnapshot(from: PogoAPIFixtures.realCapturedSnapshotJSON)
        XCTAssertTrue(PowerBaseDiscovery(baseline: legacy).newPowerBases(in: legacy).isEmpty)
    }
}

/// AppModel + LiveSensorDataSource wired as in the app, driven over SSE.
@MainActor
final class MultiPowerBaseLiveTests: XCTestCase {
    typealias F = MultiPowerBaseFixtures
    private let endpoint = PogoAPIEndpoint(baseURL: URL(string: "http://test.local")!)

    private func id(_ raw: String) -> UUID { ModuleIdentity.stableUUID(forRawIdentifier: raw) }

    func testOneBaseOfflineAndBackThroughSSEAndAnAppReconnectKeepsNamesAndRooms() async throws {
        let transport = ControllableSensorAPITransport { F.twoBases() }
        let source = LiveSensorDataSource(endpoint: endpoint, transport: transport, sleeper: RecordingSleeper(), livenessIdleTimeout: 5)
        let store = InMemoryHomeConfigurationStore()
        let model = AppModel(dataSource: source, configurationStore: store)
        model.start()
        defer { model.stop() }

        try await waitUntil { model.snapshot.modules.count == 4 && model.snapshot.powerBases.count == 2 }
        try await model.updateModule(id: id(F.aSHT), customName: "거실 온습도", roomID: HomeConfigurationDefaults.livingRoom.id)
        try await model.updateModule(id: id(F.bSHT), customName: "침실 온습도", roomID: HomeConfigurationDefaults.bedroom.id)

        // Base A drops off the bridge; B carries on.
        try await waitUntil { await transport.hasOpenEventStream }
        await transport.sendLines(PogoAPIFixtures.sseSnapshotEvent(json: F.twoBases(baseAOnline: false)))
        try await waitUntil { model.snapshot.powerBases.first?.isOnline == false }
        let aOffline = try XCTUnwrap(model.module(with: id(F.aSHT)))
        XCTAssertFalse(aOffline.isOnline)
        XCTAssertTrue(model.snapshot.isOfflineBecausePowerBaseIsOffline(aOffline))
        XCTAssertEqual(aOffline.name, "거실 온습도", "an offline Base's module keeps its name")
        XCTAssertEqual(aOffline.roomID, HomeConfigurationDefaults.livingRoom.id)
        XCTAssertEqual(model.module(with: id(F.bSHT))?.isOnline, true)
        XCTAssertEqual(model.snapshot.modules.count, 4, "nothing disappears while a Base is offline")

        // The app's SSE connection drops; by the time it reconnects, Base A is back.
        await transport.setSnapshotProvider { F.twoBases() }
        let sessions = await transport.eventStreamOpenCount
        await transport.finishCurrentEventStream()
        try await waitUntil { await transport.hasOpenEventStream(after: sessions) }
        try await waitUntil { model.snapshot.powerBases.allSatisfy(\.isOnline) }

        let aBack = try XCTUnwrap(model.module(with: id(F.aSHT)))
        XCTAssertTrue(aBack.isOnline)
        XCTAssertEqual(aBack.name, "거실 온습도")
        XCTAssertEqual(aBack.roomID, HomeConfigurationDefaults.livingRoom.id)
        XCTAssertEqual(model.module(with: id(F.bSHT))?.name, "침실 온습도")
        XCTAssertEqual(model.module(with: id(F.bSHT))?.roomID, HomeConfigurationDefaults.bedroom.id)
        XCTAssertEqual(aBack.powerBaseIdentifier, F.baseA)
    }

    func testModuleMovedToTheOtherBaseKeepsNameRoomAndAppearsOnce() async throws {
        let transport = ControllableSensorAPITransport { F.twoBases() }
        let source = LiveSensorDataSource(endpoint: endpoint, transport: transport, sleeper: RecordingSleeper(), livenessIdleTimeout: 5)
        let model = AppModel(dataSource: source, configurationStore: InMemoryHomeConfigurationStore())
        model.start()
        defer { model.stop() }

        try await waitUntil { model.snapshot.modules.count == 4 }
        try await model.updateModule(id: id(F.aPMS), customName: "주방 미세먼지", roomID: HomeConfigurationDefaults.workspace.id)

        // A's PMS5003 is undocked and docked behind B's PMS5003.
        let moved = F.snapshot(
            bases: [
                F.base(F.baseA, online: true, modules: 1, onlineModules: 1),
                F.base(F.baseB, online: true, modules: 3, onlineModules: 3),
            ],
            modules: [
                .init(uuid: F.aSHT, base: F.baseA, parent: F.baseA, online: true, depth: 1),
                .init(uuid: F.bSHT, base: F.baseB, parent: F.baseB, online: true, depth: 1),
                .init(uuid: F.bPMS, base: F.baseB, parent: F.bSHT, online: true, depth: 2),
                .init(uuid: F.aPMS, base: F.baseB, parent: F.bPMS, online: true, depth: 3),
            ]
        )
        try await waitUntil { await transport.hasOpenEventStream }
        await transport.sendLines(PogoAPIFixtures.sseSnapshotEvent(json: moved))
        try await waitUntil { model.module(with: self.id(F.aPMS))?.powerBaseIdentifier == F.baseB }

        let module = try XCTUnwrap(model.module(with: id(F.aPMS)))
        XCTAssertEqual(module.name, "주방 미세먼지")
        XCTAssertEqual(module.roomID, HomeConfigurationDefaults.workspace.id)
        XCTAssertEqual(model.snapshot.modules.filter { $0.id == module.id }.count, 1)
        let baseB = try XCTUnwrap(model.snapshot.powerBases.last)
        XCTAssertEqual(
            model.snapshot.chainOrderedModules(on: baseB).compactMap(\.hardwareIdentifier),
            [F.bSHT, F.bPMS, F.aPMS]
        )
    }

    func testANewBaseWithTopologyButNoSampleYetDoesNotReplaceTheCompleteView() async throws {
        let transport = ControllableSensorAPITransport {
            F.snapshot(
                bases: [F.base(F.baseA, online: true, modules: 1, onlineModules: 1)],
                modules: [.init(uuid: F.aSHT, base: F.baseA, parent: F.baseA, online: true, depth: 1)]
            )
        }
        let source = LiveSensorDataSource(endpoint: endpoint, transport: transport, sleeper: RecordingSleeper(), livenessIdleTimeout: 5)
        let model = AppModel(dataSource: source)
        model.start()
        defer { model.stop() }
        try await waitUntil { model.snapshot.modules.count == 1 }

        // Base B appears; its module's topology arrives before its first sample.
        let topologyOnly = F.snapshot(
            bases: [
                F.base(F.baseA, online: true, modules: 1, onlineModules: 1),
                F.base(F.baseB, online: true, modules: 1, onlineModules: 1),
            ],
            modules: [
                .init(uuid: F.aSHT, base: F.baseA, parent: F.baseA, online: true, depth: 1),
                .init(uuid: F.bSHT, base: F.baseB, parent: F.baseB, online: true, depth: 1, withReadings: false),
            ]
        )
        try await waitUntil { await transport.hasOpenEventStream }
        await transport.sendLines(PogoAPIFixtures.sseSnapshotEvent(json: topologyOnly))
        try await waitUntil { model.isRegistryRecovering }
        XCTAssertEqual(model.snapshot.modules.count, 1, "the half-arrived module is held back, as with a single Base")

        let complete = F.snapshot(
            bases: [
                F.base(F.baseA, online: true, modules: 1, onlineModules: 1),
                F.base(F.baseB, online: true, modules: 1, onlineModules: 1),
            ],
            modules: [
                .init(uuid: F.aSHT, base: F.baseA, parent: F.baseA, online: true, depth: 1),
                .init(uuid: F.bSHT, base: F.baseB, parent: F.baseB, online: true, depth: 1),
            ]
        )
        await transport.sendLines(PogoAPIFixtures.sseSnapshotEvent(json: complete))
        try await waitUntil { model.snapshot.modules.count == 2 && !model.isRegistryRecovering }
        XCTAssertEqual(model.snapshot.powerBases.count, 2)
    }

    func testSavedNamesAndRoomsSurviveBridgeUpgradeAndAppRelaunch() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("multi-base-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let sgp41 = id(PogoAPIFixtures.sgp41UUID)

        // Before: an old single-Base bridge (no Power Base fields). The user names a module.
        do {
            let transport = ControllableSensorAPITransport { PogoAPIFixtures.realCapturedSnapshotJSON }
            let source = LiveSensorDataSource(endpoint: endpoint, transport: transport, sleeper: RecordingSleeper(), livenessIdleTimeout: 5)
            let model = AppModel(dataSource: source, configurationStore: try SwiftDataHomeConfigurationStore(url: storeURL))
            model.start()
            try await waitUntil { model.snapshot.modules.count == 2 }
            try await model.updateModule(id: sgp41, customName: "현관 가스", roomID: HomeConfigurationDefaults.livingRoom.id)
            model.stop()
        }

        // After: the bridge is upgraded (same module now reported under a Power Base) and the
        // app is relaunched with the same on-disk store.
        let upgraded = F.snapshot(
            bases: [F.base(F.baseA, online: true, modules: 1, onlineModules: 1)],
            modules: [.init(uuid: PogoAPIFixtures.sgp41UUID, base: F.baseA, parent: F.baseA, online: true, depth: 1)]
        )
        let transport = ControllableSensorAPITransport { upgraded }
        let source = LiveSensorDataSource(endpoint: endpoint, transport: transport, sleeper: RecordingSleeper(), livenessIdleTimeout: 5)
        let model = AppModel(dataSource: source, configurationStore: try SwiftDataHomeConfigurationStore(url: storeURL))
        model.start()
        defer { model.stop() }
        try await waitUntil { model.snapshot.powerBases.count == 1 }

        let module = try XCTUnwrap(model.module(with: sgp41))
        XCTAssertEqual(module.name, "현관 가스")
        XCTAssertEqual(module.roomID, HomeConfigurationDefaults.livingRoom.id)
        XCTAssertEqual(module.powerBaseIdentifier, F.baseA)
    }
}
