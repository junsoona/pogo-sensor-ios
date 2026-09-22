import SwiftUI

struct DevicesView: View {
    @Environment(AppModel.self) private var appModel

    private var snapshot: HomeSnapshot { appModel.snapshot }

    var body: some View {
        NavigationStack {
            ScrollView {
                if snapshot.modules.isEmpty {
                    ContentUnavailableView(
                        "등록된 기기가 없습니다",
                        systemImage: "sensor.fill",
                        description: Text("모듈이 연결되면 여기에 표시됩니다.")
                    )
                    .padding(.top, 60)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HomeSectionHeader(title: "기기", subtitle: "\(snapshot.modules.count)개")
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 160), spacing: PogoTheme.gridSpacing)],
                            spacing: PogoTheme.gridSpacing
                        ) {
                            ForEach(snapshot.modules) { module in
                                NavigationLink(value: module.id) {
                                    DeviceCard(
                                        module: module,
                                        room: snapshot.room(for: module),
                                        isCurrentStateVerified: appModel.health.isCurrentStateVerified
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("기기")
            .background(PogoTheme.canvas)
            .navigationDestination(for: UUID.self) { moduleID in
                if let module = appModel.module(with: moduleID) {
                    ModuleDetailView(module: module, room: appModel.room(with: module.roomID))
                }
            }
        }
    }
}

private struct DeviceCard: View {
    let module: SensorModule
    let room: Room?
    let isCurrentStateVerified: Bool

    private var tint: Color { isCurrentStateVerified && module.isOnline ? .blue : .gray }

    private var statusText: String {
        guard isCurrentStateVerified else { return "상태 확인 중 · 센서 \(module.readings.count)개" }
        return module.isOnline ? "온라인 · 센서 \(module.readings.count)개" : "오프라인"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: room?.symbolName ?? "sensor.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(tint, in: Circle())
                Spacer()
                Image(
                    systemName: isCurrentStateVerified
                        ? module.isOnline ? "checkmark.circle.fill" : "xmark.circle.fill"
                        : "questionmark.circle.fill"
                )
                    .foregroundStyle(isCurrentStateVerified && module.isOnline ? .green : .secondary)
                    .accessibilityHidden(true)
            }

            Spacer(minLength: 18)

            Text(module.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text(room?.name ?? "방 미지정")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(isCurrentStateVerified && !module.isOnline ? Color.red : Color.secondary)
                .lineLimit(1)
        }
        .padding(PogoTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 154, alignment: .topLeading)
        .background(PogoTheme.tile, in: RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(module.name)
        .accessibilityValue("\(room?.name ?? "방 미지정"), \(statusText)")
    }
}

#Preview {
    DevicesView()
        .environment(AppModel.preview)
}
