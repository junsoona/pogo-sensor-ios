import Foundation

/// Deterministic fixture data shared by `MockSensorDataSource` (as its starting point)
/// and by SwiftUI previews. Room and module identifiers are fixed UUID literals so they
/// stay stable across app launches and preview runs.
enum MockSensorFixtures {
    static let livingRoom = Room(
        id: UUID(uuidString: "8A3B1C10-0001-4000-8000-000000000001")!,
        name: "거실",
        symbolName: "sofa.fill",
        sortOrder: 0
    )

    static let bedroom = Room(
        id: UUID(uuidString: "8A3B1C10-0002-4000-8000-000000000002")!,
        name: "침실",
        symbolName: "bed.double.fill",
        sortOrder: 1
    )

    static let studio = Room(
        id: UUID(uuidString: "8A3B1C10-0003-4000-8000-000000000003")!,
        name: "작업실",
        symbolName: "desktopcomputer",
        sortOrder: 2
    )

    static let rooms: [Room] = [livingRoom, bedroom, studio]

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
                name: "거실 환경 모듈",
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
                roleDescription: "환경 센서"
            ),
            SensorModule(
                id: livingRoomAirQualityModuleID,
                name: "거실 공기질 모듈",
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
                roleDescription: "공기질 센서"
            ),
            SensorModule(
                id: bedroomLightModuleID,
                name: "침실 조도 모듈",
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
                roleDescription: "조도 센서"
            ),
            SensorModule(
                id: studioGasModuleID,
                name: "작업실 가스 센서 모듈",
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
                roleDescription: "가스 센서"
            ),
        ]
    }
}
