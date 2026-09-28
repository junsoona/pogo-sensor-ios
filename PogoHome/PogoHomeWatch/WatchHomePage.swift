import SwiftUI

struct WatchRootView: View {
    var body: some View {
        TabView {
            WatchHomePage()
            WatchAppleHomePage()
        }
        .tabViewStyle(.verticalPage)
    }
}

/// Page 1: the POGO verdict, how the Watch got it, and the values picked on the iPhone.
struct WatchHomePage: View {
    @Environment(WatchSyncEngine.self) private var sync

    var body: some View {
        // Re-evaluated as time passes, so a value turns "old" on screen without new data.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            WatchHomeContent(
                state: sync.state,
                connection: sync.connectionStatus,
                isRefreshing: sync.isRefreshing,
                now: context.date,
                refresh: { Task { await sync.refresh() } },
                phoneLink: sync.phoneLink
            )
        }
    }
}

struct WatchHomeContent: View {
    let state: WatchStoredState
    let connection: WatchConnectionStatus
    let isRefreshing: Bool
    let now: Date
    let refresh: () -> Void

    private var headline: WatchPogoHeadline { WatchGlancePresentation.headline(state.glance, now: now) }
    private var selected: [WatchSelectedValue] { WatchGlancePresentation.selectedValues(state.glance, settings: state.settings, now: now) }

    /// The link to the iPhone app, for what to say while no settings have arrived.
    var phoneLink: WatchPhoneLinkStatus = .reachable
    /// `false` lays the same rows out flat — `ImageRenderer` can't draw a `List` on watchOS, so the
    /// rendering tests use this.
    var isInList = true

    var body: some View {
        Group {
            if isInList {
                NavigationStack {
                    List { rows }
                        .navigationTitle(Text(verbatim: Brand.appName))
                }
            } else {
                VStack(alignment: .leading, spacing: 10) { rows }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 6)
            }
        }
        // Wrist down (Always On): the home, room and device names and security-sensitive values go.
        .watchAlwaysOnPrivacy()
    }

    @ViewBuilder
    private var rows: some View {
        Section {
            header
        }
        Section {
            connectionRow
        }
        Section {
            if let hint = WatchGlancePresentation.setupHint(settings: state.settings, selectedCount: selected.count, phoneLink: phoneLink, isRefreshing: isRefreshing) {
                Text(WatchText.setupHint(hint))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(selected) { WatchValueRow(value: $0, now: now) }
            }
        } header: {
            Text("선택한 값", comment: "Watch: header of the values picked on the iPhone")
        }
        Section {
            Button(action: refresh) {
                HStack {
                    if isRefreshing {
                        ProgressView()
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("지금 확인", comment: "Watch: button that looks for a way to the bridge now")
                }
            }
            .disabled(isRefreshing)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let name = state.glance?.homeName {
                Text(name)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .privacySensitive()
            }
            // The source on its own line, so a long verdict ("Connection not confirmed") wraps whole.
            Label {
                Text(verbatim: Brand.name)
            } icon: {
                Image(systemName: WatchText.symbol(headline))
                    .foregroundStyle(WatchText.tone(headline).color)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            Text(WatchText.title(headline))
                .font(.headline)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.leading)
            Text(WatchText.detail(headline, now: now))
                .font(.footnote)
                .foregroundStyle(headline.isCurrent ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            if headline.isCurrent, let at = headline.confirmedAt {
                Text(GlanceTime.confirmation(at, now: now, isCurrent: true))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if state.glance?.pogo.isSimulated == true {
                Text("모의 데이터", comment: "Data source option: simulated data")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var connectionRow: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(WatchText.connectionTitle(connection))
                    .font(.footnote.weight(.semibold))
                if let detail = WatchText.connectionDetail(connection, now: now) {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: WatchText.connectionSymbol(connection))
        }
        .accessibilityElement(children: .combine)
    }
}

struct WatchValueRow: View {
    let value: WatchSelectedValue
    let now: Date

    var body: some View {
        switch value.lookup {
        case let .found(sensor, condition):
            found(sensor, condition)
        case let other:
            Label(WatchText.missing(other), systemImage: "questionmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func found(_ sensor: HomeGlanceSensor, _ condition: HomeGlanceSensorCondition) -> some View {
        let isRecent = condition == .recent
        return VStack(alignment: .leading, spacing: 1) {
            Label {
                Text(HomeGlanceValueText.kindLabel(of: sensor))
            } icon: {
                Image(systemName: HomeGlanceValueText.symbolName(of: sensor))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Text(HomeGlanceValueText.valueText(of: sensor) ?? "—")
                .font(.title3.weight(.semibold))
                .foregroundStyle(isRecent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .privacySensitive(WatchPrivacy.isSensitive(sensor))
            Text(place(sensor))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .privacySensitive()
            Label {
                Text(WatchText.valueFooter(sensor, condition: condition, now: now))
            } icon: {
                if !isRecent { Image(systemName: WatchText.conditionSymbol(condition, sensor: sensor)) }
            }
            .font(.caption2)
            .foregroundStyle(isRecent ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
        }
        .accessibilityElement(children: .combine)
    }

    private func place(_ sensor: HomeGlanceSensor) -> String {
        guard let room = sensor.roomName, !room.isEmpty else { return sensor.deviceName }
        return "\(room) · \(sensor.deviceName)"
    }
}
