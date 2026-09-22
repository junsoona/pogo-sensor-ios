import SwiftUI

struct ModuleDetailView: View {
    @Environment(AppModel.self) private var appModel
    let module: SensorModule
    let room: Room?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PogoTheme.sectionSpacing) {
                header

                VStack(alignment: .leading, spacing: 12) {
                    HomeSectionHeader(title: "센서", subtitle: "\(module.readings.count)개")
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 160), spacing: PogoTheme.gridSpacing)],
                        spacing: PogoTheme.gridSpacing
                    ) {
                        ForEach(module.sortedReadings) { reading in
                            SensorCard(reading: reading, contextLabel: room?.name ?? module.name)
                        }
                    }
                }

                diagnosticsSection
            }
            .padding()
        }
        .navigationTitle(module.name)
        .navigationBarTitleDisplayMode(.inline)
        .background(PogoTheme.canvas)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: room?.symbolName ?? "square.grid.2x2")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(.blue, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(module.name)
                    .font(.title2.weight(.bold))
                if let room {
                    Text(room.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let role = module.roleDescription {
                    Text(role)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            StatusBadge(
                status: appModel.health.isCurrentStateVerified
                    ? module.isOnline ? .normal : .unavailable
                    : .stale
            )
        }
        .accessibilityElement(children: .combine)
    }

    /// Technical diagnostics kept visually separate from user-facing info: monospaced
    /// UUID, exact timestamps, and connectivity, in a distinctly styled block.
    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "기술 정보")

            VStack(alignment: .leading, spacing: 10) {
                diagnosticRow(label: "모듈 UUID", value: module.id.uuidString, monospaced: true)
                diagnosticRow(
                    label: "연결 상태",
                    value: appModel.health.isCurrentStateVerified
                        ? module.isOnline ? "온라인" : "오프라인"
                        : "확인 중"
                )
                diagnosticRow(label: "마지막 수신", value: module.lastSeen.formatted(date: .abbreviated, time: .standard))
            }
            .padding(PogoTheme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius, style: .continuous)
                    .fill(Color(.tertiarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color(.separator), lineWidth: 0.5)
            )
        }
    }

    private func diagnosticRow(label: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        ModuleDetailView(
            module: MockSensorFixtures.modules(referenceDate: MockSensorFixtures.previewReferenceDate)[0],
            room: MockSensorFixtures.livingRoom
        )
    }
}
