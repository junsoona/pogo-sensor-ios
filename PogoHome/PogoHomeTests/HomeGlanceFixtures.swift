import Foundation
@testable import PogoHome

/// POGO/Apple Home inputs for the widget glance tests. The Apple Home light and sensor come
/// from `AppleHomeFixtures`; `sameNameAccessory` deliberately shares its name — and even its
/// UUID value — with a POGO module.
enum GlanceFixtures {
    static let room = Room(id: UUID(uuidString: "20000000-0000-0000-0000-0000000000A1")!, name: "거실", symbolName: "sofa.fill", sortOrder: 0)
    static let climateID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    static let airID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func climate(online: Bool = true, temperature: Double = 23.4, status: SensorStatus = .normal, name: String = "거실 센서") -> SensorModule {
        SensorModule(
            id: climateID,
            name: name,
            roomID: room.id,
            readings: [
                SensorReading(kind: .temperature, value: temperature, timestamp: t0, status: status),
                SensorReading(kind: .humidity, value: 48, timestamp: t0, status: .normal),
            ],
            isOnline: online,
            lastSeen: t0
        )
    }

    static func air(online: Bool = true, readings: Bool = true) -> SensorModule {
        SensorModule(
            id: airID,
            name: "공기질 모듈",
            roomID: room.id,
            readings: readings ? [SensorReading(kind: .pm2_5, value: 7, timestamp: t0, status: .normal)] : [],
            isOnline: online,
            lastSeen: t0
        )
    }

    static func home(_ modules: [SensorModule]) -> HomeSnapshot {
        HomeSnapshot(timestamp: t0, rooms: [room, ModuleCatalog.unspecifiedRoom(in: .korean)], modules: modules)
    }

    static func pogoInput(
        _ snapshot: HomeSnapshot,
        health: HomeHealthState = .healthy,
        connection: DataSourceConnectionStatus = .connected,
        lastSyncAt: Date? = t0,
        sessionStartedAt: Date = t0.addingTimeInterval(-10),
        isSimulated: Bool = false,
        source: SensorSourceIdentity? = nil
    ) -> HomeGlanceBuilder.PogoInput {
        HomeGlanceBuilder.PogoInput(
            snapshot: snapshot,
            health: health,
            connectionStatus: connection,
            lastSyncAt: lastSyncAt,
            isSimulated: isSimulated,
            sessionStartedAt: sessionStartedAt,
            source: source ?? (isSimulated ? .simulated : hubSource)
        )
    }

    /// The hub the glance tests' live data comes from — the Watch fixtures' bridge address.
    static let hubSource = SensorSourceIdentity.hub(URL(string: "http://192.168.50.129:8787")!)

    static func appleHomeInput(
        _ accessories: [AppleHomeAccessory] = [AppleHomeFixtures.light(), AppleHomeFixtures.sensor()],
        state: AppleHomeAccessState = .ready,
        isEnabled: Bool = true
    ) -> HomeGlanceBuilder.AppleHomeInput {
        HomeGlanceBuilder.AppleHomeInput(isEnabled: isEnabled, accessState: state, visibleAccessories: state == .ready ? accessories : [])
    }

    /// An Apple Home accessory named exactly like the POGO climate module, with the same UUID
    /// value as its id.
    static func sameNameAccessory() -> AppleHomeAccessory {
        AppleHomeAccessory(
            id: climateID,
            homeID: AppleHomeFixtures.homeID,
            name: "거실 센서",
            roomID: AppleHomeFixtures.livingRoomID,
            roomName: "거실",
            isReachable: true,
            isBridged: true,
            isMatter: true,
            services: [
                AppleHomeService(id: UUID(), kind: .temperatureSensor, name: "온도", characteristics: [
                    AppleHomeCharacteristic(id: sameNameTemperatureID, kind: .currentTemperature, value: .double(22.0), confirmedAt: t0),
                ]),
            ]
        )
    }

    static let sameNameTemperatureID = UUID(uuidString: "20000000-0000-0000-0000-0000000000C1")!

    static func build(
        pogo: HomeGlanceBuilder.PogoInput,
        appleHome: HomeGlanceBuilder.AppleHomeInput = appleHomeInput(),
        previous: HomeGlanceSnapshot? = nil,
        now: Date = t0
    ) -> HomeGlanceSnapshot {
        HomeGlanceBuilder.build(homeName: "우리 집", pogo: pogo, appleHome: appleHome, previous: previous, now: now)
    }

    static var temperatureID: HomeGlanceValueID { .pogo(module: climateID, kind: .temperature) }
    static var appleHomeTemperatureID: HomeGlanceValueID {
        .appleHome(accessory: AppleHomeFixtures.sensorID, characteristic: AppleHomeFixtures.temperatureID)
    }
}
