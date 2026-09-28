#if os(iOS)
import SwiftUI
import WidgetKit

// Shared by the widget extension (which renders them) and the app (whose tests render them to
// check every state, language, text size and appearance). Views only draw verdicts from
// `HomeGlancePresentation`; they decide nothing about freshness themselves.

/// The widget family a glance view is laid out for — mirrored from `WidgetFamily` so the views
/// compile (and can be rendered in tests) outside a widget.
enum GlanceWidgetLayout: CaseIterable, Sendable {
    case small
    case medium
    case circular
    case rectangular
    case inline

    var isAccessory: Bool {
        switch self {
        case .small, .medium: return false
        case .circular, .rectangular, .inline: return true
        }
    }

    init?(_ family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .small
        case .systemMedium: self = .medium
        case .accessoryCircular: self = .circular
        case .accessoryRectangular: self = .rectangular
        case .accessoryInline: self = .inline
        default: return nil
        }
    }
}

/// Colors never carry meaning alone: every tinted element is next to a symbol and text.
enum GlanceTone {
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

/// The sample shown in the widget gallery and as a placeholder before real data is read. Not
/// real data: gallery previews render it redacted or as an obvious example.
enum GlanceSamples {
    static let moduleID = UUID(uuidString: "8A3B1C10-0011-4000-8000-000000000011")!
    static var temperatureID: HomeGlanceValueID { .pogo(module: moduleID, kind: .temperature) }

    static func snapshot(now: Date) -> HomeGlanceSnapshot {
        HomeGlanceSnapshot(
            writtenAt: now,
            homeName: String(localized: "우리 집", comment: "Default home name"),
            pogo: HomeGlancePogoSection(
                state: .healthy,
                verifiedAt: now,
                moduleCount: 2,
                onlineCount: 2,
                attention: [],
                isSimulated: false
            ),
            appleHome: HomeGlanceAppleHomeSection(access: .ready, verifiedAt: now, accessoryCount: 3, notRespondingCount: 0),
            sensors: [
                HomeGlanceSensor(
                    id: temperatureID,
                    deviceName: String(localized: "거실 환경 모듈", comment: "Mock data module name"),
                    roomName: String(localized: "거실", comment: "Default room name"),
                    kindRawValue: SensorKind.temperature.rawValue,
                    value: 23.4,
                    status: .normal,
                    isDeviceConnected: true,
                    checkedAt: now
                ),
            ]
        )
    }
}

/// A small caption naming where a value or verdict comes from.
struct GlanceSourceLabel: View {
    let source: DeviceSource

    var body: some View {
        switch source {
        case .pogoLinuxAPI:
            Label { Text(verbatim: Brand.name) } icon: { Image(systemName: "sensor.fill") }
        case .appleHome:
            Label { Text("Apple 홈", comment: "Dashboard status source: Apple Home") } icon: { Image(systemName: "homekit") }
        }
    }
}

/// A full-widget message for states without data to show (nothing stored, nothing selected, a
/// deleted selection…).
struct GlanceMessageView: View {
    let layout: GlanceWidgetLayout
    let symbol: String
    let title: Text
    let detail: Text?

    var body: some View {
        switch layout {
        case .inline:
            Label { title } icon: { Image(systemName: symbol) }
        case .circular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: symbol)
                    .font(.title2.weight(.semibold))
                    .widgetAccentable()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
        case .rectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label { title.font(.headline) } icon: { Image(systemName: symbol) }
                    .widgetAccentable()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let detail {
                    detail
                        .font(.caption)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .small, .medium:
            // Larger text sizes drop the symbol, then the detail; the title always stays.
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    symbolView
                    titleView
                    detailView
                }
                VStack(alignment: .leading, spacing: 4) {
                    titleView
                    detailView
                }
                titleView
                    .minimumScaleFactor(0.5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var symbolView: some View {
        Image(systemName: symbol)
            .font(.title2)
            .foregroundStyle(.secondary)
            .widgetAccentable()
    }

    private var titleView: some View {
        title
            .font(.headline)
            .lineLimit(4)
            .minimumScaleFactor(0.7)
    }

    @ViewBuilder
    private var detailView: some View {
        if let detail {
            detail
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension View {
    /// The container background every glance widget uses: the system background on the Home
    /// Screen, none on the Lock Screen (the circular views draw `AccessoryWidgetBackground`
    /// themselves).
    func glanceWidgetBackground(_ layout: GlanceWidgetLayout) -> some View {
        containerBackground(for: .widget) {
            switch layout {
            case .small, .medium:
                Color(uiColor: .systemBackground)
            case .circular, .rectangular, .inline:
                Color.clear
            }
        }
    }
}
#endif
