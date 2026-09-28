import SwiftUI

/// The Dashboard's Apple Home status, next to (never merged into) the POGO sensor status: says
/// whether Apple Home can be read at all, and if so how many listed devices respond. Green only
/// for a readable Apple Home whose every listed device responds.
///
/// "Responding" is HomeKit's reachability. Value reads are a separate line (`valueCheck`): a
/// responding accessory whose value read timed out is counted there, never as not responding.
struct AppleHomeStatusCard: View {
    let summary: AppleHomeStatusSummary
    var valueCheck: AppleHomeValueCheckSummary?
    /// The card opens the list of the devices it counts (`AppleHomeIssuesView`).
    var showsDisclosure = false

    private var headline: String {
        switch summary {
        case let .unavailable(state):
            switch state {
            case .off: return String(localized: "Apple 홈 연결 꺼짐", comment: "Dashboard Apple Home status headline")
            case .loading: return String(localized: "Apple 홈 확인 중", comment: "Dashboard Apple Home status headline")
            case .denied, .restricted: return String(localized: "Apple 홈 접근 권한 없음", comment: "Dashboard Apple Home status headline")
            case .unsupported, .noHome, .ready: return String(localized: "Apple 홈을 사용할 수 없음", comment: "Apple Home notice title")
            }
        case .noHome: return String(localized: "Apple 홈에 집이 없음", comment: "Apple Home notice title")
        case .noDevices: return String(localized: "Apple 홈 기기 없음", comment: "Dashboard Apple Home status headline")
        case .allResponding: return String(localized: "Apple 홈 기기가 모두 응답합니다", comment: "Dashboard Apple Home status headline")
        case .someNotResponding: return String(localized: "응답하지 않는 Apple 홈 기기가 있습니다", comment: "Dashboard Apple Home status headline")
        }
    }

    private var detail: String {
        switch summary {
        case .unavailable:
            return String(localized: "Apple 홈 기기 상태를 알 수 없으며, 조각보 센서 상태에는 포함되지 않습니다.", comment: "Dashboard Apple Home status detail: Apple Home can't be read")
        case .noHome, .noDevices:
            return String(localized: "표시할 Apple 홈 기기가 없습니다.", comment: "Dashboard Apple Home status detail")
        case let .allResponding(total):
            return String(localized: "응답함 \(total)/\(total)", comment: "Dashboard Apple Home status: responding devices / listed devices")
        case let .someNotResponding(notResponding, total):
            return String(localized: "응답 없음 \(notResponding) · 전체 \(total)", comment: "Dashboard Apple Home status: devices not responding · listed devices")
        }
    }

    /// Only for a readable Apple Home, and only when something is pending or failed.
    private var valueCheckText: String? {
        guard let valueCheck else { return nil }
        switch summary {
        case .allResponding, .someNotResponding: break
        case .unavailable, .noHome, .noDevices: return nil
        }
        var parts: [String] = []
        // Worded like the sections of the list the card opens (`AppleHomeIssueText`).
        if valueCheck.failed > 0 {
            parts.append(AppleHomeIssueText.title(.readFailed, count: valueCheck.failed))
        }
        if valueCheck.retrying > 0 {
            parts.append(AppleHomeIssueText.title(.retrying, count: valueCheck.retrying))
        }
        if valueCheck.checking > 0 {
            parts.append(AppleHomeIssueText.title(.checking, count: valueCheck.checking))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var symbol: String {
        switch summary {
        case .allResponding: return "checkmark.circle.fill"
        case .someNotResponding: return "exclamationmark.triangle.fill"
        case .unavailable(.denied), .unavailable(.restricted): return "hand.raised.fill"
        case .unavailable, .noHome, .noDevices: return "homekit"
        }
    }

    private var tint: Color {
        switch summary {
        case .allResponding: return .green
        case .someNotResponding: return .orange
        case .unavailable, .noHome, .noDevices: return .gray
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconCircle(systemName: symbol, diameter: 36, background: tint, relativeTo: .headline)
            VStack(alignment: .leading, spacing: 3) {
                DashboardSourceCaption(text: String(localized: "Apple 홈", comment: "Dashboard status source: Apple Home"), symbol: "homekit")
                Text(headline)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let valueCheckText {
                    Text(valueCheckText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if showsDisclosure {
                DisclosureChevron()
            }
        }
        .padding(PogoTheme.cardPadding)
        // Fills the height it's given: equal-height side-by-side cards on a wide Dashboard.
        // (In the phone layout the scroll view proposes no height, so this changes nothing.)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(PogoTheme.tile, in: RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The "opens a list" hint on a Dashboard card or tile that is a link.
struct DisclosureChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// Names which source a Dashboard status card speaks for.
struct DashboardSourceCaption: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// "Apple 홈 기기" on the Dashboard: every visible accessory as a tile, grouped by home and room.
/// Each room is one horizontally scrolling row, so many devices don't push the POGO sections far
/// down; at accessibility text sizes the rows become a one-column list instead.
struct AppleHomeDashboardSection: View {
    @Environment(AppleHomeModel.self) private var appleHome
    @Environment(AppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Tile width in the horizontal rows; grows with the text size, capped.
    @ScaledMetric(relativeTo: .headline) private var tileWidth: CGFloat = 168

    var body: some View {
        let state = appleHome.snapshot.accessState
        let layout = appleHome.layout(pogo: appModel.snapshot)
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(
                title: "Apple 홈 기기",
                subtitle: state == .ready
                    ? String(localized: "devices.count", defaultValue: "\(layout.visibleAccessories.count)개", comment: "Number of devices (plural)")
                    : AppleHomeText.accessStateSummary(state)
            )
            if state != .ready {
                // Never the last-read devices: without current access nothing is shown as state.
                AppleHomeAccessNotice(state: state)
            } else if layout.homes.isEmpty {
                Text("Apple 홈에 등록된 기기가 없습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(layout.homes) { home in
                    VStack(alignment: .leading, spacing: 10) {
                        AppleHomeHomeHeader(group: home)
                        ForEach(home.rooms) { room in
                            VStack(alignment: .leading, spacing: 8) {
                                AppleHomeRoomGroupHeader(room: room)
                                row(room)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ room: AppleHomeRoomGroup) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            LazyVStack(spacing: PogoTheme.gridSpacing) {
                ForEach(room.accessories) { accessory in
                    AppleHomeAccessoryTile(accessory: accessory, showsRoom: false)
                }
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: PogoTheme.gridSpacing) {
                    ForEach(room.accessories) { accessory in
                        AppleHomeAccessoryTile(accessory: accessory, showsRoom: false)
                            .frame(width: min(tileWidth, 240))
                    }
                }
                // Sizes the row to its tallest tile, which the tiles then all stretch to.
                .fixedSize(horizontal: false, vertical: true)
            }
            .contentMargins(.horizontal, 0, for: .scrollContent)
        }
    }
}
