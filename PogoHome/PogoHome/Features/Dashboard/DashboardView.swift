import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppleHomeModel.self) private var appleHome
    @Environment(AppNavigator.self) private var navigator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// The scroll view's width, for the side-by-side status cards on wide iPad and Mac windows.
    @State private var contentWidth: CGFloat = 0

    /// iPad/Mac (and a large iPhone in landscape): the POGO and Apple Home status cards side by
    /// side instead of one full-width card per row. Never at accessibility text sizes, where each
    /// card needs the whole width.
    private var showsStatusSideBySide: Bool {
        horizontalSizeClass == .regular
            && !dynamicTypeSize.isAccessibilitySize
            && contentWidth >= PogoTheme.wideDashboardMinimumWidth
    }

    private var snapshot: HomeSnapshot { appModel.snapshot }
    private var health: HomeHealthState { appModel.health }

    /// The "온라인" metric must never claim a confident count while the live connection
    /// itself is unconfirmed or still catching up — an offline-looking dashboard showing a
    /// stale "2" is more misleading than showing that the count simply isn't known right now.
    /// The number is the length of the list the tile opens (`DashboardMetrics`).
    private var onlineCountDisplayValue: String {
        if let online = DashboardMetrics.onlineModules(snapshot, health: health) {
            return online.count.formatted()
        }
        switch health {
        case .reconnecting, .recoveringRegistry:
            return String(localized: "확인 중", comment: "Dashboard metric value while the online count is not yet known")
        case .waitingForData, .healthy, .attentionNeeded:
            return "—"
        }
    }

    private var attentionItems: [DashboardAttentionItem]? {
        DashboardMetrics.attentionItems(snapshot, health: health)
    }

    private var attentionCountDisplayValue: String {
        attentionItems.map { $0.count.formatted() } ?? "—"
    }

    private var readingCountDisplayValue: String {
        DashboardMetrics.readingCount(DashboardMetrics.readingGroups(snapshot)).formatted()
    }

    private var readingsWithContext: [(module: SensorModule, reading: SensorReading)] {
        snapshot.modules
            .sorted { $0.name < $1.name }
            .flatMap { module in module.sortedReadings.map { (module, $0) } }
            .sorted { $0.reading.kind.sortOrder < $1.reading.kind.sortOrder }
    }

    var body: some View {
        @Bindable var navigator = navigator
        // A path the navigator can set, so a widget tap opens a device's screen here.
        NavigationStack(path: $navigator.dashboardPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PogoTheme.sectionSpacing) {
                    dashboardSection

                    if !snapshot.modulesNeedingAttention.isEmpty {
                        attentionSection
                    }

                    // From HomeKit, independent of the POGO data above and below; any Apple
                    // Home state (off, denied, loading) leaves the POGO sections untouched.
                    AppleHomeDashboardSection()

                    sensorSection
                    if !snapshot.visibleRooms.isEmpty {
                        roomSection
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            // The user's PogoHome-only home name (Settings → 집 이름), or the localized default.
            .tabRootTitle(Text(verbatim: appModel.homeName))
            .screenBackground()
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case let .module(moduleID):
                    ModuleDetailView(moduleID: moduleID)
                case let .room(roomID):
                    RoomDetailView(roomID: roomID)
                }
            }
            .appleHomeNavigationDestinations()
            .dashboardNavigationDestinations()
        }
    }

    private var dashboardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "대시보드", subtitle: Date().formatted(date: .abbreviated, time: .shortened))
            // Two separate verdicts: `health` is POGO sensors only; Apple Home devices are
            // summarized on their own and never make the POGO status look "all fine".
            if showsStatusSideBySide {
                HStack(alignment: .top, spacing: PogoTheme.gridSpacing) {
                    HomeStatusCard(snapshot: snapshot, health: health, dataWait: appModel.dataWait)
                    appleHomeStatusCard
                }
                // Equal-height cards, sized to the taller one.
                .fixedSize(horizontal: false, vertical: true)
            } else {
                HomeStatusCard(snapshot: snapshot, health: health, dataWait: appModel.dataWait)
            }

            // Three ~100pt-wide tiles can't hold accessibility-size text on a 375pt-wide
            // iPhone, so they stack into full-width rows there instead of truncating.
            let metricsLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: PogoTheme.gridSpacing))
                : AnyLayout(HStackLayout(alignment: .top, spacing: PogoTheme.gridSpacing))
            // Each tile opens the list it counts; the whole tile, icon included, is the link.
            metricsLayout {
                NavigationLink(value: DashboardRoute.onlineModules) {
                    DashboardMetric(
                        title: "조각보 온라인",
                        value: onlineCountDisplayValue,
                        symbol: "sensor.fill",
                        tint: .blue
                    )
                }
                .buttonStyle(.plain)
                NavigationLink(value: DashboardRoute.attention) {
                    DashboardMetric(
                        title: "확인 필요",
                        value: attentionCountDisplayValue,
                        symbol: "exclamationmark.triangle.fill",
                        tint: attentionItems?.isEmpty == true ? .green : .orange
                    )
                }
                .buttonStyle(.plain)
                NavigationLink(value: DashboardRoute.readings) {
                    DashboardMetric(
                        title: "센서",
                        value: readingCountDisplayValue,
                        symbol: "waveform.path.ecg",
                        tint: .teal
                    )
                }
                .buttonStyle(.plain)
            }
            // Equal-height tiles even when one title wraps to a second line.
            .fixedSize(horizontal: false, vertical: true)

            if !showsStatusSideBySide {
                appleHomeStatusCard
            }
        }
    }

    /// Opens the devices it counts (`AppleHomeIssuesView`) whenever it shows any: not responding,
    /// or a value read pending or failed. Both count `AppleHomeIssueList`.
    @ViewBuilder
    private var appleHomeStatusCard: some View {
        let state = appleHome.snapshot.accessState
        let layout = appleHome.layout(pogo: snapshot)
        let issues = AppleHomeIssueList.evaluate(layout.visibleAccessories)
        let opensIssues = state == .ready && !issues.isEmpty
        let card = AppleHomeStatusCard(
            summary: AppleHomeStatusSummary.evaluate(state: state, layout: layout),
            valueCheck: AppleHomeValueCheckSummary.evaluate(issues),
            showsDisclosure: opensIssues
        )
        if opensIssues {
            NavigationLink(value: DashboardRoute.appleHomeIssues) { card }
                .buttonStyle(.plain)
        } else {
            card
        }
    }

    private var attentionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "주의 필요", subtitle: String(localized: "연결과 업데이트 상태", comment: "Dashboard section subtitle"))
            VStack(spacing: 10) {
                ForEach(snapshot.modulesNeedingAttention) { module in
                    NavigationLink(value: AppRoute.module(module.id)) {
                        AttentionRow(module: module, room: snapshot.room(for: module))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var sensorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "센서", subtitle: String(localized: "모든 측정값", comment: "Dashboard section subtitle"))
            LazyVGrid(
                columns: PogoTheme.cardColumns(for: dynamicTypeSize),
                spacing: PogoTheme.gridSpacing
            ) {
                ForEach(readingsWithContext, id: \.reading.id) { entry in
                    NavigationLink(value: AppRoute.module(entry.module.id)) {
                        SensorCard(reading: entry.reading, contextLabel: entry.module.name)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var roomSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "방", subtitle: String(localized: "공간별 보기", comment: "Dashboard section subtitle"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: PogoTheme.gridSpacing) {
                    ForEach(snapshot.visibleRooms) { room in
                        NavigationLink(value: AppRoute.room(room.id)) {
                            RoomSummaryCard(
                                room: room,
                                modules: snapshot.modules(in: room),
                                isCurrentStateVerified: health.isCurrentStateVerified
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                // Sizes the row to its tallest card, which the cards then all stretch to.
                .fixedSize(horizontal: false, vertical: true)
            }
            .contentMargins(.horizontal, 0, for: .scrollContent)
        }
    }
}

struct HomeSectionHeader: View {
    let title: LocalizedStringKey
    /// Already-localized or data text (a date, a count), shown verbatim.
    let subtitle: String?

    init(title: LocalizedStringKey, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        // Wraps the subtitle under the title when both don't fit on one line (large text,
        // longer translations) instead of squeezing either.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                titleText
                Spacer()
                subtitleText
            }
            VStack(alignment: .leading, spacing: 2) {
                titleText
                subtitleText
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var titleText: some View {
        Text(title)
            .font(.title3.weight(.semibold))
    }

    @ViewBuilder
    private var subtitleText: some View {
        if let subtitle {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DashboardMetric: View {
    let title: LocalizedStringKey
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                IconCircle(systemName: symbol, diameter: 26, background: tint, weight: .bold, relativeTo: .caption)
                Spacer(minLength: 4)
                DisclosureChevron()
            }
            Text(value)
                .font(.title2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PogoTheme.tile, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct AttentionRow: View {
    let module: SensorModule
    let room: Room?

    private var reasonText: String {
        if !module.isOnline { return String(localized: "오프라인", comment: "Attention reason") }
        if module.readings.contains(where: { $0.status == .stale }) { return String(localized: "업데이트 지연", comment: "Attention reason") }
        if module.readings.contains(where: { $0.status == .error }) { return String(localized: "센서 오류", comment: "Attention reason") }
        return String(localized: "확인 필요", comment: "Attention reason")
    }

    private var detailText: String {
        guard let room else { return reasonText }
        return String(localized: "\(room.name) · \(reasonText)", comment: "Room name · attention reason")
    }

    var body: some View {
        HStack(spacing: 12) {
            IconCircle(systemName: "exclamationmark.triangle.fill", diameter: 36, background: Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(PogoTheme.cardPadding)
        .background(PogoTheme.tile, in: RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct RoomSummaryCard: View {
    let room: Room
    let modules: [SensorModule]
    let isCurrentStateVerified: Bool
    /// Grows with Dynamic Type (capped) so longer text wraps inside a wider card; the height
    /// is never fixed — the row stretches every card to the tallest one's content.
    @ScaledMetric(relativeTo: .headline) private var scaledWidth: CGFloat = 166

    private var onlineCount: Int { modules.filter(\.isOnline).count }
    private var representativeReading: SensorReading? { modules.first?.sortedReadings.first }

    private var statusText: String {
        if modules.isEmpty { return String(localized: "등록된 기기 없음", comment: "Room card: no devices") }
        guard isCurrentStateVerified else { return String(localized: "연결 상태 확인 중", comment: "Room card: connection not verified") }
        return String(localized: "온라인 \(onlineCount)/\(modules.count)", comment: "Room card: online modules / total modules")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            IconCircle(systemName: SymbolAvailability.resolvedName(for: room.symbolName), diameter: 36)

            Spacer(minLength: 10)

            Text(room.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(3)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let representativeReading {
                Text(representativeReading.formattedValue)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .padding(PogoTheme.cardPadding)
        .frame(width: min(scaledWidth, 260), alignment: .topLeading)
        .frame(minHeight: 150, maxHeight: .infinity, alignment: .topLeading)
        .background(PogoTheme.tile, in: RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    DashboardView()
        .environment(AppModel.preview)
        .environment(AppleHomeModel.preview)
        .environment(AppNavigator())
}
