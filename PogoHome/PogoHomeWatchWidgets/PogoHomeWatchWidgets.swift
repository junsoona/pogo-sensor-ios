import AppIntents
import SwiftUI
import WidgetKit

/// The Watch's Smart Stack widgets and watch face complications. They read only what the Watch app
/// stored (`WatchStateStore`); they never contact the POGO bridge, the iPhone or HomeKit. Their
/// timelines add an entry at every moment what they show turns old by itself, so a complication
/// labels old data as old on time even when WatchKit doesn't reload it.
@main
struct PogoHomeWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WatchHomeStatusWidget()
        WatchSensorWidget()
    }
}

struct WatchGlanceEntry: TimelineEntry {
    let date: Date
    let state: WatchStoredState
    /// The sensor widget's configured value; `nil` = the first value picked on the iPhone.
    var selection: String? = nil
}

enum WatchGlanceTimeline {
    /// With no reload from the app, read the file again after this long anyway.
    static let safetyReloadInterval: TimeInterval = 60 * 60

    static func load() -> WatchStoredState {
        WatchStateStore.shared()?.load() ?? .empty
    }

    static func timeline(state: WatchStoredState, selection: String?, now: Date = Date()) -> Timeline<WatchGlanceEntry> {
        let resolved = selection ?? state.settings?.selectedValueIDs.first
        let changes = WatchGlancePresentation.changeDates(state.glance, selection: resolved.flatMap(HomeGlanceValueID.init(stringValue:)), after: now)
        let entries = ([now] + changes).map { WatchGlanceEntry(date: $0, state: state, selection: selection) }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(safetyReloadInterval)))
    }

    /// An obvious example for the face editor and the Smart Stack gallery, never real data.
    static func sample(now: Date) -> WatchStoredState {
        let module = UUID(uuidString: "8A3B1C10-0011-4000-8000-000000000011")!
        let id = HomeGlanceValueID.pogo(module: module, kind: .temperature)
        let glance = HomeGlanceSnapshot(
            writtenAt: now,
            homeName: String(localized: "우리 집", comment: "Default home name"),
            pogo: HomeGlancePogoSection(state: .healthy, verifiedAt: now, moduleCount: 2, onlineCount: 2, attention: [], isSimulated: false),
            appleHome: .off,
            sensors: [
                HomeGlanceSensor(
                    id: id,
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
        let settings = WatchSettings(updatedAt: now, dataSourceMode: .live, hubBaseURL: nil, selectedValueIDs: [id.stringValue], moduleLabels: [])
        return WatchStoredState(glance: glance, settings: settings, record: .empty)
    }
}

// MARK: - Home status

struct WatchHomeStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchWidgetKind.homeStatus, provider: WatchHomeStatusProvider()) { entry in
            WatchHomeStatusEntryView(entry: entry)
        }
        .configurationDisplayName(Text("집 상태", comment: "Widget gallery: home status widget name"))
        .description(Text("조각보 센서 상태를 Watch가 마지막으로 확인한 시각과 함께 보여 줍니다.", comment: "Watch widget gallery: home status description"))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct WatchHomeStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchGlanceEntry {
        WatchGlanceEntry(date: Date(), state: WatchGlanceTimeline.sample(now: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchGlanceEntry) -> Void) {
        let stored = WatchGlanceTimeline.load()
        let state = context.isPreview && stored.glance == nil ? WatchGlanceTimeline.sample(now: Date()) : stored
        completion(WatchGlanceEntry(date: Date(), state: state))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchGlanceEntry>) -> Void) {
        completion(WatchGlanceTimeline.timeline(state: WatchGlanceTimeline.load(), selection: nil))
    }
}

struct WatchHomeStatusEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchGlanceEntry

    var body: some View {
        WatchHomeStatusComplication(state: entry.state, now: entry.date, layout: WatchComplicationLayout(family) ?? .rectangular)
            .containerBackground(for: .widget) { Color.clear }
    }
}

// MARK: - Sensor value

struct WatchSensorWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WatchWidgetKind.sensorValue, intent: WatchSensorIntent.self, provider: WatchSensorProvider()) { entry in
            WatchSensorEntryView(entry: entry)
        }
        .configurationDisplayName(Text("센서값", comment: "Widget gallery: sensor value widget name"))
        .description(Text("iPhone에서 Watch용으로 고른 값을 마지막 확인 시각과 함께 보여 줍니다.", comment: "Watch widget gallery: sensor value description"))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct WatchSensorIntent: WidgetConfigurationIntent {
    static let title = LocalizedStringResource("센서 선택", comment: "Widget configuration title")
    static let description = IntentDescription(LocalizedStringResource("Watch에 표시할 값을 고릅니다.", comment: "Watch widget configuration description"))

    @Parameter(title: LocalizedStringResource("표시할 값", comment: "Widget configuration parameter: the value to show"))
    var sensor: WatchSensorEntity?

    init() {}

    init(sensor: WatchSensorEntity?) {
        self.sensor = sensor
    }
}

/// One of the values picked on the iPhone for the Watch (`HomeGlanceValueID.stringValue`).
struct WatchSensorEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("센서값", comment: "Widget gallery: sensor value widget name; widget configuration value type"))
    static let defaultQuery = WatchSensorQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    init(_ sensor: HomeGlanceSensor) {
        self.init(id: sensor.id.stringValue, title: "\(HomeGlanceValueText.kindLabel(of: sensor)) · \(sensor.deviceName)")
    }
}

struct WatchSensorQuery: EntityQuery {
    static func selectable(in state: WatchStoredState) -> [WatchSensorEntity] {
        guard let glance = state.glance, let settings = state.settings else { return [] }
        return settings.selectedValues.compactMap { glance.sensor(with: $0).map(WatchSensorEntity.init) }
    }

    func entities(for identifiers: [String]) async throws -> [WatchSensorEntity] {
        let selectable = Self.selectable(in: WatchGlanceTimeline.load())
        return identifiers.map { id in
            selectable.first { $0.id == id }
                ?? WatchSensorEntity(id: id, title: String(localized: "선택한 센서를 찾을 수 없음", comment: "Sensor widget: the selected sensor no longer exists"))
        }
    }

    func suggestedEntities() async throws -> [WatchSensorEntity] {
        Self.selectable(in: WatchGlanceTimeline.load())
    }
}

struct WatchSensorProvider: AppIntentTimelineProvider {
    /// watchOS offers these in the face editor and the Smart Stack: "the first picked value", and
    /// each value picked on the iPhone.
    func recommendations() -> [AppIntentRecommendation<WatchSensorIntent>] {
        let first = AppIntentRecommendation(intent: WatchSensorIntent(), description: Text("첫 번째로 고른 값", comment: "Watch widget recommendation: the first value picked on the iPhone"))
        let picked = WatchSensorQuery.selectable(in: WatchGlanceTimeline.load()).map { entity in
            AppIntentRecommendation(intent: WatchSensorIntent(sensor: entity), description: Text(entity.title))
        }
        return [first] + picked
    }

    func placeholder(in context: Context) -> WatchGlanceEntry {
        WatchGlanceEntry(date: Date(), state: WatchGlanceTimeline.sample(now: Date()))
    }

    func snapshot(for configuration: WatchSensorIntent, in context: Context) async -> WatchGlanceEntry {
        let stored = WatchGlanceTimeline.load()
        if context.isPreview && stored.glance == nil { return placeholder(in: context) }
        return WatchGlanceEntry(date: Date(), state: stored, selection: configuration.sensor?.id)
    }

    func timeline(for configuration: WatchSensorIntent, in context: Context) async -> Timeline<WatchGlanceEntry> {
        WatchGlanceTimeline.timeline(state: WatchGlanceTimeline.load(), selection: configuration.sensor?.id)
    }
}

struct WatchSensorEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchGlanceEntry

    var body: some View {
        WatchSensorComplication(state: entry.state, selection: entry.selection, now: entry.date, layout: WatchComplicationLayout(family) ?? .rectangular)
            .containerBackground(for: .widget) { Color.clear }
    }
}
