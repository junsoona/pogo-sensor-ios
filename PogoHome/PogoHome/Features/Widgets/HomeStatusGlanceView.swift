#if os(iOS)
import SwiftUI
import WidgetKit

/// The "집 상태" widget: the POGO sensors' last confirmed verdict and, separately, Apple Home's.
/// The two are never merged into one "all fine" — as on the Dashboard.
///
/// Lock Screen shapes show no home, room or device names; the Home Screen ones mark names
/// privacy-sensitive (redacted while locked, e.g. in StandBy).
struct HomeStatusGlanceView: View {
    let content: HomeGlanceStore.LoadResult
    let now: Date
    let layout: GlanceWidgetLayout

    var body: some View {
        Group {
            if let snapshot = content.snapshot {
                HomeStatusGlanceBody(snapshot: snapshot, now: now, layout: layout)
            } else {
                GlanceMessageView(
                    layout: layout,
                    symbol: "house",
                    title: Text("조각보 홈 앱을 열어 주세요", comment: "Widget: no stored data yet"),
                    detail: Text("앱이 마지막으로 확인한 상태가 여기에 표시됩니다.", comment: "Widget: no stored data yet, detail")
                )
            }
        }
        .widgetURL(HomeGlanceLink.dashboard.url)
    }
}

private struct HomeStatusGlanceBody: View {
    let snapshot: HomeGlanceSnapshot
    let now: Date
    let layout: GlanceWidgetLayout

    private var pogo: HomeGlancePogoStatus { snapshot.pogoStatus(at: now) }
    private var appleHome: HomeGlanceAppleHomeStatus { snapshot.appleHomeStatus(at: now) }

    var body: some View {
        switch layout {
        case .small: small
        case .medium: medium
        case .circular: circular
        case .rectangular: rectangular
        case .inline: inline
        }
    }

    // MARK: Home Screen

    /// Larger text sizes fall back to fewer lines; every variant keeps the verdict and when it
    /// was confirmed.
    private var small: some View {
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 3) {
                header(showsHomeName: true)
                pogoBlock(showsSource: true)
                pogoConfirmation
                Spacer(minLength: 2)
                appleHomeLine
            }
            VStack(alignment: .leading, spacing: 3) {
                header(showsHomeName: true)
                pogoBlock(showsSource: true)
                pogoConfirmation
            }
            VStack(alignment: .leading, spacing: 2) {
                header(showsHomeName: false)
                pogoBlock(showsSource: false)
                pogoConfirmation
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: pogoSymbol)
                        .foregroundStyle(pogoTone.color)
                        .widgetAccentable()
                    Text(verbatim: "\(Brand.name) \(pogoHeadline)")
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                }
                .font(.headline)
                pogoConfirmation
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        ViewThatFits(in: .vertical) {
            mediumBody(showsHomeName: true, showsAttention: true)
            mediumBody(showsHomeName: true, showsAttention: false)
            mediumBody(showsHomeName: false, showsAttention: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func mediumBody(showsHomeName: Bool, showsAttention: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(showsHomeName: showsHomeName)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    pogoBlock(showsSource: showsHomeName)
                    pogoConfirmation
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                appleHomeBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showsAttention, pogo.showsCounts, let first = pogo.attention.first {
                Spacer(minLength: 0)
                attentionLine(first, more: pogo.attention.count - 1)
            }
        }
    }

    /// The POGO verdict symbol with the home name — or, when space is short, with "POGO" so the
    /// source is still named.
    private func header(showsHomeName: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: pogoSymbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(pogoTone.color)
                .widgetAccentable()
                .accessibilityHidden(true)
            if showsHomeName {
                Text(snapshot.homeName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .privacySensitive()
            } else {
                Text(verbatim: Brand.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func pogoBlock(showsSource: Bool) -> some View {
        if showsSource {
            HStack(spacing: 4) {
                GlanceSourceLabel(source: .pogoLinuxAPI)
                if pogo.isSimulated {
                    Text("모의 데이터", comment: "Data source option: simulated data")
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Text(pogoHeadline)
            .font(.headline)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
        if pogo.showsCounts {
            Text(countsText)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var pogoConfirmation: some View {
        Text(GlanceTime.confirmation(pogo.verifiedAt, now: now, isCurrent: pogo.showsCounts))
            .font(.caption2)
            .foregroundStyle(pogo.showsCounts ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            .lineLimit(3)
            .minimumScaleFactor(0.5)
    }

    private var appleHomeLine: some View {
        HStack(spacing: 4) {
            Image(systemName: "homekit")
            Text(appleHomeShortText)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .combine)
    }

    private var appleHomeBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            GlanceSourceLabel(source: .appleHome)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(appleHomeShortText)
                .font(.headline)
                .foregroundStyle(appleHomeTone == .attention ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(appleHomeConfirmation)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
    }

    private func attentionLine(_ item: HomeGlanceAttentionItem, more: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(item.name)
                .privacySensitive()
            Text(verbatim: "·")
            Text(reasonText(item.reason))
            if more > 0 {
                Text(verbatim: "+\(more)")
            }
        }
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .combine)
    }

    // MARK: Lock Screen

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: pogoSymbol)
                    .font(.body.weight(.semibold))
                    .widgetAccentable()
                if pogo.showsCounts {
                    Text(verbatim: "\(pogo.onlineCount)/\(pogo.moduleCount)")
                        .font(.caption.weight(.semibold))
                        .minimumScaleFactor(0.6)
                } else if let verifiedAt = pogo.verifiedAt {
                    // Old or unverified: the time it was last confirmed, not a count.
                    Text(GlanceTime.compactString(verifiedAt, now: now))
                        .font(.system(size: 11, weight: .medium))
                        .minimumScaleFactor(0.6)
                }
            }
            .lineLimit(1)
            .padding(4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(String(localized: "조각보 센서", comment: "Dashboard status source: 조각보 sensors")), \(pogoHeadline)"))
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: pogoSymbol)
                    .widgetAccentable()
                Text(verbatim: "\(Brand.name) \(pogoHeadline)")
            }
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if pogo.showsCounts {
                        Text(countsText)
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "homekit")
                        Text(appleHomeShortText)
                    }
                    Text(GlanceTime.confirmation(pogo.verifiedAt, now: now, isCurrent: pogo.showsCounts))
                }
                Text(GlanceTime.confirmation(pogo.verifiedAt, now: now, isCurrent: pogo.showsCounts))
            }
            .font(.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        // One line: verdict and, if it isn't a recent confirmation, when it was last confirmed.
        Label {
            if !pogo.showsCounts, let verifiedAt = pogo.verifiedAt {
                Text(verbatim: "\(Brand.name) \(pogoHeadline) · \(GlanceTime.compactString(verifiedAt, now: now))")
            } else {
                Text(verbatim: "\(Brand.name) \(pogoHeadline)")
            }
        } icon: {
            Image(systemName: pogoSymbol)
        }
    }

    // MARK: Text

    private var pogoHeadline: String {
        switch pogo.verdict {
        case .healthy:
            return String(localized: "정상", comment: "Sensor status")
        case .attentionNeeded:
            return String(localized: "확인 필요 \(pogo.attention.count)개", comment: "Room card: number of devices needing attention (plural)")
        case .unverified:
            return String(localized: "연결 확인 안 됨", comment: "Widget: the POGO bridge connection was not confirmed when last written")
        case .stale:
            return String(localized: "오래된 정보", comment: "Widget: the stored state is older than the widget's freshness limit")
        case .waitingForData:
            return String(localized: "데이터 없음", comment: "Widget: no POGO data was ever confirmed")
        }
    }

    private var countsText: String {
        String(localized: "연결 \(pogo.onlineCount)/\(pogo.moduleCount)", comment: "Widget: online POGO modules / all POGO modules")
    }

    private var pogoTone: GlanceTone {
        switch pogo.verdict {
        case .healthy: return .fine
        case .attentionNeeded: return .attention
        case .unverified, .stale, .waitingForData: return .neutral
        }
    }

    private var pogoSymbol: String {
        switch pogo.verdict {
        case .healthy: return "checkmark.circle.fill"
        case .attentionNeeded: return "exclamationmark.triangle.fill"
        case .unverified: return "wifi.exclamationmark"
        case .stale: return "clock.badge.exclamationmark"
        case .waitingForData: return "hourglass"
        }
    }

    private var appleHomeShortText: String {
        switch appleHome {
        case .unavailable(.off):
            return String(localized: "꺼짐", comment: "Apple Home: off")
        case .unavailable(.denied), .unavailable(.restricted):
            return String(localized: "접근 권한 없음", comment: "Widget: Apple Home access denied or restricted")
        case .unavailable:
            return String(localized: "사용할 수 없음", comment: "Widget: Apple Home unsupported on this device")
        case .noHome:
            return String(localized: "집 없음", comment: "Widget: Apple Home has no home")
        case .noDevices:
            return String(localized: "기기 없음", comment: "Widget: Apple Home has no devices to show")
        case .stale:
            return String(localized: "오래된 정보", comment: "Widget: the stored state is older than the widget's freshness limit")
        case let .allResponding(total, _):
            return String(localized: "응답 \(total)/\(total)", comment: "Widget: responding Apple Home devices / listed devices")
        case let .someNotResponding(notResponding, total, _):
            return String(localized: "응답 \(total - notResponding)/\(total)", comment: "Widget: responding Apple Home devices / listed devices")
        }
    }

    private var appleHomeConfirmation: String {
        switch appleHome {
        case let .allResponding(_, verifiedAt), let .someNotResponding(_, _, verifiedAt):
            return GlanceTime.confirmation(verifiedAt, now: now, isCurrent: true)
        case let .stale(verifiedAt):
            return GlanceTime.confirmation(verifiedAt, now: now, isCurrent: false)
        case .unavailable, .noHome, .noDevices:
            return String(localized: "저장된 Apple 홈 상태를 표시하지 않습니다", comment: "Widget: Apple Home can't be read, so nothing stored about it is shown")
        }
    }

    private var appleHomeTone: GlanceTone {
        switch appleHome {
        case .allResponding: return .fine
        case .someNotResponding: return .attention
        default: return .neutral
        }
    }

    private func reasonText(_ reason: HomeGlanceAttentionReason) -> String {
        switch reason {
        case .offline: return String(localized: "오프라인", comment: "Attention reason")
        case .stale: return String(localized: "업데이트 지연", comment: "Attention reason")
        case .error: return String(localized: "센서 오류", comment: "Attention reason")
        case .unavailable: return String(localized: "사용 불가", comment: "Sensor status")
        }
    }
}
#endif
