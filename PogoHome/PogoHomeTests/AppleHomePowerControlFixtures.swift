import Foundation
@testable import PogoHome

/// Accessories for the Control Center power toggle, on top of `AppleHomeFixtures`.
enum PowerControlFixtures {
    typealias F = AppleHomeFixtures

    static let outletID = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
    static let outletPowerID = UUID(uuidString: "50000000-0000-0000-0000-000000000011")!
    static let switchID = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
    static let switchPowerID = UUID(uuidString: "50000000-0000-0000-0000-000000000021")!
    static let stripID = UUID(uuidString: "50000000-0000-0000-0000-000000000003")!
    static let fanID = UUID(uuidString: "50000000-0000-0000-0000-000000000004")!
    static let fanPowerID = UUID(uuidString: "50000000-0000-0000-0000-000000000041")!
    static let purifierID = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
    static let otherHomeID = UUID(uuidString: "50000000-0000-0000-0000-0000000000FF")!

    static let lightTarget = AppleHomePowerTargetID(homeID: F.homeID, accessoryID: F.lightID, characteristicID: F.lightPowerID)
    static let outletTarget = AppleHomePowerTargetID(homeID: F.homeID, accessoryID: outletID, characteristicID: outletPowerID)

    static func outlet(reachable: Bool = true, power: AppleHomeRawValue? = .bool(true), powerWritable: Bool = true) -> AppleHomeAccessory {
        AppleHomeAccessory(
            id: outletID,
            homeID: F.homeID,
            name: "전기포트 플러그",
            roomID: F.bedroomID,
            roomName: "침실",
            isReachable: reachable,
            services: [
                AppleHomeService(id: UUID(), kind: .outlet, name: "플러그", characteristics: [
                    AppleHomeCharacteristic(id: outletPowerID, kind: .powerState, isWritable: powerWritable, value: power, confirmedAt: power == nil ? nil : F.readAt),
                    AppleHomeCharacteristic(id: UUID(), kind: .outletInUse, value: .bool(true), confirmedAt: F.readAt),
                ]),
            ]
        )
    }

    static func wallSwitch() -> AppleHomeAccessory {
        AppleHomeAccessory(id: switchID, homeID: F.homeID, name: "현관 스위치", isReachable: true, services: [
            AppleHomeService(id: UUID(), kind: .switch, name: "스위치", characteristics: [
                AppleHomeCharacteristic(id: switchPowerID, kind: .powerState, isWritable: true),
            ]),
        ])
    }

    /// Two outlets on one accessory: which one the toggle would switch is ambiguous.
    static func powerStrip(outletIDs: [UUID] = [UUID(), UUID()], id: UUID = stripID) -> AppleHomeAccessory {
        AppleHomeAccessory(id: id, homeID: F.homeID, name: "멀티탭", isReachable: true, services: outletIDs.map { outlet in
            AppleHomeService(id: UUID(), kind: .outlet, name: "콘센트", characteristics: [
                AppleHomeCharacteristic(id: outlet, kind: .powerState, isWritable: true),
            ])
        })
    }

    static func fan() -> AppleHomeAccessory {
        AppleHomeAccessory(id: fanID, homeID: F.homeID, name: "선풍기", isReachable: true, services: [
            AppleHomeService(id: UUID(), kind: .fan, name: "선풍기", characteristics: [
                AppleHomeCharacteristic(id: fanPowerID, kind: .powerState, isWritable: true),
            ]),
        ])
    }

    static func airPurifier() -> AppleHomeAccessory {
        AppleHomeAccessory(id: purifierID, homeID: F.homeID, name: "공기청정기", isReachable: true, services: [
            AppleHomeService(id: UUID(), kind: .airPurifier, name: "공기청정기", characteristics: [
                AppleHomeCharacteristic(id: UUID(), kind: .active, isWritable: true),
            ]),
        ])
    }

    static func catalog(
        availability: AppleHomePowerAvailability = .ready,
        targets: [AppleHomePowerTarget] = [lightEntry],
        states: [AppleHomePowerTargetID: AppleHomePowerState] = [:],
        knownNames: [String: String] = [:],
        writtenAt: Date = F.readAt
    ) -> AppleHomePowerCatalog {
        AppleHomePowerCatalog(
            writtenAt: writtenAt,
            availability: availability,
            targets: targets,
            states: Dictionary(uniqueKeysWithValues: states.map { ($0.key.stringValue, $0.value) }),
            knownNames: knownNames
        )
    }

    static let lightEntry = AppleHomePowerTarget(id: lightTarget, name: "거실 조명", roomName: "거실", homeName: "우리 집", kind: .light)
    static let outletEntry = AppleHomePowerTarget(id: outletTarget, name: "전기포트 플러그", roomName: "침실", homeName: "우리 집", kind: .outlet)
}

/// A HomeKit connection whose every answer the test decides.
@MainActor
final class ScriptedPowerGateway: AppleHomePowerGateway {
    var prepareError: Error?
    var accessories: [AppleHomeAccessory]
    /// What the device reports; `nil` = reads fail with `readFailure`.
    var deviceIsOn: Bool?
    var readFailure: Error = AppleHomePowerFailure.readFailed
    /// Read results used before `deviceIsOn`, first to last.
    var queuedReads: [Result<Bool, Error>] = []
    var writeError: Error?
    /// Whether a successful write changes what the device reports.
    var writeTakesEffect = true
    /// When set, `prepare` suspends until `releasePrepare()`.
    var holdsPrepare = false

    private(set) var prepareCount = 0
    private(set) var lookups: [(accessoryID: UUID, homeID: UUID)] = []
    private(set) var readCount = 0
    private(set) var writes: [(isOn: Bool, characteristicID: UUID, accessoryID: UUID)] = []
    private var prepareGate: CheckedContinuation<Void, Never>?

    init(accessories: [AppleHomeAccessory], deviceIsOn: Bool?) {
        self.accessories = accessories
        self.deviceIsOn = deviceIsOn
    }

    var isHoldingPrepare: Bool { prepareGate != nil }

    func releasePrepare() {
        prepareGate?.resume()
        prepareGate = nil
    }

    func prepare() async throws {
        prepareCount += 1
        if holdsPrepare {
            await withCheckedContinuation { prepareGate = $0 }
        }
        if let prepareError { throw prepareError }
    }

    func accessory(id: UUID, inHome homeID: UUID) -> AppleHomeAccessory? {
        lookups.append((id, homeID))
        return accessories.first { $0.id == id && $0.homeID == homeID }
    }

    func readPower(characteristicID: UUID, accessoryID: UUID) async throws -> Bool {
        readCount += 1
        if !queuedReads.isEmpty { return try queuedReads.removeFirst().get() }
        guard let deviceIsOn else { throw readFailure }
        return deviceIsOn
    }

    func writePower(_ isOn: Bool, characteristicID: UUID, accessoryID: UUID) async throws {
        writes.append((isOn, characteristicID, accessoryID))
        if let writeError { throw writeError }
        if writeTakesEffect { deviceIsOn = isOn }
    }
}

/// A catalog store in memory.
final class InMemoryPowerStore: AppleHomePowerStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AppleHomePowerStore.LoadResult
    private(set) var saveCount = 0

    init(_ catalog: AppleHomePowerCatalog?) {
        stored = catalog.map { .catalog($0) } ?? .missing
    }

    var catalog: AppleHomePowerCatalog? {
        lock.withLock { stored.catalog }
    }

    func load() -> AppleHomePowerStore.LoadResult {
        lock.withLock { stored }
    }

    func save(_ catalog: AppleHomePowerCatalog) throws {
        lock.withLock {
            stored = .catalog(catalog)
            saveCount += 1
        }
    }
}

@MainActor
final class CountingPowerReloader: AppleHomePowerControlReloading {
    private(set) var count = 0
    func reloadControls() { count += 1 }
}
