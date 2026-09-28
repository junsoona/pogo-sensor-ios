import SwiftUI

struct RoomDetailView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let roomID: UUID
    @State private var isEditingRoom = false

    private var room: Room? { appModel.room(with: roomID) }
    private var modules: [SensorModule] {
        guard let room else { return [] }
        return appModel.snapshot.modules(in: room)
    }

    var body: some View {
        Group {
            if let room, modules.isEmpty {
                CenteredEmptyState {
                    ContentUnavailableView(
                        "등록된 기기가 없습니다",
                        systemImage: SymbolAvailability.resolvedName(for: room.symbolName),
                        description: Text("\(room.name)에 연결된 모듈이 아직 없습니다.", comment: "Empty room; the room name is user data")
                    )
                }
            } else if room != nil {
                ScrollView {
                    moduleList
                }
                .screenBackground()
            } else {
                // The room this destination was pushed for no longer exists (deleted, or a
                // stale navigation value) — show a clear fallback instead of a blank screen.
                CenteredEmptyState {
                    ContentUnavailableView(
                        "방을 찾을 수 없습니다",
                        systemImage: "questionmark.circle",
                        description: Text("이 방은 삭제되었거나 더 이상 존재하지 않습니다.")
                    )
                }
            }
        }
        .detailTitle(room?.name ?? String(localized: "room.detail.fallbackTitle", defaultValue: "방", comment: "Title of a room screen whose room no longer exists (singular)")) {
            if let room, room.id != ModuleCatalog.unspecifiedRoomID {
                Button("편집") { isEditingRoom = true }
            }
        }
        .sheet(isPresented: $isEditingRoom) {
            if let room {
                RoomEditorSheet(mode: .edit(room))
            }
        }
    }

    private var moduleList: some View {
        VStack(alignment: .leading, spacing: PogoTheme.sectionSpacing) {
            ForEach(modules) { module in
                VStack(alignment: .leading, spacing: 12) {
                    NavigationLink(value: AppRoute.module(module.id)) {
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
                        columns: PogoTheme.cardColumns(for: dynamicTypeSize),
                        spacing: PogoTheme.gridSpacing
                    ) {
                        ForEach(module.sortedReadings) { reading in
                            NavigationLink(value: AppRoute.module(module.id)) {
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

#Preview {
    NavigationStack {
        RoomDetailView(
            roomID: MockSensorFixtures.livingRoom.id
        )
        .environment(AppModel.preview)
        .navigationDestination(for: AppRoute.self) { route in
            switch route {
            case let .module(moduleID):
                ModuleDetailView(moduleID: moduleID)
            case let .room(roomID):
                RoomDetailView(roomID: roomID)
            }
        }
    }
}
