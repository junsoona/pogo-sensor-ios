import SwiftUI
import WidgetKit

// The Watch face complications and Smart Stack widgets. Shared by the widget extension (which
// renders them) and the Watch app (whose tests render every state, language, text size and the
// Always On look). Views only draw verdicts from `WatchGlancePresentation`.
//
// Privacy: home, room and device names and security-sensitive values are `privacySensitive`, so
// the system redacts them while the Watch is locked; in Always On (luminance reduced) the views
// redact them themselves.

nonisolated enum WatchWidgetKind {
    static let homeStatus = "com.junsoona.PogoHome.watch.homeStatus"
    static let sensorValue = "com.junsoona.PogoHome.watch.sensorValue"
    static let all = [homeStatus, sensorValue]
}

/// The complication family a view is laid out for — mirrored from `WidgetFamily` so the views
/// can also be rendered outside a widget (tests).
enum WatchComplicationLayout: CaseIterable, Sendable {
    case circular
    case rectangular
    case inline
    case corner

    init?(_ family: WidgetFamily) {
        switch family {
        case .accessoryCircular: self = .circular
        case .accessoryRectangular: self = .rectangular
        case .accessoryInline: self = .inline
        case .accessoryCorner: self = .corner
        default: return nil
        }
    }
}

/// Redacts `privacySensitive` content in Always On, on top of the system's own locked redaction.
private struct AlwaysOnPrivacy: ViewModifier {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    func body(content: Content) -> some View {
        content.redacted(reason: isLuminanceReduced ? .privacy : [])
    }
}

extension View {
    func watchAlwaysOnPrivacy() -> some View {
        modifier(AlwaysOnPrivacy())
    }
}

// MARK: - Home status

struct WatchHomeStatusComplication: View {
    let state: WatchStoredState
    let now: Date
    let layout: WatchComplicationLayout

    private var headline: WatchPogoHeadline { WatchGlancePresentation.headline(state.glance, now: now) }

    var body: some View {
        Group {
            switch layout {
            case .circular: circular
            case .rectangular: rectangular
            case .inline: inline
            case .corner: corner
            }
        }
        .watchAlwaysOnPrivacy()
    }

    private var shortText: String {
        switch headline {
        case let .healthy(online, total, _), let .attentionNeeded(_, online, total, _):
            return "\(online)/\(total)"
        case let .notConfirmed(at), let .stale(at):
            return at.map { GlanceTime.compactString($0, now: now) } ?? "—"
        case .noData, .waitingForData:
            return "—"
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: WatchText.symbol(headline))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(WatchText.tone(headline).color)
                    .widgetAccentable()
                Text(verbatim: shortText)
                    .font(.system(size: 12, weight: .semibold))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
            .padding(3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(Brand.name) \(WatchText.title(headline)), \(WatchText.detail(headline, now: now))"))
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: WatchText.symbol(headline))
                    .foregroundStyle(WatchText.tone(headline).color)
                    .widgetAccentable()
                Text(verbatim: Brand.name)
                    .foregroundStyle(.secondary)
                Text(WatchText.title(headline))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .font(.headline)
            Text(WatchText.detail(headline, now: now))
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if headline.isCurrent, let at = headline.confirmedAt {
                Text(GlanceTime.confirmation(at, now: now, isCurrent: true))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let name = state.glance?.homeName {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .privacySensitive()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One short line: the verdict for a current state; for anything else the symbol says why and
    /// the text only when it was last confirmed, so the time is never cut off.
    private var inline: some View {
        Label {
            if headline.isCurrent {
                Text(verbatim: "\(Brand.name) \(WatchText.title(headline)) · \(shortText)")
            } else {
                Text(verbatim: "\(Brand.name) \(shortText)")
            }
        } icon: {
            Image(systemName: WatchText.symbol(headline))
        }
        .accessibilityLabel(Text(verbatim: "\(Brand.name) \(WatchText.title(headline)), \(WatchText.detail(headline, now: now))"))
    }

    private var corner: some View {
        Image(systemName: WatchText.symbol(headline))
            .font(.title3.weight(.semibold))
            .widgetAccentable()
            .widgetLabel {
                Text(verbatim: "\(Brand.name) \(WatchText.title(headline))")
            }
            .accessibilityLabel(Text(verbatim: "\(Brand.name) \(WatchText.title(headline))"))
    }
}

// MARK: - Sensor value

struct WatchSensorComplication: View {
    let state: WatchStoredState
    /// `HomeGlanceValueID.stringValue`; `nil` means the first value picked on the iPhone.
    let selection: String?
    let now: Date
    let layout: WatchComplicationLayout

    private var selectedID: String? { selection ?? state.settings?.selectedValueIDs.first }

    private var lookup: HomeGlanceSensorLookup {
        guard let glance = state.glance else { return .missing }
        guard let selectedID else { return .notConfigured }
        guard let id = HomeGlanceValueID(stringValue: selectedID) else { return .missing }
        return WatchGlancePresentation.lookup(id, in: glance, now: now)
    }

    var body: some View {
        Group {
            if case let .found(sensor, condition) = lookup {
                SensorValueComplication(sensor: sensor, condition: condition, now: now, layout: layout)
            } else {
                message
            }
        }
        .watchAlwaysOnPrivacy()
    }

    private var messageText: String {
        state.glance == nil
            ? String(localized: "iPhone에서 조각보 홈을 열어 주세요", comment: "Watch: nothing received yet; open the iPhone app once")
            : WatchText.missing(lookup)
    }

    @ViewBuilder
    private var message: some View {
        switch layout {
        case .circular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "sensor")
                    .font(.title3)
                    .widgetAccentable()
            }
            .accessibilityLabel(Text(messageText))
        case .rectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label { Text(verbatim: Brand.appName) } icon: { Image(systemName: "sensor") }
                    .font(.headline)
                    .widgetAccentable()
                Text(messageText)
                    .font(.caption)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .inline:
            Label { Text(messageText) } icon: { Image(systemName: "sensor") }
        case .corner:
            Image(systemName: "sensor")
                .font(.title3)
                .widgetAccentable()
                .widgetLabel { Text(messageText) }
        }
    }
}

private struct SensorValueComplication: View {
    let sensor: HomeGlanceSensor
    let condition: HomeGlanceSensorCondition
    let now: Date
    let layout: WatchComplicationLayout

    private var isRecent: Bool { condition == .recent }
    private var isSensitive: Bool { WatchPrivacy.isSensitive(sensor) }
    private var kindLabel: String { HomeGlanceValueText.kindLabel(of: sensor) }
    private var symbol: String { HomeGlanceValueText.symbolName(of: sensor) }
    private var valueText: String { HomeGlanceValueText.valueText(of: sensor) ?? "—" }
    private var compactValue: String { HomeGlanceValueText.compactValueText(of: sensor) ?? "—" }

    var body: some View {
        switch layout {
        case .circular: circular
        case .rectangular: rectangular
        case .inline: inline
        case .corner: corner
        }
    }

    /// Not a current value: the circle shows when it was last confirmed instead.
    private var circularText: String {
        if isRecent { return compactValue }
        guard condition != .notYetRead, let checkedAt = sensor.checkedAt else { return "—" }
        return GlanceTime.compactString(checkedAt, now: now)
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: isRecent ? symbol : WatchText.conditionSymbol(condition, sensor: sensor))
                    .font(.caption.weight(.semibold))
                    .widgetAccentable()
                Text(verbatim: circularText)
                    .font(.system(size: 14, weight: .semibold))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .privacySensitive(isSensitive)
            }
            .padding(3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(kindLabel), \(isRecent ? valueText : WatchText.condition(condition, source: sensor.source))"))
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The room only when it fits next to the kind.
            ViewThatFits(in: .horizontal) {
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
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                        .widgetAccentable()
                    Text(kindLabel)
                        .minimumScaleFactor(0.7)
                }
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            Text(valueText)
                .font(.title3.weight(.semibold))
                .foregroundStyle(isRecent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .privacySensitive(isSensitive)
            Label {
                Text(WatchText.valueFooter(sensor, condition: condition, now: now))
            } icon: {
                if !isRecent { Image(systemName: WatchText.conditionSymbol(condition, sensor: sensor)) }
            }
            .font(.caption2)
            .foregroundStyle(isRecent ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        Label {
            // Not current: the symbol says why, the text says when — short enough to never be cut.
            Text(verbatim: "\(kindLabel) \(isRecent ? compactValue : circularText)")
        } icon: {
            Image(systemName: isRecent ? symbol : WatchText.conditionSymbol(condition, sensor: sensor))
        }
        .privacySensitive(isSensitive)
        .accessibilityLabel(Text(verbatim: "\(kindLabel), \(isRecent ? valueText : WatchText.valueFooter(sensor, condition: condition, now: now))"))
    }

    private var corner: some View {
        Text(verbatim: circularText)
            .font(.system(size: 16, weight: .semibold))
            .minimumScaleFactor(0.5)
            .privacySensitive(isSensitive)
            .widgetCurvesContent()
            .widgetLabel {
                Text(verbatim: isRecent ? kindLabel : "\(kindLabel) \(WatchText.condition(condition, source: sensor.source))")
            }
    }
}
