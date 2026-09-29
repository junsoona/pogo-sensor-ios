import SwiftUI

/// The Dashboard's Apple Home status, next to (never merged into) the POGO sensor status: says
/// whether Apple Home can be read at all, and if so how its listed devices are doing. The verdict
/// (headline, icon, color) weighs HomeKit's connection state and PogoHome's value reads together
/// (`AppleHomeCardVerdict`); green only when every listed device responds and no value read is
/// pending or failed.
///
/// "Responding" is HomeKit's reachability, shown as HomeKit reports it. A responding accessory
/// whose last value read failed is counted as a read failure — and still as responding.
struct AppleHomeStatusCard: View {
    let summary: AppleHomeStatusSummary
    var valueCheck: AppleHomeValueCheckSummary?
    /// The card opens the list of the devices it counts (`AppleHomeIssuesView`).
    var showsDisclosure = false

    private var verdict: AppleHomeCardVerdict {
        AppleHomeCardVerdict.evaluate(summary: summary, valueCheck: valueCheck)
    }

    private var headline: String {
        switch verdict {
        case let .unavailable(state):
            switch state {
            case .off: return String(localized: "Apple 홈 연결 꺼짐", comment: "Dashboard Apple Home status headline")
            case .loading: return String(localized: "Apple 홈 확인 중", comment: "Dashboard Apple Home status headline")
            case .denied, .restricted: return String(localized: "Apple 홈 접근 권한 없음", comment: "Dashboard Apple Home status headline")
            case .unsupported, .noHome, .ready: return String(localized: "Apple 홈을 사용할 수 없음", comment: "Apple Home notice title")
            }
        case .noHome: return String(localized: "Apple 홈에 집이 없음", comment: "Apple Home notice title")
        case .noDevices: return String(localized: "Apple 홈 기기 없음", comment: "Dashboard Apple Home status headline")
        case .needsAttention:
            return String(localized: "확인이 필요한 Apple 홈 기기가 있습니다", comment: "Dashboard Apple Home status headline: a device doesn't respond or its last value read failed")
        case .retrying:
            return String(localized: "Apple 홈 기기 값을 다시 읽는 중입니다", comment: "Dashboard Apple Home status headline: value reads are being retried automatically; nothing has failed for good")
        case .checking:
            return String(localized: "Apple 홈 기기 값을 확인하는 중입니다", comment: "Dashboard Apple Home status headline: first value reads are running")
        case .fine: return String(localized: "Apple 홈 기기가 모두 응답합니다", comment: "Dashboard Apple Home status headline")
        }
    }

    /// The detail line, as separate parts: each count the verdict rests on, then HomeKit's
    /// responding count.
    private var detailParts: [String] {
        switch verdict {
        case .unavailable:
            return [String(localized: "Apple 홈 기기 상태를 알 수 없으며, 조각보 센서 상태에는 포함되지 않습니다.", comment: "Dashboard Apple Home status detail: Apple Home can't be read")]
        case .noHome, .noDevices:
            return [String(localized: "표시할 Apple 홈 기기가 없습니다.", comment: "Dashboard Apple Home status detail")]
        case let .fine(total):
            return [String(localized: "응답함 \(total)/\(total)", comment: "Dashboard Apple Home status: responding devices / listed devices")]
        case let .needsAttention(counts), let .retrying(counts), let .checking(counts):
            return issueParts(counts) + [
                String(localized: "HomeKit 기준 응답함 \(counts.responding)/\(counts.total)", comment: "Dashboard Apple Home status: devices HomeKit reports as responding / listed devices (a device whose value read failed can still respond)")
            ]
        }
    }

    /// The same parts for VoiceOver: "42 of 42" rather than "42 slash 42".
    private var accessibilityDetailParts: [String] {
        switch verdict {
        case .unavailable, .noHome, .noDevices:
            return detailParts
        case let .fine(total):
            return [respondingForVoiceOver(total: total, responding: total)]
        case let .needsAttention(counts), let .retrying(counts), let .checking(counts):
            return issueParts(counts) + [respondingForVoiceOver(total: counts.total, responding: counts.responding)]
        }
    }

    private func respondingForVoiceOver(total: Int, responding: Int) -> String {
        String(localized: "HomeKit 기준 \(total)개 중 \(responding)개 응답함", comment: "VoiceOver, Dashboard Apple Home status: listed devices, of which HomeKit reports this many as responding")
    }

    /// One part per kind the card counts, in the order of the list it opens (`AppleHomeIssuesView`).
    private func issueParts(_ counts: AppleHomeCardVerdict.Counts) -> [String] {
        var parts: [String] = []
        if counts.notResponding > 0 {
            parts.append(String(localized: "응답 없음 \(counts.notResponding)개", comment: "Dashboard Apple Home status: number of devices HomeKit reports as not responding"))
        }
        if counts.readFailed > 0 {
            parts.append(String(localized: "값 읽기 실패 \(counts.readFailed)개", comment: "Dashboard Apple Home status: number of devices whose last value read failed with no retry left (they may still respond)"))
        }
        if counts.retrying > 0 {
            parts.append(String(localized: "다시 읽는 중 \(counts.retrying)개", comment: "Dashboard Apple Home status: number of devices whose value read is being retried automatically"))
        }
        if counts.checking > 0 {
            parts.append(String(localized: "값 확인 중 \(counts.checking)개", comment: "Dashboard Apple Home status: number of devices whose first value read is running"))
        }
        return parts
    }

    private var symbol: String {
        switch verdict {
        case .fine: return "checkmark.circle.fill"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .retrying: return "arrow.triangle.2.circlepath"
        case .checking: return "hourglass"
        case .unavailable(.denied), .unavailable(.restricted): return "hand.raised.fill"
        case .unavailable, .noHome, .noDevices: return "homekit"
        }
    }

    /// Like the POGO card (`HomeStatusCard`): green only for `.fine`, orange for what needs
    /// attention, gray while something is still being read or can't be known.
    private var tint: Color {
        switch verdict {
        case .fine: return .green
        case .needsAttention: return .orange
        case .retrying, .checking, .unavailable, .noHome, .noDevices: return .gray
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconCircle(systemName: symbol, diameter: 36, background: tint, relativeTo: .headline)
            VStack(alignment: .leading, spacing: 3) {
                DashboardSourceCaption(text: String(localized: "Apple 홈", comment: "Dashboard status source: Apple Home"), symbol: "homekit")
                Text(headline)
                    .font(.subheadline.weight(.semibold))
                Text(verbatim: detailParts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(verbatim: accessibilityDetailParts.joined(separator: ", ")))
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
