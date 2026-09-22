import Foundation

nonisolated enum SensorStatus: String, CaseIterable, Hashable, Sendable {
    /// Reading within its normal operating range.
    case normal
    /// Sensor is warming up or recalibrating after power-on.
    case conditioning
    /// No fresh reading has arrived within the expected interval.
    case stale
    /// Module or sensor cannot currently report a value.
    case unavailable
    /// Sensor reported a fault.
    case error

    var displayName: String {
        switch self {
        case .normal: return "정상"
        case .conditioning: return "보정 중"
        case .stale: return "업데이트 지연"
        case .unavailable: return "사용 불가"
        case .error: return "오류"
        }
    }

    var symbolName: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .conditioning: return "arrow.triangle.2.circlepath"
        case .stale: return "clock.badge.exclamationmark.fill"
        case .unavailable: return "questionmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    /// Whether this status should be surfaced as something the user needs to check.
    var needsAttention: Bool {
        switch self {
        case .normal, .conditioning: return false
        case .stale, .unavailable, .error: return true
        }
    }
}

nonisolated struct SensorReading: Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: SensorKind
    let value: Double
    let timestamp: Date
    let status: SensorStatus

    init(id: UUID = UUID(), kind: SensorKind, value: Double, timestamp: Date, status: SensorStatus) {
        self.id = id
        self.kind = kind
        self.value = value
        self.timestamp = timestamp
        self.status = status
    }

    var formattedValue: String {
        kind.formattedValue(value)
    }
}
