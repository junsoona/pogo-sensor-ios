import SwiftUI

struct ModuleDetailView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.detailPlacement) private var placement
    let moduleID: UUID
    @State private var isEditing = false

    private var module: SensorModule? { appModel.module(with: moduleID) }
    private var room: Room? {
        guard let module else { return nil }
        return appModel.room(with: module.roomID)
    }

    var body: some View {
        Group {
            if module != nil {
                ScrollView {
                    details
                }
                .screenBackground()
            } else {
                // Reached only if the module genuinely isn't in `appModel.snapshot` right now
                // (e.g. it was removed, or a navigation value outlived its module) — every
                // entry point that can push a module destination must land here instead of a
                // blank screen, never silently render nothing.
                CenteredEmptyState {
                    ContentUnavailableView(
                        "기기를 찾을 수 없습니다",
                        systemImage: "questionmark.circle",
                        description: Text("이 기기는 더 이상 등록되어 있지 않거나 아직 동기화되지 않았습니다.")
                    )
                }
            }
        }
        .detailTitle(module?.name ?? String(localized: "device.detail.fallbackTitle", defaultValue: "기기", comment: "Title of a device screen whose device no longer exists (singular)")) {
            if module != nil {
                Button("편집") { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            ModuleEditorSheet(moduleID: moduleID)
        }
    }

    private var details: some View {
        let module = module!
        return VStack(alignment: .leading, spacing: PogoTheme.sectionSpacing) {
            header

            VStack(alignment: .leading, spacing: 12) {
                HomeSectionHeader(
                    title: "센서",
                    subtitle: String(localized: "sensors.count", defaultValue: "\(module.readings.count)개", comment: "Number of sensors (plural)")
                )
                LazyVGrid(
                    columns: PogoTheme.cardColumns(for: dynamicTypeSize),
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

    private var header: some View {
        let module = module!
        // The status badge moves under the name at accessibility sizes instead of squeezing it.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            IconCircle(systemName: SymbolAvailability.resolvedName(for: room?.symbolName ?? "square.grid.2x2"), diameter: 48, relativeTo: .title3)

            VStack(alignment: .leading, spacing: 4) {
                // Beside the device list the pane's header already names it.
                if placement == .screen {
                    Text(module.name)
                        .font(.title2.weight(.bold))
                }
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
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }
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
        let module = module!
        return VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "기술 정보")

            VStack(alignment: .leading, spacing: 10) {
                diagnosticRow(label: "제품 이름", value: module.hardwareName)
                if let identifier = module.hardwareIdentifier {
                    diagnosticRow(label: "하드웨어 ID", value: identifier, monospaced: true)
                }
                diagnosticRow(label: "앱 내부 ID", value: module.id.uuidString, monospaced: true)
                diagnosticRow(
                    label: "연결 상태",
                    value: appModel.health.isCurrentStateVerified
                        ? module.isOnline
                            ? String(localized: "온라인", comment: "Connection state value")
                            : appModel.snapshot.isOfflineBecausePowerBaseIsOffline(module)
                                ? String(localized: "오프라인 (Power Base 연결 끊김)", comment: "Connection state value: offline because its Power Base is offline")
                                : String(localized: "오프라인", comment: "Connection state value")
                        : String(localized: "확인 중", comment: "Connection state value: being checked")
                )
                diagnosticRow(label: "마지막 수신", value: module.lastSeen.formatted(date: .abbreviated, time: .standard))
                if let base = appModel.snapshot.powerBase(for: module) {
                    diagnosticRow(
                        label: "Power Base",
                        value: "\(base.shortLabel) · \(PowerBaseConnectionText.summary(of: base))"
                    )
                    diagnosticRow(label: "Power Base ID", value: base.hardwareIdentifier, monospaced: true)
                } else if let identifier = module.powerBaseIdentifier {
                    diagnosticRow(label: "Power Base ID", value: identifier, monospaced: true)
                }
                if let position = PowerBaseConnectionText.chainPosition(of: module, in: appModel.snapshot) {
                    diagnosticRow(label: "모듈 연결 위치", value: position)
                }
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

    private func diagnosticRow(label: LocalizedStringKey, value: String, monospaced: Bool = false) -> some View {
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
            moduleID: MockSensorFixtures.modules(referenceDate: MockSensorFixtures.previewReferenceDate)[0].id
        )
        .environment(AppModel.preview)
    }
}
