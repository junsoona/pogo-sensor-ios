import SwiftUI

/// The lists behind the Dashboard's 조각보 sensor tiles and its Apple Home card, pushed on the
/// Dashboard's own stack. A separate route type from `AppRoute`/`AppleHomeRoute` (which carry a
/// room or device id); every row opens the device's existing screen through those.
enum DashboardRoute: Hashable {
    /// "온라인" tile: the online 조각보 sensor modules.
    case onlineModules
    /// "확인 필요" tile: modules needing attention, with the reasons.
    case attention
    /// "센서" tile: every reading the tile counts, per module.
    case readings
    /// The Apple Home card: accessories not responding or with a pending/failed value read.
    case appleHomeIssues
}

extension View {
    func dashboardNavigationDestinations() -> some View {
        navigationDestination(for: DashboardRoute.self) { route in
            switch route {
            case .onlineModules:
                DashboardOnlineModulesView()
            case .attention:
                DashboardAttentionView()
            case .readings:
                DashboardReadingsView()
            case .appleHomeIssues:
                AppleHomeIssuesView()
            }
        }
    }
}

// MARK: - 조각보 sensors

/// "온라인": the modules the tile counts, each opening its detail screen.
struct DashboardOnlineModulesView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let snapshot = appModel.snapshot
        let health = appModel.health
        Group {
            if let modules = DashboardMetrics.onlineModules(snapshot, health: health) {
                if modules.isEmpty {
                    CenteredEmptyState {
                        ContentUnavailableView {
                            Label("온라인인 조각보 센서가 없습니다", systemImage: "sensor.fill")
                        } description: {
                            snapshot.modules.isEmpty
                                ? Text("연결된 조각보 센서가 없습니다. 모듈이 연결되면 여기에 표시됩니다.")
                                : Text("조각보 센서 \(snapshot.modules.count)개가 모두 오프라인입니다. Power Base와 허브의 연결을 확인하세요.", comment: "Dashboard online list, empty: every module is offline; the number of modules (plural)")
                        }
                    }
                } else {
                    List {
                        Section {
                            ForEach(modules) { module in
                                NavigationLink(value: AppRoute.module(module.id)) {
                                    DashboardModuleRow(module: module, snapshot: snapshot, isCurrentStateVerified: true)
                                }
                            }
                        } header: {
                            DashboardListSourceHeader()
                        } footer: {
                            Text("전체 \(snapshot.modules.count)개 중 \(modules.count)개가 온라인입니다.", comment: "Dashboard online list footer: all modules, online modules")
                        }
                    }
                    .listScreenBackground()
                }
            } else {
                DashboardUnverifiedView(health: health)
            }
        }
        .navigationTitle(Text("온라인 조각보 센서"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// "확인 필요": the modules the tile counts, with why each needs checking.
struct DashboardAttentionView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let snapshot = appModel.snapshot
        let health = appModel.health
        Group {
            if let items = DashboardMetrics.attentionItems(snapshot, health: health) {
                if items.isEmpty {
                    CenteredEmptyState {
                        ContentUnavailableView {
                            Label("확인이 필요한 항목이 없습니다", systemImage: "checkmark.circle")
                        } description: {
                            Text("모든 조각보 센서가 연결되어 있고 측정값도 정상적으로 들어오고 있습니다.")
                        }
                    }
                } else {
                    List {
                        Section {
                            ForEach(items) { item in
                                NavigationLink(value: item.detailRoute) {
                                    DashboardAttentionRow(item: item, room: snapshot.room(for: item.module))
                                }
                            }
                        } header: {
                            DashboardListSourceHeader()
                        } footer: {
                            Text("기기를 누르면 센서값과 연결 정보를 볼 수 있습니다.")
                        }
                    }
                    .listScreenBackground()
                }
            } else {
                DashboardUnverifiedView(health: health)
            }
        }
        .navigationTitle(Text(String(localized: "dashboard.attention.title", defaultValue: "확인 필요", comment: "Title of the list of 조각보 sensors needing attention")))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// "센서": every reading the tile counts, one section per module.
struct DashboardReadingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let snapshot = appModel.snapshot
        let health = appModel.health
        let groups = DashboardMetrics.readingGroups(snapshot)
        Group {
            if groups.isEmpty {
                CenteredEmptyState {
                    ContentUnavailableView {
                        Label("표시할 센서값이 없습니다", systemImage: "waveform.path.ecg")
                    } description: {
                        snapshot.modules.isEmpty
                            ? Text("연결된 조각보 센서가 없습니다. 모듈이 연결되면 여기에 표시됩니다.")
                            : Text("조각보 센서가 아직 측정값을 보내지 않았습니다. 값이 들어오면 여기에 표시됩니다.")
                    }
                }
            } else {
                List {
                    Section {
                        Text("조각보 센서 \(groups.count)개의 센서값 \(DashboardMetrics.readingCount(groups))개", comment: "Dashboard readings list: number of modules, number of readings (plural)")
                            .font(.subheadline)
                        if !health.isCurrentStateVerified {
                            Label {
                                Text("마지막으로 받은 센서값을 표시하고 있습니다")
                            } icon: {
                                Image(systemName: "clock.arrow.circlepath")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    } header: {
                        DashboardListSourceHeader()
                    }
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.readings) { reading in
                                NavigationLink(value: group.detailRoute) {
                                    DashboardReadingRow(reading: reading)
                                }
                            }
                        } header: {
                            DashboardReadingGroupHeader(
                                module: group.module,
                                room: snapshot.room(for: group.module),
                                isOffline: health.isCurrentStateVerified && !group.module.isOnline
                            )
                        }
                    }
                }
                .listScreenBackground()
            }
        }
        .navigationTitle(Text(String(localized: "dashboard.readings.title", defaultValue: "센서값", comment: "Title of the list of every 조각보 sensor reading (plural)")))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Names the source of a list, so 조각보 sensors are never mistaken for Apple Home devices.
private struct DashboardListSourceHeader: View {
    var body: some View {
        Label {
            Text("조각보 센서", comment: "Dashboard status source: 조각보 sensors")
        } icon: {
            Image(systemName: "sensor.fill")
        }
    }
}

/// While the connection isn't verified the tile shows no number ("확인 중" / "—"), and so the
/// list shows why instead of a guess.
private struct DashboardUnverifiedView: View {
    let health: HomeHealthState

    var body: some View {
        CenteredEmptyState {
            ContentUnavailableView {
                Label(title, systemImage: symbol)
            } description: {
                Text("연결이 확인되면 최신 상태로 다시 표시합니다.")
            }
        }
    }

    private var title: String {
        switch health {
        case .waitingForData: return String(localized: "센서 데이터를 기다리는 중입니다", comment: "Home status headline")
        case .reconnecting: return String(localized: "센서 허브 연결을 확인해 주세요", comment: "Home status headline")
        case .recoveringRegistry: return String(localized: "센서 정보를 다시 확인하고 있습니다", comment: "Home status headline")
        case .healthy, .attentionNeeded: return ""
        }
    }

    private var symbol: String {
        switch health {
        case .reconnecting: return "wifi.exclamationmark"
        case .recoveringRegistry: return "arrow.triangle.2.circlepath"
        case .waitingForData, .healthy, .attentionNeeded: return "hourglass"
        }
    }
}

/// A row of the lists here: an icon, then lines of text. At accessibility text sizes the icon
/// is left out so the text keeps the row's whole width instead of breaking every few letters.
private struct DashboardListRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let symbolName: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
                IconCircle(systemName: symbolName, diameter: 30, background: tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A reason line (offline, read failed, …) with its symbol; text only at accessibility sizes.
private struct DashboardReasonLine: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let text: String
    let symbolName: String
    let tint: Color

    var body: some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: symbolName)
        }
        .labelStyle(ReasonLabelStyle(showsIcon: !dynamicTypeSize.isAccessibilitySize))
        .font(.caption)
        .foregroundStyle(tint)
    }

    private struct ReasonLabelStyle: LabelStyle {
        let showsIcon: Bool

        func makeBody(configuration: Configuration) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if showsIcon { configuration.icon }
                configuration.title
            }
        }
    }
}

private struct DashboardModuleRow: View {
    let module: SensorModule
    let snapshot: HomeSnapshot
    let isCurrentStateVerified: Bool

    var body: some View {
        let room = snapshot.room(for: module)
        let roomName = room?.name ?? String(localized: "방 미지정", comment: "Device card: module has no room")
        let status = DeviceStatusText.pogo(
            module,
            isCurrentStateVerified: isCurrentStateVerified,
            isPowerBaseOffline: snapshot.isOfflineBecausePowerBaseIsOffline(module)
        )
        DashboardListRow(
            symbolName: SymbolAvailability.resolvedName(for: room?.symbolName ?? "sensor.fill"),
            tint: isCurrentStateVerified && module.isOnline ? .blue : .gray
        ) {
            Text(verbatim: module.name)
            Text(verbatim: "\(roomName) · \(status)")
                .font(.caption)
                .foregroundStyle(isCurrentStateVerified && !module.isOnline ? Color.red : Color.secondary)
        }
    }
}

private struct DashboardAttentionRow: View {
    let item: DashboardAttentionItem
    let room: Room?

    var body: some View {
        DashboardListRow(symbolName: "exclamationmark.triangle.fill", tint: .orange) {
            Text(verbatim: item.module.name)
            Text(verbatim: room?.name ?? String(localized: "방 미지정", comment: "Device card: module has no room"))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(item.reasons.enumerated()), id: \.offset) { _, reason in
                DashboardReasonLine(text: Self.text(for: reason), symbolName: Self.symbol(for: reason), tint: .red)
            }
        }
    }

    static func text(for reason: DashboardAttentionItem.Reason) -> String {
        switch reason {
        case let .offline(isPowerBaseOffline):
            return isPowerBaseOffline
                ? String(localized: "오프라인 (Power Base 연결 끊김)", comment: "Connection state value: offline because its Power Base is offline")
                : String(localized: "오프라인", comment: "Attention reason")
        case let .reading(kind, status):
            return "\(kind.displayName) · \(status.displayName)"
        }
    }

    static func symbol(for reason: DashboardAttentionItem.Reason) -> String {
        switch reason {
        case .offline: return "wifi.slash"
        case let .reading(_, status): return status.symbolName
        }
    }
}

private struct DashboardReadingGroupHeader: View {
    let module: SensorModule
    let room: Room?
    let isOffline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: module.name)
            Text(verbatim: [
                room?.name ?? String(localized: "방 미지정", comment: "Device card: module has no room"),
                isOffline ? String(localized: "오프라인", comment: "Device card status") : nil,
            ].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(isOffline ? Color.red : Color.secondary)
                .textCase(nil)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The value sits at the trailing edge; at accessibility sizes it moves under the sensor's name.
private struct DashboardReadingRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let reading: SensorReading

    var body: some View {
        DashboardListRow(symbolName: reading.kind.symbolName, tint: PogoTheme.color(for: reading.kind)) {
            if dynamicTypeSize.isAccessibilitySize {
                Text(verbatim: reading.kind.displayName)
                value
                status
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: reading.kind.displayName)
                        status
                    }
                    Spacer(minLength: 8)
                    value
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
    }

    private var value: some View {
        Text(verbatim: reading.formattedValue)
            .font(.body.weight(.semibold).monospacedDigit())
    }

    @ViewBuilder
    private var status: some View {
        if reading.status != .normal {
            Text(verbatim: reading.status.displayName)
                .font(.caption)
                .foregroundStyle(PogoTheme.color(for: reading.status))
        }
    }
}

// MARK: - Apple Home

/// The Dashboard Apple Home card's devices: every accessory the card counts, in one section per
/// line of the card (not responding, read failed, retrying, first read), each opening the
/// accessory's detail screen. Counted by `AppleHomeIssueList`, like the card.
struct AppleHomeIssuesView: View {
    @Environment(AppleHomeModel.self) private var appleHome
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let state = appleHome.snapshot.accessState
        Group {
            if state != .ready {
                CenteredEmptyState {
                    AppleHomeAccessNotice(state: state)
                }
            } else {
                let issues = AppleHomeIssueList.evaluate(appleHome.layout(pogo: appModel.snapshot).visibleAccessories)
                if issues.isEmpty {
                    CenteredEmptyState {
                        ContentUnavailableView {
                            Label("확인이 필요한 Apple 홈 기기가 없습니다", systemImage: "checkmark.circle")
                        } description: {
                            Text("모든 Apple 홈 기기가 응답하고 있으며, 값 읽기도 끝났습니다.")
                        }
                    }
                } else {
                    List {
                        ForEach(AppleHomeIssueReason.Category.allCases, id: \.self) { category in
                            let members = issues.issues(in: category)
                            if !members.isEmpty {
                                Section {
                                    ForEach(members) { issue in
                                        NavigationLink(value: issue.detailRoute) {
                                            AppleHomeIssueRow(issue: issue, homeName: appleHome.snapshot.home(with: issue.accessory.homeID)?.name)
                                        }
                                    }
                                } header: {
                                    Text(verbatim: AppleHomeIssueText.title(category, count: members.count))
                                } footer: {
                                    Text(verbatim: AppleHomeIssueText.explanation(category))
                                }
                            }
                        }
                    }
                    .listScreenBackground()
                }
            }
        }
        .navigationTitle(Text("확인이 필요한 Apple 홈 기기"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The card's lines and the list's sections share this wording, so each count on the card
/// names the section that lists those devices.
enum AppleHomeIssueText {
    static func title(_ category: AppleHomeIssueReason.Category, count: Int) -> String {
        switch category {
        case .notResponding:
            return String(localized: "응답 없음 \(count)", comment: "Apple Home: number of devices not responding (connection)")
        case .readFailed:
            return String(localized: "값 읽기 실패 \(count)", comment: "Dashboard Apple Home status: devices whose last value read failed (they may still respond)")
        case .retrying:
            return String(localized: "다시 읽는 중 \(count)", comment: "Dashboard Apple Home status: devices whose value read is being retried automatically")
        case .checking:
            return String(localized: "값 확인 중 \(count)", comment: "Dashboard Apple Home status: devices whose values are still being read")
        }
    }

    static func explanation(_ category: AppleHomeIssueReason.Category) -> String {
        switch category {
        case .notResponding:
            return String(localized: "Apple 홈이 이 기기에 연결하지 못하고 있습니다. 기기의 전원과 네트워크를 확인하세요. 연결되지 않은 동안에는 값을 읽지 않습니다.", comment: "Apple Home issues list: not responding section footer")
        case .readFailed:
            return String(localized: "기기는 응답하지만 마지막 값 읽기에 실패했습니다. 기기를 열면 다시 읽습니다.", comment: "Apple Home issues list: read failed section footer")
        case .retrying:
            return String(localized: "값을 제시간에 읽지 못해 자동으로 다시 읽고 있습니다.", comment: "Apple Home issues list: retrying section footer")
        case .checking:
            return String(localized: "처음으로 값을 읽고 있습니다. 끝나면 자동으로 표시됩니다.", comment: "Apple Home issues list: first read section footer")
        }
    }

    static func reason(_ reason: AppleHomeIssueReason) -> String {
        switch reason {
        case let .notResponding(isBlocked):
            return isBlocked
                ? String(localized: "Apple 홈에서 차단됨", comment: "Apple Home accessory state: blocked by HomeKit")
                : String(localized: "응답 없음", comment: "Apple Home accessory state: not reachable")
        case let .readFailed(message):
            return String(localized: "마지막 읽기 실패: \(message)", comment: "Apple Home: the latest read failed; the argument is the reason")
        case let .retrying(attempt, maxAttempts):
            return AppleHomeText.retrying(attempt: attempt, maxAttempts: maxAttempts)
        case .checking:
            return String(localized: "상태 확인 중…", comment: "Apple Home tile: reading the device's state")
        }
    }
}

private struct AppleHomeIssueRow: View {
    let issue: AppleHomeIssue
    let homeName: String?

    private var place: String {
        [homeName, AppleHomeTileText.roomName(of: issue.accessory)].compactMap { $0 }.joined(separator: " · ")
    }

    private var tint: Color {
        switch issue.reason.category {
        case .notResponding, .readFailed: return .red
        case .retrying: return .orange
        case .checking: return .secondary
        }
    }

    /// When the values on screen date from: worth saying only while no read is under way.
    private var showsLastChecked: Bool {
        switch issue.reason.category {
        case .notResponding, .readFailed: return true
        case .retrying, .checking: return false
        }
    }

    private var symbol: String {
        switch issue.reason.category {
        case .notResponding: return "wifi.slash"
        case .readFailed: return "exclamationmark.triangle.fill"
        case .retrying: return "arrow.clockwise"
        case .checking: return "ellipsis.circle"
        }
    }

    var body: some View {
        DashboardListRow(
            symbolName: AppleHomeText.symbolName(for: issue.accessory),
            tint: issue.accessory.isOperable ? .orange : .gray
        ) {
            Text(verbatim: issue.accessory.name)
            Text(verbatim: place)
                .font(.caption)
                .foregroundStyle(.secondary)
            DashboardReasonLine(text: AppleHomeIssueText.reason(issue.reason), symbolName: symbol, tint: tint)
            if showsLastChecked {
                Text(verbatim: AppleHomeText.lastChecked(issue.accessory.lastCheckedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, PlatformSupport.isMacCatalyst ? 8 : 0)
    }
}

// MARK: - Detail routes

// The existing detail screens, by the row's own id and source.
extension DashboardAttentionItem {
    var detailRoute: AppRoute { .module(module.id) }
}

extension DashboardReadingGroup {
    var detailRoute: AppRoute { .module(module.id) }
}

extension AppleHomeIssue {
    var detailRoute: AppleHomeRoute { .accessory(accessory.id) }
}
