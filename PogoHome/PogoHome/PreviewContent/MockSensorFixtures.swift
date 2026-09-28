import Foundation

/// Deterministic fixture data shared by `MockSensorDataSource` (as its starting point)
/// and by SwiftUI previews. Room and module identifiers are fixed UUID literals so they
/// stay stable across app launches and preview runs. The rooms are the app's default rooms
/// (same ids), and every name here is mock "hardware" text shown in the current UI language.
enum MockSensorFixtures {
    static var livingRoom: Room { HomeConfigurationDefaults.livingRoom }
    static var bedroom: Room { HomeConfigurationDefaults.bedroom }
    static var studio: Room { HomeConfigurationDefaults.workspace }

    static var rooms: [Room] { [livingRoom, bedroom, studio] }

    static let livingRoomEnvironmentModuleID = UUID(uuidString: "8A3B1C10-0011-4000-8000-000000000011")!
    static let livingRoomAirQualityModuleID = UUID(uuidString: "8A3B1C10-0012-4000-8000-000000000012")!
    static let bedroomLightModuleID = UUID(uuidString: "8A3B1C10-0013-4000-8000-000000000013")!
    static let studioGasModuleID = UUID(uuidString: "8A3B1C10-0014-4000-8000-000000000014")!

    /// A fixed reference date so previews render identical content every time.
    static let previewReferenceDate = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static var previewSnapshot: HomeSnapshot {
        HomeSnapshot(
            timestamp: previewReferenceDate,
            rooms: rooms,
            modules: modules(referenceDate: previewReferenceDate)
        )
    }

    /// Builds the four seed modules relative to `referenceDate`, so the mock data source
    /// can call this with `Date()` at launch while previews pass a fixed date.
    static func modules(referenceDate: Date) -> [SensorModule] {
        [
            SensorModule(
                id: livingRoomEnvironmentModuleID,
                name: String(localized: "거실 환경 모듈", comment: "Mock data module name"),
                roomID: livingRoom.id,
                readings: [
                    SensorReading(
                        kind: .temperature,
                        value: 23.4,
                        timestamp: referenceDate,
                        status: .normal
                    ),
                    SensorReading(
                        kind: .humidity,
                        value: 48.0,
                        timestamp: referenceDate,
                        status: .normal
                    ),
                ],
                isOnline: true,
                lastSeen: referenceDate,
                roleDescription: String(localized: "환경 센서", comment: "Mock data module role")
            ),
            SensorModule(
                id: livingRoomAirQualityModuleID,
                name: String(localized: "거실 공기질 모듈", comment: "Mock data module name"),
                roomID: livingRoom.id,
                readings: [
                    SensorReading(kind: .pm1, value: 4.0, timestamp: referenceDate, status: .normal),
                    SensorReading(kind: .pm2_5, value: 7.0, timestamp: referenceDate, status: .normal),
                    SensorReading(
                        kind: .pm10,
                        value: 11.0,
                        timestamp: referenceDate,
                        status: .conditioning
                    ),
                ],
                isOnline: true,
                lastSeen: referenceDate,
                roleDescription: String(localized: "공기질 센서", comment: "Mock data module role")
            ),
            SensorModule(
                id: bedroomLightModuleID,
                name: String(localized: "침실 조도 모듈", comment: "Mock data module name"),
                roomID: bedroom.id,
                readings: [
                    SensorReading(
                        kind: .illuminance,
                        value: 120.0,
                        timestamp: referenceDate.addingTimeInterval(-40 * 60),
                        status: .stale
                    )
                ],
                isOnline: true,
                lastSeen: referenceDate.addingTimeInterval(-40 * 60),
                roleDescription: String(localized: "조도 센서", comment: "Mock data module role")
            ),
            SensorModule(
                id: studioGasModuleID,
                name: String(localized: "작업실 가스 센서 모듈", comment: "Mock data module name"),
                roomID: studio.id,
                readings: [
                    SensorReading(
                        kind: .vocRaw,
                        value: 0,
                        timestamp: referenceDate.addingTimeInterval(-15 * 60),
                        status: .unavailable
                    ),
                    SensorReading(
                        kind: .vocIndex,
                        value: 0,
                        timestamp: referenceDate.addingTimeInterval(-15 * 60),
                        status: .unavailable
                    ),
                    SensorReading(
                        kind: .noxRaw,
                        value: 0,
                        timestamp: referenceDate.addingTimeInterval(-15 * 60),
                        status: .unavailable
                    ),
                    SensorReading(
                        kind: .noxIndex,
                        value: 0,
                        timestamp: referenceDate.addingTimeInterval(-15 * 60),
                        status: .unavailable
                    ),
                ],
                isOnline: false,
                lastSeen: referenceDate.addingTimeInterval(-15 * 60),
                roleDescription: String(localized: "가스 센서", comment: "Mock data module role")
            ),
        ]
    }
}
