import Foundation

// A HomeKit-free copy of what Apple Home reports, built by `HomeKitAppleHomeProvider` (or a
// test/preview fake). Views and `AppleHomeModel` only ever see these values, never `HM*`
// objects, so every rule about what may be shown or controlled is testable without HomeKit.

/// Whether PogoHome can see Apple Home right now, and if not, why.
nonisolated enum AppleHomeAccessState: Hashable, Sendable {
    /// The user hasn't turned on Apple Home in PogoHome; HomeKit has not been touched (no
    /// permission prompt has been shown).
    case off
    /// This platform/build has no HomeKit.
    case unsupported
    /// Waiting for the permission decision or HomeKit's first home list.
    case loading
    /// The user declined (or later revoked) Apple Home access for PogoHome.
    case denied
    /// Access is blocked by the system (e.g. Screen Time / device management).
    case restricted
    /// Access granted, but the user has no home in Apple Home.
    case noHome
    case ready
}

nonisolated enum AppleHomeHubState: Hashable, Sendable {
    case connected
    case disconnected
    case notAvailable
    case unknown
}

nonisolated struct AppleHomeInfo: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let isPrimary: Bool
    let hubState: AppleHomeHubState
}

/// The HomeKit service types PogoHome recognizes. Anything else is `.other` and contributes
/// nothing but its name to the "not shown" list.
nonisolated enum AppleHomeServiceKind: String, Hashable, Sendable {
    case lightbulb, `switch`, outlet, fan, airPurifier
    case temperatureSensor, humiditySensor, airQualitySensor, lightSensor
    case contactSensor, motionSensor, occupancySensor, leakSensor, smokeSensor
    case carbonDioxideSensor, carbonMonoxideSensor
    case battery, lockMechanism, windowCovering
    /// Accessory Information — metadata only, never listed as a feature.
    case accessoryInformation
    case other
}

/// The HomeKit characteristic types PogoHome can present. Anything else is not mapped at all
/// (counted in `AppleHomeService.unsupportedCharacteristicCount`).
nonisolated enum AppleHomeCharacteristicKind: String, Hashable, Sendable {
    case powerState, active, brightness
    case currentTemperature, currentRelativeHumidity, currentLightLevel
    case airQuality, pm2_5Density, pm10Density, carbonDioxideLevel
    case contactState, motionDetected, occupancyDetected, leakDetected, smokeDetected, carbonMonoxideDetected
    case batteryLevel, statusLowBattery
    case currentLockMechanismState, currentPosition, outletInUse
}

/// A characteristic value as HomeKit delivered it. Strings/data are never needed for the
/// characteristics above and are not carried.
nonisolated enum AppleHomeRawValue: Hashable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)

    var doubleValue: Double {
        switch self {
        case let .bool(value): return value ? 1 : 0
        case let .int(value): return Double(value)
        case let .double(value): return value
        }
    }

    var boolValue: Bool { doubleValue != 0 }
}

nonisolated struct AppleHomeCharacteristic: Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: AppleHomeCharacteristicKind
    let isReadable: Bool
    let isWritable: Bool
    let supportsNotification: Bool
    /// The value PogoHome itself has read or been notified of in this session; `nil` until
    /// then, even if HomeKit holds an older cached value.
    let value: AppleHomeRawValue?
    let confirmedAt: Date?
    let minimumValue: Double?
    let maximumValue: Double?

    init(
        id: UUID,
        kind: AppleHomeCharacteristicKind,
        isReadable: Bool = true,
        isWritable: Bool = false,
        supportsNotification: Bool = false,
        value: AppleHomeRawValue? = nil,
        confirmedAt: Date? = nil,
        minimumValue: Double? = nil,
        maximumValue: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.isReadable = isReadable
        self.isWritable = isWritable
        self.supportsNotification = supportsNotification
        self.value = value
        self.confirmedAt = confirmedAt
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
    }
}

nonisolated struct AppleHomeService: Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: AppleHomeServiceKind
    /// HomeKit's own service name (user-editable in the Home app).
    let name: String
    /// HomeKit's localized description of the service type, used when `kind == .other`.
    let typeDescription: String
    let isPrimary: Bool
    /// HomeKit's `isUserInteractive`: `false` for plumbing the Home app doesn't show as a
    /// feature (identify, protocol or firmware information and the like).
    let isUserInteractive: Bool
    let characteristics: [AppleHomeCharacteristic]
    /// Characteristics HomeKit exposes that PogoHome doesn't interpret (not shown).
    let unsupportedCharacteristicCount: Int

    init(
        id: UUID,
        kind: AppleHomeServiceKind,
        name: String,
        typeDescription: String = "",
        isPrimary: Bool = false,
        isUserInteractive: Bool = true,
        characteristics: [AppleHomeCharacteristic],
        unsupportedCharacteristicCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.typeDescription = typeDescription
        self.isPrimary = isPrimary
        self.isUserInteractive = isUserInteractive
        self.characteristics = characteristics
        self.unsupportedCharacteristicCount = unsupportedCharacteristicCount
    }
}

nonisolated struct AppleHomeAccessory: Identifiable, Hashable, Sendable {
    /// `HMAccessory.uniqueIdentifier`.
    let id: UUID
    let homeID: UUID
    let name: String
    let roomID: UUID?
    let roomName: String?
    let isReachable: Bool
    /// HomeKit has blocked the accessory (e.g. it failed authentication); it can't be used.
    let isBlocked: Bool
    /// Sits behind a bridge accessory (as each POGO module does behind the Linux Matter bridge).
    let isBridged: Bool
    /// HomeKit reports a Matter node id for it.
    let isMatter: Bool
    let categoryDescription: String
    let manufacturer: String?
    let model: String?
    let firmwareVersion: String?
    let services: [AppleHomeService]
    /// The most recent failed read (message), cleared by the next successful one.
    let lastReadError: String?
    /// Where PogoHome's automatic read of this accessory stands; `nil` when none is queued,
    /// running or waiting to retry.
    let autoRead: AppleHomeAutoReadState?

    init(
        id: UUID,
        homeID: UUID,
        name: String,
        roomID: UUID? = nil,
        roomName: String? = nil,
        isReachable: Bool,
        isBlocked: Bool = false,
        isBridged: Bool = false,
        isMatter: Bool = false,
        categoryDescription: String = "",
        manufacturer: String? = nil,
        model: String? = nil,
        firmwareVersion: String? = nil,
        services: [AppleHomeService],
        lastReadError: String? = nil,
        autoRead: AppleHomeAutoReadState? = nil
    ) {
        self.id = id
        self.homeID = homeID
        self.name = name
        self.roomID = roomID
        self.roomName = roomName
        self.isReachable = isReachable
        self.isBlocked = isBlocked
        self.isBridged = isBridged
        self.isMatter = isMatter
        self.categoryDescription = categoryDescription
        self.manufacturer = manufacturer
        self.model = model
        self.firmwareVersion = firmwareVersion
        self.services = services
        self.lastReadError = lastReadError
        self.autoRead = autoRead
    }

    /// When PogoHome last received any value from this accessory.
    var lastCheckedAt: Date? {
        services.flatMap(\.characteristics).compactMap(\.confirmedAt).max()
    }

    /// Can be operated right now.
    var isOperable: Bool { isReachable && !isBlocked }

    /// Has at least one characteristic PogoHome shows and HomeKit lets it read. Without one,
    /// "no value" is simply what the accessory offers, not a failed or pending read.
    var hasReadableValues: Bool {
        services.contains { $0.characteristics.contains(where: \.isReadable) }
    }

    func characteristic(with id: UUID) -> AppleHomeCharacteristic? {
        for service in services {
            if let match = service.characteristics.first(where: { $0.id == id }) { return match }
        }
        return nil
    }
}

nonisolated struct AppleHomeSnapshot: Hashable, Sendable {
    let accessState: AppleHomeAccessState
    let homes: [AppleHomeInfo]
    let accessories: [AppleHomeAccessory]

    init(accessState: AppleHomeAccessState, homes: [AppleHomeInfo] = [], accessories: [AppleHomeAccessory] = []) {
        self.accessState = accessState
        // Accessories are only ever meaningful with access; never keep stale ones around.
        self.homes = accessState == .ready || accessState == .noHome ? homes : []
        self.accessories = accessState == .ready ? accessories : []
    }

    static let off = AppleHomeSnapshot(accessState: .off)

    func accessory(with id: UUID) -> AppleHomeAccessory? {
        accessories.first { $0.id == id }
    }

    func home(with id: UUID) -> AppleHomeInfo? {
        homes.first { $0.id == id }
    }
}

/// An automatic read: one PogoHome starts without a tap — the first read after HomeKit lists an
/// accessory in this session, or after it responds again. `AppleHomeAutoReader` runs them.
nonisolated enum AppleHomeAutoReadState: Hashable, Sendable {
    /// Waiting for a free read slot. `nextAttempt` is 1 before the first try; above 1 the
    /// previous try failed with a transient error and this is an automatic retry.
    case waiting(nextAttempt: Int, maxAttempts: Int)
    case reading(attempt: Int, maxAttempts: Int)

    /// An earlier attempt of this round failed; another one is pending or running.
    var isRetry: Bool {
        switch self {
        case let .waiting(attempt, _), let .reading(attempt, _): return attempt > 1
        }
    }

    var attempt: Int {
        switch self {
        case let .waiting(attempt, _), let .reading(attempt, _): return attempt
        }
    }

    var maxAttempts: Int {
        switch self {
        case let .waiting(_, maxAttempts), let .reading(_, maxAttempts): return maxAttempts
        }
    }
}

/// What `HMAccessorySetupManager` reported after the system setup flow finished.
nonisolated struct AppleHomeSetupResult: Hashable, Sendable {
    let homeID: UUID
    let accessoryIDs: [UUID]
}

nonisolated enum AppleHomeProviderError: Error, Hashable, Sendable {
    case notAuthorized
    /// HomeKit rejected an individual read while HMHomeManager still reports access granted.
    /// This can happen while the home is becoming ready and may succeed on retry.
    case accessNotReady
    case accessoryNotFound
    case characteristicNotFound
    case notReachable
    case timedOut
    case cancelled
    case setupUnavailable
    case underlying(String)
}
