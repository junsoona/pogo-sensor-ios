import AppIntents
import SwiftUI
import WidgetKit

struct SensorValueWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: HomeGlanceWidgetKind.sensorValue, intent: SelectSensorIntent.self, provider: SensorValueProvider()) { entry in
            SensorValueWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(Text("센서값", comment: "Widget gallery: sensor value widget name"))
        .description(Text("선택한 조각보 센서나 Apple 홈 기기의 값을 앱이 마지막으로 확인한 시각과 함께 보여 줍니다.", comment: "Widget gallery: sensor value widget description"))
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct SelectSensorIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("센서 선택", comment: "Widget configuration title")
    static let description = IntentDescription(LocalizedStringResource("위젯에 표시할 값을 고릅니다. 조각보 센서와 Apple 홈 기기는 이름이 같아도 따로 표시됩니다.", comment: "Widget configuration description"))

    @Parameter(title: LocalizedStringResource("표시할 값", comment: "Widget configuration parameter: the value to show"))
    var sensor: GlanceSensorEntity?

    init() {}
}

/// A selectable value, identified by source + device + value (`HomeGlanceValueID`). POGO and
/// Apple Home entries with the same device name are separate entities, told apart by source.
struct GlanceSensorEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("센서값", comment: "Widget gallery: sensor value widget name; widget configuration value type"))
    static let defaultQuery = GlanceSensorQuery()

    /// `HomeGlanceValueID.stringValue`.
    let id: String
    let title: String
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    init(_ sensor: HomeGlanceSensor) {
        self.id = sensor.id.stringValue
        self.title = "\(HomeGlanceValueText.kindLabel(of: sensor)) · \(sensor.deviceName)"
        let source = sensor.source == .pogoLinuxAPI
            ? String(localized: "조각보 센서", comment: "Dashboard status source: 조각보 sensors")
            : String(localized: "Apple 홈", comment: "Dashboard status source: Apple Home")
        self.subtitle = sensor.roomName.map { "\(source) · \($0)" } ?? source
    }

    /// A selection whose value is gone, or can't be read right now (Apple Home off/denied). Kept
    /// (rather than dropped) so the widget says so instead of "nothing selected".
    init(unavailableID id: String, isUnreadableAppleHome: Bool) {
        self.id = id
        self.title = isUnreadableAppleHome
            ? String(localized: "Apple 홈 값을 표시할 수 없음", comment: "Sensor widget: Apple Home can't be read")
            : String(localized: "선택한 센서를 찾을 수 없음", comment: "Sensor widget: the selected sensor no longer exists")
        self.subtitle = ""
    }
}

struct GlanceSensorQuery: EntityStringQuery {
    /// Values offered for selection: everything stored, except Apple Home values while Apple
    /// Home isn't readable.
    private func selectable() -> [HomeGlanceSensor] {
        guard let snapshot = HomeGlanceTimeline.load().snapshot else { return [] }
        return snapshot.appleHome.access == .ready ? snapshot.sensors : snapshot.pogoSensors
    }

    func entities(for identifiers: [String]) async throws -> [GlanceSensorEntity] {
        let snapshot = HomeGlanceTimeline.load().snapshot
        let sensors = selectable()
        return identifiers.map { id in
            if let sensor = sensors.first(where: { $0.id.stringValue == id }) {
                return GlanceSensorEntity(sensor)
            }
            let isUnreadableAppleHome = HomeGlanceValueID(stringValue: id)?.device.source == .appleHome
                && snapshot.map { $0.appleHome.access != .ready } ?? false
            return GlanceSensorEntity(unavailableID: id, isUnreadableAppleHome: isUnreadableAppleHome)
        }
    }

    func entities(matching string: String) async throws -> [GlanceSensorEntity] {
        selectable().map(GlanceSensorEntity.init).filter {
            $0.title.localizedStandardContains(string) || $0.subtitle.localizedStandardContains(string)
        }
    }

    func suggestedEntities() async throws -> [GlanceSensorEntity] {
        selectable().map(GlanceSensorEntity.init)
    }

    /// A new widget starts with the first POGO temperature (else the first stored value).
    func defaultResult() async -> GlanceSensorEntity? {
        let sensors = selectable()
        let preferred = sensors.first { $0.pogoKind == .temperature } ?? sensors.first
        return preferred.map(GlanceSensorEntity.init)
    }
}

struct SensorValueProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> HomeGlanceEntry {
        HomeGlanceEntry(date: Date(), content: .snapshot(GlanceSamples.snapshot(now: Date())), selection: GlanceSamples.temperatureID.stringValue)
    }

    func snapshot(for configuration: SelectSensorIntent, in context: Context) async -> HomeGlanceEntry {
        let stored = HomeGlanceTimeline.load()
        if context.isPreview && (stored.snapshot == nil || configuration.sensor == nil) {
            return placeholder(in: context)
        }
        return HomeGlanceEntry(date: Date(), content: stored, selection: configuration.sensor?.id)
    }

    func timeline(for configuration: SelectSensorIntent, in context: Context) async -> Timeline<HomeGlanceEntry> {
        HomeGlanceTimeline.timeline(content: HomeGlanceTimeline.load(), selection: configuration.sensor?.id)
    }
}

struct SensorValueWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HomeGlanceEntry

    var body: some View {
        let layout = GlanceWidgetLayout(family) ?? .small
        SensorGlanceView(content: entry.content, selection: entry.selection, now: entry.date, layout: layout)
            .glanceWidgetBackground(layout)
    }
}
