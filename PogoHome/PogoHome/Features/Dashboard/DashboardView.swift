import SwiftUI

private enum DashboardRoute: Hashable {
    case module(UUID)
    case room(UUID)
}

struct DashboardView: View {
    @Environment(AppModel.self) private var appModel

    private var snapshot: HomeSnapshot { appModel.snapshot }
    private var health: HomeHealthState { appModel.health }

    /// The "온라인" metric must never claim a confident count while the live connection
    /// itself is unconfirmed or still catching up — an offline-looking dashboard showing a
    /// stale "2" is more misleading than showing that the count simply isn't known right now.
    private var onlineCountDisplayValue: String {
        switch health {
        case .healthy, .attentionNeeded:
            return "\(snapshot.modules.filter(\.isOnline).count)"
        case .reconnecting, .recoveringRegistry:
            return "확인 중"
        case .waitingForData:
            return "—"
        }
    }

    private var attentionCountDisplayValue: String {
        health.isCurrentStateVerified ? "\(snapshot.modulesNeedingAttention.count)" : "—"
    }

    private var readingsWithContext: [(module: SensorModule, reading: SensorReading)] {
        snapshot.modules
            .sorted { $0.name < $1.name }
            .flatMap { module in module.sortedReadings.map { (module, $0) } }
            .sorted { $0.reading.kind.sortOrder < $1.reading.kind.sortOrder }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PogoTheme.sectionSpacing) {
                    dashboardSection

                    if !snapshot.modulesNeedingAttention.isEmpty {
                        attentionSection
                    }

                    sensorSection
                    roomSection
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .navigationTitle("우리 집")
            .background(PogoTheme.canvas)
            .navigationDestination(for: DashboardRoute.self) { route in
                switch route {
                case let .module(moduleID):
                    if let module = appModel.module(with: moduleID) {
                        ModuleDetailView(module: module, room: appModel.room(with: module.roomID))
                    }
                case let .room(roomID):
                    if let room = appModel.room(with: roomID) {
                        RoomDetailView(room: room, modules: snapshot.modules(in: room))
                    }
                }
            }
        }
    }

    private var dashboardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "대시보드", subtitle: Date().formatted(date: .abbreviated, time: .shortened))
            HomeStatusCard(snapshot: snapshot, health: health)

            HStack(spacing: PogoTheme.gridSpacing) {
                DashboardMetric(
                    title: "온라인",
                    value: onlineCountDisplayValue,
                    symbol: "sensor.fill",
                    tint: .blue
                )
                DashboardMetric(
                    title: "확인 필요",
                    value: attentionCountDisplayValue,
                    symbol: "exclamationmark.triangle.fill",
                    tint: health.isCurrentStateVerified && snapshot.modulesNeedingAttention.isEmpty ? .green : .orange
                )
                DashboardMetric(
                    title: "센서",
                    value: "\(snapshot.allReadings.count)",
                    symbol: "waveform.path.ecg",
                    tint: .teal
                )
            }
        }
    }

    private var attentionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "주의 필요", subtitle: "연결과 업데이트 상태")
            VStack(spacing: 10) {
                ForEach(snapshot.modulesNeedingAttention) { module in
                    NavigationLink(value: DashboardRoute.module(module.id)) {
                        AttentionRow(module: module, room: snapshot.room(for: module))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var sensorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "센서", subtitle: "모든 측정값")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160), spacing: PogoTheme.gridSpacing)],
                spacing: PogoTheme.gridSpacing
            ) {
                ForEach(readingsWithContext, id: \.reading.id) { entry in
                    NavigationLink(value: DashboardRoute.module(entry.module.id)) {
                        SensorCard(reading: entry.reading, contextLabel: entry.module.name)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var roomSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "방", subtitle: "공간별 보기")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PogoTheme.gridSpacing) {
                    ForEach(snapshot.sortedRooms) { room in
                        NavigationLink(value: DashboardRoute.room(room.id)) {
                            RoomSummaryCard(
                                room: room,
                                modules: snapshot.modules(in: room),
                                isCurrentStateVerified: health.isCurrentStateVerified
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .contentMargins(.horizontal, 0, for: .scrollContent)
        }
    }
}

struct HomeSectionHeader: View {
    let title: String
    let subtitle: String?

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer()
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct DashboardMetric: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(tint, in: Circle())
            Text(value)
                .font(.title2.weight(.bold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PogoTheme.tile, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct AttentionRow: View {
    let module: SensorModule
    let room: Room?

    private var reasonText: String {
        if !module.isOnline { return "오프라인" }
        if module.readings.contains(where: { $0.status == .stale }) { return "업데이트 지연" }
        if module.readings.contains(where: { $0.status == .error }) { return "센서 오류" }
        return "확인 필요"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.orange, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(module.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text([room?.name, reasonText].compactMap { $0 }.joined(separator: " · "))
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

    private var onlineCount: Int { modules.filter(\.isOnline).count }
    private var representativeReading: SensorReading? { modules.first?.sortedReadings.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: room.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.blue, in: Circle())

            Spacer(minLength: 10)

            Text(room.name)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(
                modules.isEmpty
                    ? "등록된 기기 없음"
                    : isCurrentStateVerified ? "온라인 \(onlineCount)/\(modules.count)" : "연결 상태 확인 중"
            )
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
        .frame(width: 166, height: 150, alignment: .topLeading)
        .background(PogoTheme.tile, in: RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    DashboardView()
        .environment(AppModel.preview)
}
