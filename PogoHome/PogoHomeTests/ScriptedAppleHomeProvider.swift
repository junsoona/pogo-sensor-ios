import Foundation
@testable import PogoHome

/// Apple Home fixtures: a dimmable light, a read-only light, a temperature sensor, and a lock.
enum AppleHomeFixtures {
    static let homeID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    static let lightID = UUID(uuidString: "10000000-0000-0000-0000-000000000010")!
    static let lightPowerID = UUID(uuidString: "10000000-0000-0000-0000-000000000011")!
    static let lightBrightnessID = UUID(uuidString: "10000000-0000-0000-0000-000000000012")!
    static let readOnlyLightID = UUID(uuidString: "10000000-0000-0000-0000-000000000020")!
    static let readOnlyPowerID = UUID(uuidString: "10000000-0000-0000-0000-000000000021")!
    static let sensorID = UUID(uuidString: "10000000-0000-0000-0000-000000000030")!
    static let temperatureID = UUID(uuidString: "10000000-0000-0000-0000-000000000031")!
    static let lockID = UUID(uuidString: "10000000-0000-0000-0000-000000000040")!
    static let lockStateID = UUID(uuidString: "10000000-0000-0000-0000-000000000041")!
    static let readAt = Date(timeIntervalSince1970: 1_800_000_000)
    static let livingRoomID = UUID(uuidString: "10000000-0000-0000-0000-0000000000A1")!
    static let bedroomID = UUID(uuidString: "10000000-0000-0000-0000-0000000000A2")!

    static func light(
        power: AppleHomeRawValue? = .bool(false),
        brightness: AppleHomeRawValue? = .int(40),
        reachable: Bool = true,
        blocked: Bool = false,
        name: String = "거실 조명",
        roomID: UUID? = livingRoomID,
        roomName: String? = "거실",
        powerConfirmedAt: Date = readAt
    ) -> AppleHomeAccessory {
        AppleHomeAccessory(
            id: lightID,
            homeID: homeID,
            name: name,
            roomID: roomID,
            roomName: roomName,
            isReachable: reachable,
            isBlocked: blocked,
            isMatter: true,
            services: [
                AppleHomeService(id: UUID(), kind: .accessoryInformation, name: "Info", characteristics: []),
                AppleHomeService(
                    id: UUID(uuidString: "10000000-0000-0000-0000-00000000001F")!,
                    kind: .lightbulb,
                    name: "천장등",
                    characteristics: [
                        AppleHomeCharacteristic(id: lightPowerID, kind: .powerState, isWritable: true, supportsNotification: true, value: power, confirmedAt: power == nil ? nil : powerConfirmedAt),
                        AppleHomeCharacteristic(id: lightBrightnessID, kind: .brightness, isWritable: true, value: brightness, confirmedAt: brightness == nil ? nil : readAt, minimumValue: 0, maximumValue: 100),
                    ]
                ),
            ]
        )
    }

    /// A light whose PowerState HomeKit exposes as readable but not writable.
    static func readOnlyLight() -> AppleHomeAccessory {
        AppleHomeAccessory(
            id: readOnlyLightID,
            homeID: homeID,
            name: "읽기 전용 조명",
            isReachable: true,
            services: [
                AppleHomeService(id: UUID(), kind: .lightbulb, name: "조명", characteristics: [
                    AppleHomeCharacteristic(id: readOnlyPowerID, kind: .powerState, isWritable: false, value: .bool(true), confirmedAt: readAt),
                ]),
            ]
        )
    }

    static func sensor(temperature: Double? = 23.4, name: String = "PMS5003") -> AppleHomeAccessory {
        AppleHomeAccessory(
            id: sensorID,
            homeID: homeID,
            name: name,
            roomID: bedroomID,
            roomName: "침실",
            isReachable: true,
            isBridged: true,
            isMatter: true,
            services: [
                AppleHomeService(id: UUID(), kind: .temperatureSensor, name: "온도", characteristics: [
                    AppleHomeCharacteristic(id: temperatureID, kind: .currentTemperature, value: temperature.map(AppleHomeRawValue.double), confirmedAt: temperature == nil ? nil : readAt),
                ]),
                AppleHomeService(id: UUID(), kind: .other, name: "", typeDescription: "Identify", characteristics: [], unsupportedCharacteristicCount: 1),
            ]
        )
    }

    /// Lock state is readable; PogoHome never offers lock control.
    static func lock() -> AppleHomeAccessory {
        AppleHomeAccessory(
            id: lockID,
            homeID: homeID,
            name: "현관 잠금장치",
            isReachable: true,
            services: [
                AppleHomeService(id: UUID(), kind: .lockMechanism, name: "현관", characteristics: [
                    AppleHomeCharacteristic(id: lockStateID, kind: .currentLockMechanismState, value: .int(1), confirmedAt: readAt),
                ]),
            ]
        )
    }

    static func ready(_ accessories: [AppleHomeAccessory]) -> AppleHomeSnapshot {
        AppleHomeSnapshot(
            accessState: .ready,
            homes: [AppleHomeInfo(id: homeID, name: "우리 집", isPrimary: true, hubState: .connected)],
            accessories: accessories
        )
    }
}

/// A provider whose every answer the test decides.
@MainActor
final class ScriptedAppleHomeProvider: AppleHomeProvider {
    var snapshot: AppleHomeSnapshot
    var isAccessorySetupAvailable = true
    var writeError: Error?
    var refreshError: Error?
    /// What the device reports after a successful write; `nil` = the device keeps reporting
    /// its old state.
    var snapshotAfterWrite: ((AppleHomeRawValue) -> AppleHomeSnapshot)?
    var setupResult: Result<AppleHomeSetupResult, Error> = .failure(AppleHomeProviderError.cancelled)
    /// When set, `write` suspends until `releaseWrite()`.
    var holdsWrites = false

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var refreshCount = 0
    private(set) var setupCount = 0
    private(set) var writes: [(value: AppleHomeRawValue, characteristicID: UUID, accessoryID: UUID)] = []
    /// Kept after `stop()` so a test can simulate a late HomeKit callback.
    private(set) var lastOnChange: (@MainActor (AppleHomeSnapshot) -> Void)?
    private var onChange: (@MainActor (AppleHomeSnapshot) -> Void)?
    private var writeGate: CheckedContinuation<Void, Never>?

    init(snapshot: AppleHomeSnapshot) {
        self.snapshot = snapshot
    }

    func start(onChange: @escaping @MainActor (AppleHomeSnapshot) -> Void) {
        startCount += 1
        self.onChange = onChange
        lastOnChange = onChange
        onChange(snapshot)
    }

    func stop() {
        stopCount += 1
        onChange = nil
    }

    func publish(_ next: AppleHomeSnapshot) {
        snapshot = next
        onChange?(next)
    }

    func refresh(accessoryID: UUID) async throws {
        refreshCount += 1
        if let refreshError { throw refreshError }
        onChange?(snapshot)
    }

    func write(_ value: AppleHomeRawValue, characteristicID: UUID, accessoryID: UUID) async throws {
        writes.append((value, characteristicID, accessoryID))
        if holdsWrites {
            await withCheckedContinuation { writeGate = $0 }
        }
        if let writeError { throw writeError }
        if let snapshotAfterWrite {
            snapshot = snapshotAfterWrite(value)
        }
    }

    var isHoldingWrite: Bool { writeGate != nil }

    func releaseWrite() {
        writeGate?.resume()
        writeGate = nil
    }

    func performAccessorySetup() async throws -> AppleHomeSetupResult {
        setupCount += 1
        return try setupResult.get()
    }
}

@MainActor
func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
    let suite = "PogoHomeTests.appleHome.\(name).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

/// Spins the main actor until `condition` holds (or fails after ~2s).
@MainActor
func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
