import SwiftUI

struct RoomDetailView: View {
    let room: Room
    let modules: [SensorModule]

    var body: some View {
        ScrollView {
            if modules.isEmpty {
                ContentUnavailableView(
                    "등록된 기기가 없습니다",
                    systemImage: room.symbolName,
                    description: Text("\(room.name)에 연결된 모듈이 아직 없습니다.")
                )
                .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: PogoTheme.sectionSpacing) {
                    ForEach(modules) { module in
                        VStack(alignment: .leading, spacing: 12) {
                            NavigationLink(value: module.id) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(module.name)
                                            .font(.title3.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        if let role = module.roleDescription {
                                            Text(role)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)

                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 160), spacing: PogoTheme.gridSpacing)],
                                spacing: PogoTheme.gridSpacing
                            ) {
                                ForEach(module.sortedReadings) { reading in
                                    NavigationLink(value: module.id) {
                                        SensorCard(reading: reading, contextLabel: module.name)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .navigationTitle(room.name)
        .background(PogoTheme.canvas)
        .navigationDestination(for: UUID.self) { moduleID in
            if let module = modules.first(where: { $0.id == moduleID }) {
                ModuleDetailView(module: module, room: room)
            }
        }
    }
}

#Preview {
    NavigationStack {
        RoomDetailView(
            room: MockSensorFixtures.livingRoom,
            modules: MockSensorFixtures.previewSnapshot.modules(in: MockSensorFixtures.livingRoom)
        )
    }
}
