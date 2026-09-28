import SwiftUI
import WidgetKit

/// PogoHome's widgets and controls. They read only what the app last stored (`HomeGlanceStore`,
/// `AppleHomePowerStore`); they never contact the POGO bridge or HomeKit themselves. The Apple
/// Home power control's tap runs in the app process.
@main
struct PogoHomeWidgetsBundle: WidgetBundle {
    var body: some Widget {
        HomeStatusWidget()
        SensorValueWidget()
        if #available(iOS 27.0, *) {
            AppleHomePowerControl()
        }
    }
}

/// One timeline entry: the stored glance as it was read, drawn as of `date`.
struct HomeGlanceEntry: TimelineEntry {
    let date: Date
    let content: HomeGlanceStore.LoadResult
    /// The sensor widget's configured value (`HomeGlanceValueID.stringValue`).
    var selection: String? = nil
}

enum HomeGlanceTimeline {
    /// With no reload request from the app, re-read the stored file after this long anyway, in
    /// case a request was dropped. Far apart on purpose: the app asks for reloads when data
    /// changes, and the timeline entries below already handle aging.
    static let safetyReloadInterval: TimeInterval = 60 * 60

    static func load() -> HomeGlanceStore.LoadResult {
        HomeGlanceStore.shared()?.load() ?? .missing
    }

    /// An entry now, plus one at every moment the stored data's presentation changes by itself
    /// (a confirmation turning old, midnight) — so the widget labels old data as old on time
    /// even if WidgetKit postpones every reload.
    static func timeline(
        content: HomeGlanceStore.LoadResult,
        selection: String? = nil,
        now: Date = Date()
    ) -> Timeline<HomeGlanceEntry> {
        let sensorID = selection.flatMap(HomeGlanceValueID.init(stringValue:))
        let changes = content.snapshot?.presentationChangeDates(after: now, sensorID: sensorID) ?? []
        let entries = ([now] + changes).map { HomeGlanceEntry(date: $0, content: content, selection: selection) }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(safetyReloadInterval)))
    }
}
