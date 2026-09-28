import Foundation

/// Canned Apple Home data for SwiftUI previews only — never used by the running app, which
/// always gets `AppleHomeProviderFactory.makeDefault()`.
@MainActor
final class PreviewAppleHomeProvider: AppleHomeProvider {
    private var onChange: (@MainActor (AppleHomeSnapshot) -> Void)?
    private var snapshot: AppleHomeSnapshot

    init(snapshot: AppleHomeSnapshot = PreviewAppleHomeProvider.sampleSnapshot) {
        self.snapshot = snapshot
    }

    var isAccessorySetupAvailable: Bool { true }

    func start(onChange: @escaping @MainActor (AppleHomeSnapshot) -> Void) {
        self.onChange = onChange
        onChange(snapshot)
    }

    func stop() { onChange = nil }

    func refresh(accessoryID: UUID) async throws {
        onChange?(snapshot)
    }

    func write(_ value: AppleHomeRawValue, characteristicID: UUID, accessoryID: UUID) async throws {
        throw AppleHomeProviderError.underlying("Preview")
    }

    func performAccessorySetup() async throws -> AppleHomeSetupResult {
        throw AppleHomeProviderError.cancelled
    }

    static let homeID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!

    static var sampleSnapshot: AppleHomeSnapshot {
        let now = Date()
        let light = AppleHomeAccessory(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000010")!,
            homeID: homeID,
            name: "거실 조명",
            roomID: UUID(uuidString: "A0000000-0000-0000-0000-0000000000B1")!,
            roomName: "거실",
            isReachable: true,
            isMatter: true,
            categoryDescription: "Lightbulb",
            manufacturer: "Example",
            model: "Matter Bulb",
            services: [
                AppleHomeService(
                    id: UUID(),
                    kind: .lightbulb,
                    name: "거실 조명",
                    characteristics: [
                        AppleHomeCharacteristic(id: UUID(), kind: .powerState, isWritable: true, value: .bool(true), confirmedAt: now),
                        AppleHomeCharacteristic(id: UUID(), kind: .brightness, isWritable: true, value: .int(60), confirmedAt: now, minimumValue: 0, maximumValue: 100),
                    ]
                ),
            ]
        )
        let sensor = AppleHomeAccessory(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000020")!,
            homeID: homeID,
            name: "PMS5003",
            roomID: UUID(uuidString: "A0000000-0000-0000-0000-0000000000B2")!,
            roomName: "침실",
            isReachable: true,
            isBridged: true,
            isMatter: true,
            services: [
                AppleHomeService(id: UUID(), kind: .temperatureSensor, name: "온도", characteristics: [
                    AppleHomeCharacteristic(id: UUID(), kind: .currentTemperature, value: .double(23.4), confirmedAt: now),
                ]),
                AppleHomeService(id: UUID(), kind: .other, name: "", typeDescription: "Identify", characteristics: []),
            ]
        )
        let outlet = AppleHomeAccessory(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000030")!,
            homeID: homeID,
            name: "책상 콘센트",
            roomID: UUID(uuidString: "A0000000-0000-0000-0000-0000000000B3")!,
            roomName: "서재",
            isReachable: false,
            isMatter: true,
            services: [
                AppleHomeService(id: UUID(), kind: .outlet, name: "책상 콘센트", characteristics: [
                    AppleHomeCharacteristic(id: UUID(), kind: .powerState, isWritable: true, value: .bool(false), confirmedAt: now.addingTimeInterval(-3600)),
                ]),
            ]
        )
        return AppleHomeSnapshot(
            accessState: .ready,
            homes: [AppleHomeInfo(id: homeID, name: "우리 집", isPrimary: true, hubState: .connected)],
            accessories: [light, sensor, outlet]
        )
    }
}

extension AppleHomeModel {
    static var preview: AppleHomeModel {
        let model = AppleHomeModel(
            provider: PreviewAppleHomeProvider(),
            defaults: UserDefaults(suiteName: "PogoHome.preview.appleHome") ?? .standard
        )
        model.enable()
        return model
    }
}
