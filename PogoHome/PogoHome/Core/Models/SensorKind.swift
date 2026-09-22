import Foundation

nonisolated enum SensorCategory: String, Hashable, Sendable {
    case climate
    case airQuality
    case light
    case gas
}

nonisolated enum SensorKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case temperature
    case humidity
    case illuminance
    case pm1
    case pm2_5
    case pm10
    case vocRaw
    case vocIndex
    case noxRaw
    case noxIndex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .temperature: return "온도"
        case .humidity: return "습도"
        case .illuminance: return "조도"
        case .pm1: return "미세먼지 PM1"
        case .pm2_5: return "미세먼지 PM2.5"
        case .pm10: return "미세먼지 PM10"
        case .vocRaw: return "VOC Raw"
        case .vocIndex: return "VOC Index"
        case .noxRaw: return "NOx Raw"
        case .noxIndex: return "NOx Index"
        }
    }

    var unit: String {
        switch self {
        case .temperature: return "°C"
        case .humidity: return "%"
        case .illuminance: return "lx"
        case .pm1, .pm2_5, .pm10: return "µg/m³"
        case .vocRaw, .noxRaw: return "Raw"
        case .vocIndex, .noxIndex: return "Index"
        }
    }

    var symbolName: String {
        switch self {
        case .temperature: return "thermometer.medium"
        case .humidity: return "humidity.fill"
        case .illuminance: return "sun.max.fill"
        case .pm1, .pm2_5, .pm10: return "aqi.medium"
        case .vocRaw, .vocIndex: return "wind"
        case .noxRaw, .noxIndex: return "smoke.fill"
        }
    }

    var category: SensorCategory {
        switch self {
        case .temperature, .humidity: return .climate
        case .illuminance: return .light
        case .pm1, .pm2_5, .pm10: return .airQuality
        case .vocRaw, .vocIndex, .noxRaw, .noxIndex: return .gas
        }
    }

    /// Lower values sort first within a module or dashboard listing.
    var sortOrder: Int {
        switch self {
        case .temperature: return 0
        case .humidity: return 1
        case .illuminance: return 2
        case .pm1: return 3
        case .pm2_5: return 4
        case .pm10: return 5
        case .vocRaw: return 6
        case .vocIndex: return 7
        case .noxRaw: return 8
        case .noxIndex: return 9
        }
    }

    func formattedValue(_ value: Double) -> String {
        let numberString: String
        switch self {
        case .temperature, .humidity, .pm1, .pm2_5, .pm10:
            numberString = value.formatted(.number.precision(.fractionLength(1)))
        case .illuminance, .vocRaw, .vocIndex, .noxRaw, .noxIndex:
            numberString = value.formatted(.number.precision(.fractionLength(0)))
        }
        return "\(numberString) \(unit)"
    }
}
