#if os(iOS) || os(watchOS)
import Foundation
import HomeKit

/// How HomeKit's types, values and errors map onto PogoHome's HomeKit-free vocabulary
/// (`AppleHomeSnapshot.swift`). Shared by the iPhone's `HomeKitAppleHomeProvider`, the power
/// control gateway and the Watch, which has HomeKit but not the iPhone-only setup flow.
nonisolated enum HomeKitMapping {
    static func rawValue(of characteristic: HMCharacteristic) -> AppleHomeRawValue? {
        guard let number = characteristic.value as? NSNumber else { return nil }
        switch characteristic.metadata?.format {
        case HMCharacteristicMetadataFormatBool?:
            return .bool(number.boolValue)
        case HMCharacteristicMetadataFormatFloat?:
            return .double(number.doubleValue)
        case HMCharacteristicMetadataFormatInt?, HMCharacteristicMetadataFormatUInt8?, HMCharacteristicMetadataFormatUInt16?,
             HMCharacteristicMetadataFormatUInt32?, HMCharacteristicMetadataFormatUInt64?:
            return .int(number.intValue)
        default:
            return .double(number.doubleValue)
        }
    }

    static let serviceKinds: [String: AppleHomeServiceKind] = {
        var kinds: [String: AppleHomeServiceKind] = [
            HMServiceTypeLightbulb: .lightbulb,
            HMServiceTypeSwitch: .switch,
            HMServiceTypeOutlet: .outlet,
            HMServiceTypeFan: .fan,
            HMServiceTypeAirPurifier: .airPurifier,
            HMServiceTypeTemperatureSensor: .temperatureSensor,
            HMServiceTypeHumiditySensor: .humiditySensor,
            HMServiceTypeAirQualitySensor: .airQualitySensor,
            HMServiceTypeLightSensor: .lightSensor,
            HMServiceTypeContactSensor: .contactSensor,
            HMServiceTypeMotionSensor: .motionSensor,
            HMServiceTypeOccupancySensor: .occupancySensor,
            HMServiceTypeLeakSensor: .leakSensor,
            HMServiceTypeSmokeSensor: .smokeSensor,
            HMServiceTypeCarbonDioxideSensor: .carbonDioxideSensor,
            HMServiceTypeCarbonMonoxideSensor: .carbonMonoxideSensor,
            HMServiceTypeBattery: .battery,
            HMServiceTypeLockMechanism: .lockMechanism,
            HMServiceTypeWindowCovering: .windowCovering,
            HMServiceTypeAccessoryInformation: .accessoryInformation,
        ]
        // HAP "Fan v2" (0xB7) has no public HMServiceType constant; Matter fans use it.
        kinds["000000B7-0000-1000-8000-0026BB765291"] = .fan
        return Dictionary(uniqueKeysWithValues: kinds.map { ($0.key.uppercased(), $0.value) })
    }()

    static let characteristicKinds: [String: AppleHomeCharacteristicKind] = {
        let kinds: [String: AppleHomeCharacteristicKind] = [
            HMCharacteristicTypePowerState: .powerState,
            HMCharacteristicTypeActive: .active,
            HMCharacteristicTypeBrightness: .brightness,
            HMCharacteristicTypeCurrentTemperature: .currentTemperature,
            HMCharacteristicTypeCurrentRelativeHumidity: .currentRelativeHumidity,
            HMCharacteristicTypeCurrentLightLevel: .currentLightLevel,
            HMCharacteristicTypeAirQuality: .airQuality,
            HMCharacteristicTypePM2_5Density: .pm2_5Density,
            HMCharacteristicTypePM10Density: .pm10Density,
            HMCharacteristicTypeCarbonDioxideLevel: .carbonDioxideLevel,
            HMCharacteristicTypeContactState: .contactState,
            HMCharacteristicTypeMotionDetected: .motionDetected,
            HMCharacteristicTypeOccupancyDetected: .occupancyDetected,
            HMCharacteristicTypeLeakDetected: .leakDetected,
            HMCharacteristicTypeSmokeDetected: .smokeDetected,
            HMCharacteristicTypeCarbonMonoxideDetected: .carbonMonoxideDetected,
            HMCharacteristicTypeBatteryLevel: .batteryLevel,
            HMCharacteristicTypeStatusLowBattery: .statusLowBattery,
            HMCharacteristicTypeCurrentLockMechanismState: .currentLockMechanismState,
            HMCharacteristicTypeCurrentPosition: .currentPosition,
            HMCharacteristicTypeOutletInUse: .outletInUse,
        ]
        return Dictionary(uniqueKeysWithValues: kinds.map { ($0.key.uppercased(), $0.value) })
    }()

    static func providerError(_ error: Error) -> AppleHomeProviderError {
        if let error = error as? AppleHomeProviderError { return error }
        let nsError = error as NSError
        if nsError.domain == HMErrorDomain, let code = HMError.Code(rawValue: nsError.code) {
            switch code {
            case .operationCancelled:
                return .cancelled
            case .homeAccessNotAuthorized, .insufficientPrivileges, .missingEntitlement:
                return .notAuthorized
            case .operationTimedOut:
                return .timedOut
            case .accessoryNotReachable, .accessoryPoweredOff, .communicationFailure, .accessoryCommunicationFailure:
                return .notReachable
            default:
                break
            }
        }
        return .underlying(nsError.localizedDescription)
    }
}
#endif
