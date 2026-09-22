import SwiftUI

/// Summarizes the home's status from plain facts only (online/offline, stale, or
/// conditioning/error readings) — no health thresholds or AQI-style scoring. `health` (see
/// `HomeHealthEvaluator`) is computed by the caller, not this view, so connection state and
/// "everything's fine" are never conflated here.
struct HomeStatusCard: View {
    let snapshot: HomeSnapshot
    let health: HomeHealthState

    private var headline: String {
        switch health {
        case .waitingForData: return "센서 데이터를 기다리는 중입니다"
        case .reconnecting: return "센서 허브 연결을 확인해 주세요"
        case .recoveringRegistry: return "센서 정보를 다시 확인하고 있습니다"
        case .healthy: return "집 상태가 안정적입니다"
        case .attentionNeeded: return "확인이 필요한 센서가 있습니다"
        }
    }

    private var subheadline: String {
        switch health {
        case .waitingForData:
            return "아직 수신된 센서 데이터가 없습니다"
        case .reconnecting:
            return "마지막으로 받은 센서값을 표시하고 있습니다"
        case .recoveringRegistry:
            return "마지막으로 받은 센서값을 표시하고 있습니다"
        case .healthy:
            return "모든 센서가 연결되어 있습니다"
        case .attentionNeeded:
            var parts: [String] = []
            let staleCount = snapshot.staleModules.count
            let offlineCount = snapshot.modules.filter { !$0.isOnline }.count
            if offlineCount > 0 {
                parts.append("오프라인 기기 \(offlineCount)개")
            }
            if staleCount > 0 {
                parts.append("업데이트가 지연된 기기 \(staleCount)개")
            }
            if parts.isEmpty {
                parts.append("확인이 필요한 센서를 점검해 주세요")
            }
            return parts.joined(separator: " · ")
        }
    }

    private var iconSymbolName: String {
        switch health {
        case .healthy: return "checkmark.circle.fill"
        case .attentionNeeded: return "exclamationmark.triangle.fill"
        case .reconnecting: return "wifi.exclamationmark"
        case .recoveringRegistry: return "arrow.triangle.2.circlepath"
        case .waitingForData: return "hourglass"
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
            Image(systemName: iconSymbolName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(iconTint, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.headline)
                Text(subheadline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(PogoTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
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
    }
    .padding()
}
