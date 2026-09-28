import SwiftUI
import WidgetKit

struct HomeStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: HomeGlanceWidgetKind.homeStatus, provider: HomeStatusProvider()) { entry in
            HomeStatusWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(Text("집 상태", comment: "Widget gallery: home status widget name"))
        .description(Text("조각보 센서와 Apple 홈 기기를 앱이 마지막으로 확인한 상태로 보여 줍니다.", comment: "Widget gallery: home status widget description"))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct HomeStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> HomeGlanceEntry {
        HomeGlanceEntry(date: Date(), content: .snapshot(GlanceSamples.snapshot(now: Date())))
    }

    func getSnapshot(in context: Context, completion: @escaping (HomeGlanceEntry) -> Void) {
        let stored = HomeGlanceTimeline.load()
        // The gallery shows an example until the app has stored something real.
        let content = context.isPreview && stored.snapshot == nil ? .snapshot(GlanceSamples.snapshot(now: Date())) : stored
        completion(HomeGlanceEntry(date: Date(), content: content))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HomeGlanceEntry>) -> Void) {
        completion(HomeGlanceTimeline.timeline(content: HomeGlanceTimeline.load()))
    }
}

struct HomeStatusWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HomeGlanceEntry

    var body: some View {
        let layout = GlanceWidgetLayout(family) ?? .small
        HomeStatusGlanceView(content: entry.content, now: entry.date, layout: layout)
            .glanceWidgetBackground(layout)
    }
}
