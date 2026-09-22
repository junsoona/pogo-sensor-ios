import SwiftUI

struct RoomsView: View {
    @Environment(AppModel.self) private var appModel

    private var snapshot: HomeSnapshot { appModel.snapshot }

    var body: some View {
        NavigationStack {
            ScrollView {
                if snapshot.rooms.isEmpty {
                    ContentUnavailableView(
                        "등록된 방이 없습니다",
                        systemImage: "square.grid.2x2",
                        description: Text("모듈이 연결되면 방이 여기에 표시됩니다.")
                    )
                    .padding(.top, 60)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HomeSectionHeader(title: "방", subtitle: "\(snapshot.rooms.count)개")
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 170), spacing: PogoTheme.gridSpacing)],
                            spacing: PogoTheme.gridSpacing
                        ) {
                            ForEach(snapshot.sortedRooms) { room in
                                NavigationLink(value: room.id) {
                                    RoomCard(
                                        room: room,
                                        modules: snapshot.modules(in: room),
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
            .navigationTitle("방")
            .background(Color(.systemGroupedBackground))
            .navigationDestination(for: UUID.self) { roomID in
                if let room = appModel.room(with: roomID) {
                    RoomDetailView(room: room, modules: appModel.snapshot.modules(in: room))
                }
            }
        }
    }
}

private struct RoomCard: View {
    let room: Room
    let modules: [SensorModule]
    let isCurrentStateVerified: Bool

    private var onlineCount: Int { modules.filter(\.isOnline).count }
    private var representativeReading: SensorReading? {
        modules.first?.sortedReadings.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: room.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.blue, in: Circle())

            Text(room.name)
                .font(.headline)
                .foregroundStyle(.primary)

            if modules.isEmpty {
                Text("등록된 기기 없음")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(isCurrentStateVerified ? "온라인 \(onlineCount)/\(modules.count)" : "연결 상태 확인 중")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let reading = representativeReading {
                    Text(reading.formattedValue)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .padding(PogoTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 142, alignment: .topLeading)
        .background(PogoTheme.tile, in: RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    RoomsView()
        .environment(AppModel.preview)
}
