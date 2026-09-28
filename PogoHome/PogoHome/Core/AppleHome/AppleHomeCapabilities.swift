import Foundation

/// What PogoHome may show and operate for an Apple Home accessory — decided only from what
/// HomeKit actually exposes on it, never from the accessory's category or name.
///
/// - A value is listed only for a characteristic HomeKit marks readable, and its text is shown
///   only after PogoHome has read it (or been notified of it) in this session.
/// - A control is offered only for a characteristic HomeKit marks both writable and readable
///   (so the result can be read back) and only on a service type where its meaning is clear:
///   power on lights/switches/outlets/fans, active on fans/air purifiers, brightness on
///   lights. Locks, doors, thermostats, window coverings and everything else stay read-only.
nonisolated enum AppleHomeCapabilities {
    static func controlKind(
        for characteristic: AppleHomeCharacteristic,
        in service: AppleHomeService
    ) -> DeviceControlKind? {
        guard characteristic.isWritable, characteristic.isReadable else { return nil }
        switch (characteristic.kind, service.kind) {
        case (.powerState, .lightbulb), (.powerState, .switch), (.powerState, .outlet), (.powerState, .fan):
            return .power
        case (.active, .fan), (.active, .airPurifier):
            return .active
        case (.brightness, .lightbulb):
            return .brightness
        default:
            return nil
        }
    }

    static func controls(of accessory: AppleHomeAccessory) -> [DeviceAvailableControl] {
        let listedServices = accessory.services.filter { $0.kind != .accessoryInformation }
        return listedServices.flatMap { service in
            service.characteristics.compactMap { characteristic -> DeviceAvailableControl? in
                guard let kind = controlKind(for: characteristic, in: service) else { return nil }
                return DeviceAvailableControl(
                    id: characteristic.id,
                    kind: kind,
                    label: service.name.isEmpty ? accessory.name : service.name,
                    confirmedValue: characteristic.value.map { controlValue(from: $0, kind: kind) },
                    range: kind == .brightness ? percentRange(of: characteristic) : nil,
                    isEnabled: accessory.isOperable
                )
            }
        }
    }

    /// Readable values that are not already presented as a control.
    static func values(of accessory: AppleHomeAccessory) -> [DeviceReadableValue] {
        accessory.services
            .filter { $0.kind != .accessoryInformation }
            .flatMap { service in
                service.characteristics.compactMap { characteristic -> DeviceReadableValue? in
                    guard characteristic.isReadable, controlKind(for: characteristic, in: service) == nil else { return nil }
                    return presentation(of: characteristic)
                }
            }
    }

    /// How much of the accessory the detail screen can show or operate — decided from
    /// `values(of:)` and `controls(of:)`, so the verdict never disagrees with what is listed.
    static func featureSupport(of accessory: AppleHomeAccessory) -> AppleHomeFeatureSupport {
        guard !values(of: accessory).isEmpty || !controls(of: accessory).isEmpty else { return .appleHomeOnly }
        return .supported(otherFeatureNames: otherFeatureNames(of: accessory))
    }

    /// Features the Home app offers on the accessory that PogoHome recognizes nothing on, by the
    /// name the user sees in the Home app. Services HomeKit marks as not user-interactive
    /// (identify, protocol or firmware information) and unnamed ones are left out: the user
    /// would only see a technical type name for them.
    static func otherFeatureNames(of accessory: AppleHomeAccessory) -> [String] {
        var seen: Set<String> = []
        return accessory.services
            .filter { $0.kind != .accessoryInformation && $0.isUserInteractive && $0.characteristics.isEmpty }
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func controlValue(from raw: AppleHomeRawValue, kind: DeviceControlKind) -> DeviceControlValue {
        switch kind {
        case .power, .active: return .bool(raw.boolValue)
        case .brightness: return .percent(Int(raw.doubleValue.rounded()))
        }
    }

    /// The value HomeKit expects for a control: `PowerState` is a bool, `Active` a uint8 (0/1),
    /// `Brightness` an int percentage.
    static func rawValue(for value: DeviceControlValue, kind: DeviceControlKind) -> AppleHomeRawValue? {
        switch (kind, value) {
        case let (.power, .bool(on)): return .bool(on)
        case let (.active, .bool(on)): return .int(on ? 1 : 0)
        case let (.brightness, .percent(percent)): return .int(percent)
        default: return nil
        }
    }

    static func percentRange(of characteristic: AppleHomeCharacteristic) -> ClosedRange<Int> {
        let lower = Int((characteristic.minimumValue ?? 0).rounded(.up))
        let upper = Int((characteristic.maximumValue ?? 100).rounded(.down))
        return lower <= upper ? lower...upper : 0...100
    }

    // MARK: - Presentation

    static func presentation(of characteristic: AppleHomeCharacteristic, locale: Locale = .current) -> DeviceReadableValue {
        let text = characteristic.value.map { displayText(for: characteristic.kind, value: $0, locale: locale) }
        return DeviceReadableValue(
            id: characteristic.id.uuidString,
            label: label(for: characteristic.kind),
            displayValue: text,
            symbolName: symbolName(for: characteristic.kind),
            needsAttention: characteristic.value.map { needsAttention(characteristic.kind, $0) } ?? false
        )
    }

    static func label(for kind: AppleHomeCharacteristicKind) -> String {
        switch kind {
        case .powerState: return String(localized: "전원", comment: "Apple Home value: on/off")
        case .active: return String(localized: "작동", comment: "Apple Home value: active/inactive")
        case .brightness: return String(localized: "밝기", comment: "Apple Home value")
        case .currentTemperature: return SensorKind.temperature.displayName
        case .currentRelativeHumidity: return SensorKind.humidity.displayName
        case .currentLightLevel: return SensorKind.illuminance.displayName
        case .pm2_5Density: return SensorKind.pm2_5.displayName
        case .pm10Density: return SensorKind.pm10.displayName
        case .airQuality: return String(localized: "공기질", comment: "Apple Home value: air quality level")
        case .carbonDioxideLevel: return String(localized: "이산화탄소", comment: "Apple Home value: CO2 level")
        case .contactState: return String(localized: "열림 감지", comment: "Apple Home value: contact sensor")
        case .motionDetected: return String(localized: "움직임", comment: "Apple Home value: motion sensor")
        case .occupancyDetected: return String(localized: "사람 감지", comment: "Apple Home value: occupancy sensor")
        case .leakDetected: return String(localized: "누수", comment: "Apple Home value: leak sensor")
        case .smokeDetected: return String(localized: "연기", comment: "Apple Home value: smoke sensor")
        case .carbonMonoxideDetected: return String(localized: "일산화탄소", comment: "Apple Home value: CO sensor")
        case .batteryLevel: return String(localized: "배터리", comment: "Apple Home value: battery level")
        case .statusLowBattery: return String(localized: "배터리 상태", comment: "Apple Home value: low battery flag")
        case .currentLockMechanismState: return String(localized: "잠금 상태", comment: "Apple Home value: lock state")
        case .currentPosition: return String(localized: "현재 위치", comment: "Apple Home value: window covering position")
        case .outletInUse: return String(localized: "콘센트 사용", comment: "Apple Home value: outlet in use")
        }
    }

    static func symbolName(for kind: AppleHomeCharacteristicKind) -> String {
        switch kind {
        case .powerState, .active: return "power"
        case .brightness: return "sun.max.fill"
        case .currentTemperature: return SensorKind.temperature.symbolName
        case .currentRelativeHumidity: return SensorKind.humidity.symbolName
        case .currentLightLevel: return SensorKind.illuminance.symbolName
        case .pm2_5Density, .pm10Density, .airQuality: return "aqi.medium"
        case .carbonDioxideLevel: return "carbon.dioxide.cloud.fill"
        case .contactState: return "door.left.hand.open"
        case .motionDetected: return "figure.walk.motion"
        case .occupancyDetected: return "person.fill"
        case .leakDetected: return "drop.triangle.fill"
        case .smokeDetected: return "smoke.fill"
        case .carbonMonoxideDetected: return "carbon.monoxide.cloud.fill"
        case .batteryLevel, .statusLowBattery: return "battery.75percent"
        case .currentLockMechanismState: return "lock.fill"
        case .currentPosition: return "blinds.horizontal.open"
        case .outletInUse: return "poweroutlet.type.b.fill"
        }
    }

    static func displayText(for kind: AppleHomeCharacteristicKind, value: AppleHomeRawValue, locale: Locale = .current) -> String {
        let number = value.doubleValue
        switch kind {
        case .powerState:
            return value.boolValue ? String(localized: "켜짐", comment: "Apple Home: on") : String(localized: "꺼짐", comment: "Apple Home: off")
        case .active:
            return value.boolValue ? String(localized: "작동 중", comment: "Apple Home: active") : String(localized: "꺼짐", comment: "Apple Home: off")
        case .brightness, .batteryLevel, .currentPosition:
            return percentText(number, locale: locale)
        case .currentTemperature: return SensorKind.temperature.formattedValue(number, locale: locale)
        case .currentRelativeHumidity: return SensorKind.humidity.formattedValue(number, locale: locale)
        case .currentLightLevel: return SensorKind.illuminance.formattedValue(number, locale: locale)
        case .pm2_5Density: return SensorKind.pm2_5.formattedValue(number, locale: locale)
        case .pm10Density: return SensorKind.pm10.formattedValue(number, locale: locale)
        case .carbonDioxideLevel:
            let digits = number.formatted(.number.precision(.fractionLength(0)).locale(locale))
            return String(localized: "\(digits) ppm", comment: "CO2 level in parts per million")
        case .airQuality:
            switch Int(number) {
            case 1: return String(localized: "매우 좋음", comment: "Air quality level 1 of 5")
            case 2: return String(localized: "좋음", comment: "Air quality level 2 of 5")
            case 3: return String(localized: "보통", comment: "Air quality level 3 of 5")
            case 4: return String(localized: "나쁨", comment: "Air quality level 4 of 5")
            case 5: return String(localized: "매우 나쁨", comment: "Air quality level 5 of 5")
            default: return String(localized: "알 수 없음", comment: "Apple Home: the device reports an unknown value")
            }
        case .contactState:
            // HomeKit: 0 = contact detected (closed), 1 = no contact (open).
            return number == 0 ? String(localized: "닫힘", comment: "Contact sensor: closed") : String(localized: "열림", comment: "Contact sensor: open")
        case .motionDetected, .occupancyDetected, .leakDetected, .smokeDetected:
            return value.boolValue ? String(localized: "감지됨", comment: "Apple Home sensor: detected") : String(localized: "감지 안 됨", comment: "Apple Home sensor: not detected")
        case .carbonMonoxideDetected:
            return value.boolValue ? String(localized: "비정상 수준", comment: "CO sensor: abnormal level") : String(localized: "정상", comment: "Sensor status")
        case .statusLowBattery:
            return value.boolValue ? String(localized: "부족", comment: "Battery: low") : String(localized: "정상", comment: "Sensor status")
        case .currentLockMechanismState:
            switch Int(number) {
            case 0: return String(localized: "열림", comment: "Lock: unsecured")
            case 1: return String(localized: "잠김", comment: "Lock: secured")
            case 2: return String(localized: "걸림", comment: "Lock: jammed")
            default: return String(localized: "알 수 없음", comment: "Apple Home: the device reports an unknown value")
            }
        case .outletInUse:
            return value.boolValue ? String(localized: "사용 중", comment: "Outlet in use: yes") : String(localized: "사용 안 함", comment: "Outlet in use: no")
        }
    }

    static func needsAttention(_ kind: AppleHomeCharacteristicKind, _ value: AppleHomeRawValue) -> Bool {
        switch kind {
        case .leakDetected, .smokeDetected, .carbonMonoxideDetected, .statusLowBattery:
            return value.boolValue
        case .airQuality:
            return Int(value.doubleValue) >= 4
        case .currentLockMechanismState:
            return Int(value.doubleValue) == 2
        default:
            return false
        }
    }

    static func percentText(_ value: Double, locale: Locale = .current) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
}

/// What the accessory's detail screen says about features PogoHome doesn't show.
nonisolated enum AppleHomeFeatureSupport: Hashable, Sendable {
    /// Nothing on it can be shown or operated here: the whole device is used in the Home app.
    case appleHomeOnly
    /// Some values or controls are shown. `otherFeatureNames` are the remaining features, by
    /// their Home app name, that only the Home app offers (often none).
    case supported(otherFeatureNames: [String])
}
