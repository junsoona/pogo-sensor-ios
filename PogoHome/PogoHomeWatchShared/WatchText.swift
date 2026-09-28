import Foundation
import SwiftUI

// The words and symbols the Watch app and its widgets use for the verdicts of
// `WatchGlancePresentation`. Kept in one place so a complication and the app never describe the
// same state differently. Colors never carry meaning alone: every tone sits next to a symbol and
// text.

nonisolated enum WatchTone: Sendable {
    case fine
    case attention
    case neutral

    var color: Color {
        switch self {
        case .fine: return .green
        case .attention: return .orange
        case .neutral: return .secondary
        }
    }
}

nonisolated enum WatchText {
    // MARK: POGO headline

    static func title(_ headline: WatchPogoHeadline) -> String {
        switch headline {
        case .noData:
            return String(localized: "데이터 없음", comment: "Widget: no POGO data was ever confirmed")
        case .waitingForData:
            return String(localized: "데이터 기다리는 중", comment: "Watch: the bridge answered but has no complete readings yet")
        case .healthy:
            return String(localized: "정상", comment: "Sensor status")
        case let .attentionNeeded(count, _, _, _):
            return String(localized: "확인 필요 \(count)", comment: "Watch: POGO modules needing attention, with their number")
        case .notConfirmed:
            return String(localized: "연결 확인 안 됨", comment: "Widget: the POGO bridge connection was not confirmed when last written")
        case .stale:
            return String(localized: "오래된 정보", comment: "Widget: the stored state is older than the widget's freshness limit")
        }
    }

    /// In place of the selected values while there are none to show.
    static func setupHint(_ hint: WatchSetupHint) -> String {
        switch hint {
        case .connectingToPhone:
            return String(localized: "iPhone과 연결하는 중…", comment: "Watch: no settings yet; the link to the iPhone is still being set up")
        case .phoneAppNotInstalled:
            return String(localized: "iPhone에 조각보 홈이 설치되어 있지 않습니다", comment: "Watch: no settings yet; PogoHome isn't installed on the paired iPhone")
        case .phoneUnreachable:
            return String(localized: "iPhone에 연결할 수 없습니다. iPhone을 가까이 두고 조각보 홈을 열어 주세요.", comment: "Watch: no settings yet; the iPhone is out of reach")
        case .receivingSettings:
            return String(localized: "iPhone에서 설정을 받는 중…", comment: "Watch: no settings yet; asking the iPhone now")
        case .openPhoneApp:
            return String(localized: "iPhone에서 조각보 홈을 한 번 열어 주세요", comment: "Watch: the iPhone app must be opened once to send the settings")
        case .pickValues:
            return String(localized: "iPhone의 조각보 홈 설정 › Apple Watch에서 표시할 값을 고르세요.", comment: "Watch: no values picked yet; where to pick them")
        }
    }

    /// The second line: counts for a current state, otherwise when it was last confirmed.
    static func detail(_ headline: WatchPogoHeadline, now: Date) -> String {
        switch headline {
        case .noData:
            return String(localized: "iPhone에서 조각보 홈을 열어 주세요", comment: "Watch: nothing received yet; open the iPhone app once")
        case .waitingForData:
            return String(localized: "허브가 센서 값을 보내면 표시됩니다", comment: "Watch: waiting for the bridge's first complete readings")
        case let .healthy(online, total, _), let .attentionNeeded(_, online, total, _):
            return String(localized: "온라인 \(online)/\(total)", comment: "Room card: online modules / total modules")
        case let .notConfirmed(at), let .stale(at):
            return GlanceTime.confirmation(at, now: now, isCurrent: false)
        }
    }

    static func symbol(_ headline: WatchPogoHeadline) -> String {
        switch headline {
        case .noData, .waitingForData: return "hourglass"
        case .healthy: return "checkmark.circle.fill"
        case .attentionNeeded: return "exclamationmark.triangle.fill"
        case .notConfirmed: return "wifi.exclamationmark"
        case .stale: return "clock.badge.exclamationmark"
        }
    }

    static func tone(_ headline: WatchPogoHeadline) -> WatchTone {
        switch headline {
        case .healthy: return .fine
        case .attentionNeeded, .notConfirmed, .stale: return .attention
        case .noData, .waitingForData: return .neutral
        }
    }

    // MARK: Connection

    static func connectionTitle(_ status: WatchConnectionStatus) -> String {
        switch status {
        case .notConfigured:
            return String(localized: "허브 주소 없음", comment: "Watch: the iPhone hasn't sent the bridge address yet")
        case .simulated:
            return String(localized: "iPhone 모의 데이터", comment: "Watch: the iPhone app shows simulated data")
        case .checking:
            return String(localized: "확인 중…", comment: "Control Center value: reading the state")
        case .notChecked:
            return String(localized: "아직 확인하지 않음", comment: "Watch: no attempt to reach the bridge yet")
        case .confirmed(.direct, _):
            return String(localized: "집 네트워크에서 직접 확인", comment: "Watch: the Watch read the POGO bridge itself")
        case .confirmed(.phone, _):
            return String(localized: "iPhone을 통해 확인", comment: "Watch: the iPhone confirmed the POGO state for the Watch")
        case .unreachable:
            return String(localized: "허브에 연결할 수 없음", comment: "Watch: neither the Watch nor the iPhone reached the POGO bridge")
        }
    }

    /// Why, or when — `nil` when the title says it all.
    static func connectionDetail(_ status: WatchConnectionStatus, now: Date) -> String? {
        switch status {
        case .notConfigured:
            return String(localized: "iPhone에서 조각보 홈을 한 번 열어 주세요", comment: "Watch: the iPhone app must be opened once to send the settings")
        case .simulated, .checking, .notChecked:
            return nil
        case let .confirmed(_, at):
            return GlanceTime.string(at, now: now)
        case let .unreachable(direct, phone, _):
            if phone == .failed(.phoneCannotReachHub) {
                return String(localized: "iPhone도 허브에 연결하지 못했습니다. 집 밖에서는 새 값을 받을 수 없습니다.", comment: "Watch: the iPhone couldn't reach the bridge either")
            }
            if direct == .failed(.badResponse) {
                return String(localized: "허브의 응답을 읽을 수 없습니다.", comment: "Watch: the bridge answered with something unusable")
            }
            if direct == .failed(.notConfigured) {
                return String(localized: "iPhone에서 조각보 홈을 한 번 열어 주세요", comment: "Watch: the iPhone app must be opened once to send the settings")
            }
            return String(localized: "집 Wi‑Fi 밖이거나 iPhone이 멀리 있습니다. 집 밖에서는 새 값을 받을 수 없습니다.", comment: "Watch: neither the bridge nor the iPhone could be reached")
        }
    }

    static func connectionSymbol(_ status: WatchConnectionStatus) -> String {
        switch status {
        case .notConfigured: return "gearshape"
        case .simulated: return "theatermasks"
        case .checking, .notChecked: return "arrow.triangle.2.circlepath"
        case .confirmed(.direct, _): return "wifi"
        case .confirmed(.phone, _): return "iphone"
        case .unreachable: return "wifi.slash"
        }
    }

    // MARK: Values

    static func condition(_ condition: HomeGlanceSensorCondition, source: DeviceSource) -> String {
        switch condition {
        case .recent:
            return ""
        case .stale:
            return String(localized: "오래된 정보", comment: "Widget: the stored state is older than the widget's freshness limit")
        case .sourceUnverified:
            return String(localized: "연결 확인 안 됨", comment: "Widget: the POGO bridge connection was not confirmed when last written")
        case .deviceDisconnected:
            return source == .pogoLinuxAPI
                ? String(localized: "오프라인", comment: "Attention reason")
                : String(localized: "응답 없음", comment: "Sensor widget: the Apple Home device isn't responding")
        case .notYetRead:
            return String(localized: "아직 읽지 않음", comment: "Sensor widget: Apple Home listed the value but PogoHome hasn't read it yet")
        }
    }

    static func conditionSymbol(_ condition: HomeGlanceSensorCondition, sensor: HomeGlanceSensor) -> String {
        switch condition {
        case .recent: return HomeGlanceValueText.symbolName(of: sensor)
        case .stale: return "clock.badge.exclamationmark"
        case .sourceUnverified: return "wifi.exclamationmark"
        case .deviceDisconnected: return "bolt.horizontal.circle"
        case .notYetRead: return "ellipsis.circle"
        }
    }

    /// "14:02 확인" for a recent value; otherwise why it isn't current and when it was confirmed.
    static func valueFooter(_ sensor: HomeGlanceSensor, condition: HomeGlanceSensorCondition, now: Date) -> String {
        if condition == .recent {
            return GlanceTime.confirmation(sensor.checkedAt, now: now, isCurrent: true)
        }
        let reason = self.condition(condition, source: sensor.source)
        guard condition != .notYetRead, let checkedAt = sensor.checkedAt else { return reason }
        return "\(reason) · \(GlanceTime.string(checkedAt, now: now))"
    }

    static func missing(_ lookup: HomeGlanceSensorLookup) -> String {
        switch lookup {
        case .sourceUnavailable:
            return String(localized: "Apple 홈 값을 표시할 수 없음", comment: "Sensor widget: Apple Home can't be read")
        case .notConfigured:
            return String(localized: "센서를 선택하세요", comment: "Sensor widget: nothing selected")
        case .missing, .found:
            return String(localized: "선택한 센서를 찾을 수 없음", comment: "Sensor widget: the selected sensor no longer exists")
        }
    }
}
