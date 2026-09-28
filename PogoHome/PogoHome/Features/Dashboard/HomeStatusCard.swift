import SwiftUI

/// Summarizes the POGO sensors' status — and only theirs: Apple Home devices are summarized
/// separately (`AppleHomeStatusCard`), so the wording here always names POGO sensors.
///
/// Summarizes the status from plain facts only (online/offline, stale, or
/// conditioning/error readings) — no health thresholds or AQI-style scoring. `health` (see
/// `HomeHealthEvaluator`) is computed by the caller, not this view, so connection state and
/// "everything's fine" are never conflated here.
struct HomeStatusCard: View {
    let snapshot: HomeSnapshot
    let health: HomeHealthState
    /// Why nothing is shown yet, while no module has been received (`AppModel.dataWait`).
    var dataWait: HomeDataWait? = nil

    private var headline: String {
        switch (health, dataWait) {
        case (.waitingForData, .connecting?): return String(localized: "센서 허브에 연결하는 중입니다", comment: "Home status headline: connecting to the sensor hub, nothing received yet")
        case (.waitingForData, .unreachable?): return String(localized: "센서 허브에 연결할 수 없습니다", comment: "Home status headline: the sensor hub can't be reached, nothing received yet")
        case (.waitingForData, _): return String(localized: "센서 데이터를 기다리는 중입니다", comment: "Home status headline")
        case (.reconnecting, _): return String(localized: "센서 허브 연결을 확인해 주세요", comment: "Home status headline")
        case (.recoveringRegistry, _): return String(localized: "센서 정보를 다시 확인하고 있습니다", comment: "Home status headline")
        case (.healthy, _): return String(localized: "조각보 센서 상태가 안정적입니다", comment: "Home status headline (POGO sensors only)")
        case (.attentionNeeded, _): return String(localized: "확인이 필요한 센서가 있습니다", comment: "Home status headline")
        }
    }

    private var subheadline: String {
        switch health {
        case .waitingForData where dataWait == .unreachable:
            return String(localized: "다시 연결하는 중입니다. 허브 전원과 API 주소를 확인해 주세요", comment: "Home status detail: the sensor hub can't be reached and is being retried")
        case .waitingForData:
            return String(localized: "아직 수신된 센서 데이터가 없습니다", comment: "Home status detail")
        case .reconnecting, .recoveringRegistry:
            return String(localized: "마지막으로 받은 센서값을 표시하고 있습니다", comment: "Home status detail")
        case .healthy:
            return String(localized: "모든 조각보 센서가 연결되어 있습니다", comment: "Home status detail (POGO sensors only)")
        case .attentionNeeded:
            let staleCount = snapshot.staleModules.count
            let offlineCount = snapshot.modules.filter { !$0.isOnline }.count
            let offlineText = String(localized: "오프라인 기기 \(offlineCount)개", comment: "Home status detail: number of offline devices (plural)")
            let staleText = String(localized: "업데이트가 지연된 기기 \(staleCount)개", comment: "Home status detail: number of devices with delayed updates (plural)")
            switch (offlineCount > 0, staleCount > 0) {
            case (true, true):
                return String(localized: "\(offlineText) · \(staleText)", comment: "Two home status details joined")
            case (true, false):
                return offlineText
            case (false, true):
                return staleText
            case (false, false):
                return String(localized: "확인이 필요한 센서를 점검해 주세요", comment: "Home status detail")
            }
        }
    }

    private var iconSymbolName: String {
        switch health {
        case .healthy: return "checkmark.circle.fill"
        case .attentionNeeded: return "exclamationmark.triangle.fill"
        case .reconnecting: return "wifi.exclamationmark"
        case .recoveringRegistry: return "arrow.triangle.2.circlepath"
        case .waitingForData: return dataWait == .unreachable ? "wifi.exclamationmark" : "hourglass"
        }
    }

    /// Green is reserved for `.healthy` — never shown while disconnected, reconnecting, or
    /// still waiting for the first snapshot, even though a stale snapshot on screen might
    /// otherwise look "fine" at a glance.
    private var iconTint: Color {
        switch health {
        case .healthy: return .green
        case .attentionNeeded: return .orange
        case .reconnecting, .recoveringRegistry, .waitingForData: return .gray
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            IconCircle(systemName: iconSymbolName, diameter: 46, background: iconTint, relativeTo: .title2, maximumScale: 1.4)

            VStack(alignment: .leading, spacing: 4) {
                DashboardSourceCaption(text: String(localized: "조각보 센서", comment: "Dashboard status source: 조각보 sensors"), symbol: "sensor.fill")
                Text(headline)
                    .font(.headline)
                Text(subheadline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(PogoTheme.cardPadding)
        // Fills the height it's given: equal-height side-by-side cards on a wide Dashboard.
        // (In the phone layout the scroll view proposes no height, so this changes nothing.)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(PogoTheme.tile, in: RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    VStack(spacing: 16) {
        HomeStatusCard(snapshot: MockSensorFixtures.previewSnapshot, health: .healthy)
        HomeStatusCard(snapshot: MockSensorFixtures.previewSnapshot, health: .reconnecting)
        HomeStatusCard(snapshot: MockSensorFixtures.previewSnapshot, health: .recoveringRegistry)
        HomeStatusCard(snapshot: HomeSnapshot(timestamp: .now, rooms: [], modules: []), health: .waitingForData)
        HomeStatusCard(snapshot: HomeSnapshot(timestamp: .now, rooms: [], modules: []), health: .waitingForData, dataWait: .connecting)
        HomeStatusCard(snapshot: HomeSnapshot(timestamp: .now, rooms: [], modules: []), health: .waitingForData, dataWait: .unreachable)
    }
    .padding()
}
