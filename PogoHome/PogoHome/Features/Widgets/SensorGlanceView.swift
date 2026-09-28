#if os(iOS)
import SwiftUI
import WidgetKit

/// The "센서값" widget: one value the user picked, from its own source, with when it was last
/// confirmed. A value that isn't a recent confirmation is labeled as such (old, offline,
/// connection not confirmed) and never styled like a current reading; in the Lock Screen circle
/// it is replaced by the time it was last confirmed.
struct SensorGlanceView: View {
    let content: HomeGlanceStore.LoadResult
    /// The configured value's `HomeGlanceValueID.stringValue`, or `nil` if none is selected.
    let selection: String?
    let now: Date
    let layout: GlanceWidgetLayout

    var body: some View {
        if let snapshot = content.snapshot {
            let id = selection.flatMap(HomeGlanceValueID.init(stringValue:))
            // A selection that can't be parsed is as good as a deleted one.
            let lookup = selection != nil && id == nil ? .missing : snapshot.sensorLookup(id, at: now)
            SensorGlanceBody(lookup: lookup, now: now, layout: layout)
                .widgetURL(link(for: lookup).url)
        } else {
            GlanceMessageView(
                layout: layout,
                symbol: "sensor",
                title: Text("조각보 홈 앱을 열어 주세요", comment: "Widget: no stored data yet"),
                detail: Text("앱이 마지막으로 확인한 값이 여기에 표시됩니다.", comment: "Widget: no stored sensor data yet, detail")
            )
            .widgetURL(HomeGlanceLink.dashboard.url)
        }
    }

    private func link(for lookup: HomeGlanceSensorLookup) -> HomeGlanceLink {
        switch lookup {
        case let .found(sensor, _): return .device(sensor.id.device)
        case .missing, .notConfigured: return .devices
        case .sourceUnavailable: return .dashboard
        }
    }
}

private struct SensorGlanceBody: View {
    let lookup: HomeGlanceSensorLookup
    let now: Date
    let layout: GlanceWidgetLayout

    var body: some View {
        switch lookup {
        case .notConfigured:
            GlanceMessageView(
                layout: layout,
                symbol: "slider.horizontal.3",
                title: Text("센서를 선택하세요", comment: "Sensor widget: nothing selected"),
                detail: Text("위젯을 길게 눌러 편집하세요.", comment: "Sensor widget: how to pick a sensor")
            )
        case .missing:
            GlanceMessageView(
                layout: layout,
                symbol: "questionmark.circle",
                title: Text("선택한 센서를 찾을 수 없음", comment: "Sensor widget: the selected sensor no longer exists"),
                detail: Text("삭제되었거나 연결이 해제되었을 수 있습니다. 위젯을 길게 눌러 다시 선택하세요.", comment: "Sensor widget: the selected sensor no longer exists, detail")
            )
        case let .sourceUnavailable(access):
            GlanceMessageView(
                layout: layout,
                symbol: "homekit",
                title: Text("Apple 홈 값을 표시할 수 없음", comment: "Sensor widget: Apple Home can't be read"),
                detail: unavailableDetail(access)
            )
        case let .found(sensor, condition):
            SensorValueView(sensor: sensor, condition: condition, now: now, layout: layout)
        }
    }

    private func unavailableDetail(_ access: HomeGlanceAppleHomeAccess) -> Text {
        switch access {
        case .off:
            return Text("조각보 홈에서 Apple 홈 연결이 꺼져 있습니다.", comment: "Sensor widget: Apple Home is turned off in PogoHome")
        case .denied, .restricted:
            return Text("Apple 홈 접근 권한이 없습니다.", comment: "Apple Home error")
        case .noHome:
            return Text("Apple 홈에 집이 없습니다.", comment: "Sensor widget: Apple Home has no home")
        case .unsupported, .ready:
            return Text("이 기기에서는 Apple 홈을 사용할 수 없습니다.", comment: "Sensor widget: Apple Home unsupported")
        }
    }
}

private struct SensorValueView: View {
    let sensor: HomeGlanceSensor
    let condition: HomeGlanceSensorCondition
    let now: Date
    let layout: GlanceWidgetLayout

    private var isRecent: Bool { condition == .recent }
    private var isSensitive: Bool { HomeGlanceValueText.isSecuritySensitive(sensor) }
    private var kindLabel: String { HomeGlanceValueText.kindLabel(of: sensor) }
    private var symbol: String { HomeGlanceValueText.symbolName(of: sensor) }

    var body: some View {
        switch layout {
        case .small, .medium: small
        case .circular: circular
        case .rectangular: rectangular
        case .inline: inline
        }
    }

    // MARK: Home Screen

    /// Larger text sizes fall back to fewer lines; every variant keeps the kind, the source, the
    /// value and — unless it is a recent confirmation — why it isn't current and when it was
    /// last confirmed.
    private var small: some View {
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 3) {
                header
                GlanceSourceLabel(source: sensor.source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                value
                place
                Spacer(minLength: 0)
                conditionLine
            }
            VStack(alignment: .leading, spacing: 2) {
                header
                value
                place
                conditionLine
            }
            VStack(alignment: .leading, spacing: 2) {
                header
                value
                conditionLine
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Kind on the left, source symbol on the right — the source stays visible in every variant.
    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(isRecent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .widgetAccentable()
            Text(kindLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            Image(systemName: sensor.source == .pogoLinuxAPI ? "sensor.fill" : "homekit")
                .foregroundStyle(.secondary)
                .accessibilityLabel(sensor.source == .pogoLinuxAPI ? Text(verbatim: Brand.name) : Text("Apple 홈", comment: "Dashboard status source: Apple Home"))
        }
        .font(.caption.weight(.semibold))
    }

    private var value: some View {
        Text(valueString)
            .font(.title.weight(.semibold))
            .foregroundStyle(isRecent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .privacySensitive(isSensitive)
    }

    private var place: some View {
        Text(placeText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .privacySensitive()
    }

    /// "14:02 확인", or — for anything but a recent confirmation — why, and when it was last
    /// confirmed.
    @ViewBuilder
    private var conditionLine: some View {
        Group {
            if isRecent {
                Text(GlanceTime.confirmation(sensor.checkedAt, now: now, isCurrent: true))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Label { Text(conditionText) } icon: { Image(systemName: conditionSymbol) }
                        .foregroundStyle(.orange)
                    if condition != .notYetRead {
                        Text(GlanceTime.confirmation(sensor.checkedAt, now: now, isCurrent: false))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.caption2)
        .lineLimit(3)
        .minimumScaleFactor(0.5)
    }

    // MARK: Lock Screen

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: isRecent ? symbol : conditionSymbol)
                    .font(.caption.weight(.semibold))
                    .widgetAccentable()
                if isRecent {
                    Text(HomeGlanceValueText.compactValueText(of: sensor) ?? "—")
                        .font(.system(size: 15, weight: .semibold))
                        .minimumScaleFactor(0.5)
                        .privacySensitive(isSensitive)
                } else if let checkedAt = sensor.checkedAt, condition != .notYetRead {
                    // Not a current value: when it was last confirmed instead.
                    Text(GlanceTime.compactString(checkedAt, now: now))
                        .font(.system(size: 11, weight: .medium))
                        .minimumScaleFactor(0.5)
                } else {
                    Text(verbatim: "—")
                        .font(.caption)
                }
            }
            .lineLimit(1)
            .padding(4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .widgetAccentable()
                Text(kindLabel)
                if let room = sensor.roomName {
                    Text(verbatim: "·")
                    Text(room)
                        .privacySensitive()
                }
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            Text(valueString)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .privacySensitive(isSensitive)
            Group {
                if isRecent {
                    Text(GlanceTime.confirmation(sensor.checkedAt, now: now, isCurrent: true))
                } else if let checkedAt = sensor.checkedAt, condition != .notYetRead {
                    Label { Text(verbatim: "\(conditionText) · \(GlanceTime.string(checkedAt, now: now))") } icon: { Image(systemName: conditionSymbol) }
                } else {
                    Label { Text(conditionText) } icon: { Image(systemName: conditionSymbol) }
                }
            }
            .font(.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        Label {
            if isRecent {
                Text(verbatim: "\(kindLabel) \(valueString)")
            } else if let checkedAt = sensor.checkedAt, condition != .notYetRead {
                Text(verbatim: "\(kindLabel) \(conditionText) · \(GlanceTime.compactString(checkedAt, now: now))")
            } else {
                Text(verbatim: "\(kindLabel) \(conditionText)")
            }
        } icon: {
            Image(systemName: isRecent ? symbol : conditionSymbol)
        }
        .privacySensitive(isSensitive)
    }

    // MARK: Text

    private var valueString: String {
        HomeGlanceValueText.valueText(of: sensor) ?? "—"
    }

    private var placeText: String {
        guard let room = sensor.roomName, !room.isEmpty else { return sensor.deviceName }
        // Both are names (user data), joined the same way in every language.
        return "\(room) · \(sensor.deviceName)"
    }

    private var conditionText: String {
        switch condition {
        case .recent:
            return ""
        case .stale:
            return String(localized: "오래된 정보", comment: "Widget: the stored state is older than the widget's freshness limit")
        case .sourceUnverified:
            return String(localized: "연결 확인 안 됨", comment: "Widget: the POGO bridge connection was not confirmed when last written")
        case .deviceDisconnected:
            return sensor.source == .pogoLinuxAPI
                ? String(localized: "오프라인", comment: "Attention reason")
                : String(localized: "응답 없음", comment: "Sensor widget: the Apple Home device isn't responding")
        case .notYetRead:
            return String(localized: "아직 읽지 않음", comment: "Sensor widget: Apple Home listed the value but PogoHome hasn't read it yet")
        }
    }

    private var conditionSymbol: String {
        switch condition {
        case .recent: return symbol
        case .stale: return "clock.badge.exclamationmark"
        case .sourceUnverified: return "wifi.exclamationmark"
        case .deviceDisconnected: return "bolt.horizontal.circle"
        case .notYetRead: return "ellipsis.circle"
        }
    }

    private var accessibilitySummary: Text {
        Text(verbatim: "\(kindLabel), \(isRecent ? valueString : conditionText)")
    }
}
#endif
