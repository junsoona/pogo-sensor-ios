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
        case .temperature: return String(localized: "온도", comment: "Sensor kind")
        case .humidity: return String(localized: "습도", comment: "Sensor kind")
        case .illuminance: return String(localized: "조도", comment: "Sensor kind: light level")
        case .pm1: return String(localized: "미세먼지 PM1", comment: "Sensor kind: particulate matter")
        case .pm2_5: return String(localized: "미세먼지 PM2.5", comment: "Sensor kind: particulate matter")
        case .pm10: return String(localized: "미세먼지 PM10", comment: "Sensor kind: particulate matter")
        case .vocRaw: return String(localized: "VOC Raw", comment: "Sensor kind: raw VOC signal")
        case .vocIndex: return String(localized: "VOC Index", comment: "Sensor kind: VOC index")
        case .noxRaw: return String(localized: "NOx Raw", comment: "Sensor kind: raw NOx signal")
        case .noxIndex: return String(localized: "NOx Index", comment: "Sensor kind: NOx index")
        }
    }

    /// SI symbols are the same in every language; only the dimensionless raw/index labels
    /// are translated.
    var unit: String {
        switch self {
        case .temperature: return "°C"
        case .humidity: return "%"
        case .illuminance: return "lx"
        case .pm1, .pm2_5, .pm10: return "µg/m³"
        case .vocRaw, .noxRaw: return String(localized: "Raw", comment: "Unit label for a raw, unitless sensor signal")
        case .vocIndex, .noxIndex: return String(localized: "Index", comment: "Unit label for a unitless sensor index")
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

    /// The number uses `locale`'s separators (`23.4` / `23,4`); the value–unit order comes from
    /// the localized format.
    func formattedValue(_ value: Double, locale: Locale = .current) -> String {
        let numberString: String
        switch self {
        case .temperature, .humidity, .pm1, .pm2_5, .pm10:
            numberString = value.formatted(.number.precision(.fractionLength(1)).locale(locale))
        case .illuminance, .vocRaw, .vocIndex, .noxRaw, .noxIndex:
            numberString = value.formatted(.number.precision(.fractionLength(0)).locale(locale))
        }
        return String(localized: "\(numberString) \(unit)", comment: "Sensor value followed by its unit, e.g. 23.4 °C")
    }
}
