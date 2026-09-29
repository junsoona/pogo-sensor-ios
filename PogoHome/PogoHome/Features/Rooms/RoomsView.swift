import SwiftUI

/// Room edits started from either layout of the Rooms tab (toolbar, context menus), presented
/// once by `RoomsView` so both layouts share the same sheets and confirmation.
@MainActor
@Observable
final class RoomActions {
    var isCreatingRoom = false
    var editingRoom: Room?
    var roomPendingDeletion: PendingRoomDeletion?
    var isManagingRooms = false
    /// A change started outside an editor (deleting from a menu) that could not be saved.
    var editError: String?
}

/// A room deletion waiting for confirmation, with the shared settings revision of the list it was
/// picked from (see `AppModel.configurationEditBase`). The confirmation stands only for that list:
/// once a newer revision arrives (say another device moved a sensor into the room) it is closed
/// with the conflict notice, and a delete confirmed while a check was still under way is refused
/// unsent — the user deletes again from the list as it is now.
struct PendingRoomDeletion: Identifiable, Equatable {
    let room: Room
    let base: ConfigurationEditBase
    var id: UUID { room.id }

    /// Whether a confirmation opened for this deletion still matches what is on screen.
    func isCurrent(in appModel: AppModel) -> Bool {
        base == appModel.configurationEditBase
    }
}

/// What the list-and-detail layout shows in its detail column.
enum RoomSelection: Hashable {
    case pogo(UUID)
    case appleHome(AppleHomeRoomKey)
}

struct RoomsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var actions = RoomActions()
    /// Kept here so it survives switching between the two layouts (iPad window resizing).
    @State private var selection: RoomSelection?

    var body: some View {
        @Bindable var actions = actions
        // One navigation stack for both layouts: resizing a window swaps only its root, so the
        // bar, a pushed screen and the other tabs' stacks are never rebuilt.
        NavigationStack {
            AdaptiveSplitLayout {
                RoomsGrid()
            } wide: {
                RoomsListDetail(selection: $selection)
            }
            .tabRootTitle(Text("방"))
            .toolbar {
                RoomsToolbar(actions: actions)
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case let .room(roomID):
                    RoomDetailView(roomID: roomID)
                case let .module(moduleID):
                    ModuleDetailView(moduleID: moduleID)
                }
            }
            .appleHomeNavigationDestinations()
        }
        .environment(actions)
        .sheet(isPresented: $actions.isCreatingRoom) {
            RoomEditorSheet(mode: .create)
        }
        .sheet(item: $actions.editingRoom) { room in
            RoomEditorSheet(mode: .edit(room))
        }
        .sheet(isPresented: $actions.isManagingRooms) {
            NavigationStack {
                RoomManagementView()
            }
        }
        .alert(
            "방을 삭제할까요?",
            isPresented: Binding(
                get: { actions.roomPendingDeletion != nil },
                set: { if !$0 { actions.roomPendingDeletion = nil } }
            ),
            presenting: actions.roomPendingDeletion
        ) { pending in
            Button("삭제", role: .destructive) {
                actions.roomPendingDeletion = nil
                let room = pending.room
                Task {
                    do {
                        try await appModel.deleteRoom(id: room.id, basedOn: pending.base)
                        if selection == .pogo(room.id) { selection = nil }
                    } catch {
                        actions.editError = error.localizedDescription
                    }
                }
            }
            Button("취소", role: .cancel) {
                actions.roomPendingDeletion = nil
            }
        } message: { pending in
            Text("‘\(pending.room.name)’에 있는 기기는 미지정 공간으로 이동합니다.", comment: "Delete-room confirmation; the room name is user data")
        }
        .onChange(of: appModel.configurationEditBase) { _, _ in
            guard let pending = actions.roomPendingDeletion, !pending.isCurrent(in: appModel) else { return }
            // Confirmed against an older list; never delete on it.
            actions.roomPendingDeletion = nil
            actions.editError = SharedSettingsEditError.conflict.localizedDescription
        }
        .alert(
            String(localized: "설정을 저장하지 못했습니다", comment: "Alert title when a room change could not be saved"),
            isPresented: Binding(get: { actions.editError != nil }, set: { if !$0 { actions.editError = nil } }),
            presenting: actions.editError
        ) { _ in
            Button("확인") { actions.editError = nil }
        } message: { message in
            Text(verbatim: message)
        }
    }
}

/// "방 추가" and the "더 보기" menu, in either layout.
private struct RoomsToolbar: ToolbarContent {
    let actions: RoomActions

    var body: some ToolbarContent {
        ToolbarAddButton("방 추가", placement: .topBarLeading) {
            actions.isCreatingRoom = true
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(String(localized: "rooms.manage", defaultValue: "방 편집", comment: "Opens the screen for renaming, reordering and deleting all rooms"), systemImage: "pencil") {
                    actions.isManagingRooms = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("더 보기")
        }
    }
}

/// Edit / delete for a POGO room (never for 미지정, which can't be edited or deleted).
private struct RoomContextMenu: View {
    @Environment(AppModel.self) private var appModel
    let room: Room
    let actions: RoomActions

    var body: some View {
        if room.id != ModuleCatalog.unspecifiedRoomID {
            Button("방 편집", systemImage: "pencil") {
                actions.editingRoom = room
            }
            Button("방 삭제", systemImage: "trash", role: .destructive) {
                actions.roomPendingDeletion = PendingRoomDeletion(room: room, base: appModel.configurationEditBase)
            }
        }
    }
}

/// iPhone and narrow windows: room cards in a grid, pushing a room's screen.
private struct RoomsGrid: View {
    @Environment(AppModel.self) private var appModel
    @Environment(RoomActions.self) private var actions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var snapshot: HomeSnapshot { appModel.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PogoTheme.sectionSpacing) {
                if snapshot.visibleRooms.isEmpty {
                    ContentUnavailableView(
                        "등록된 방이 없습니다",
                        systemImage: "square.grid.2x2",
                        description: Text("모듈이 연결되면 방이 여기에 표시됩니다.")
                    )
                    .padding(.top, 24)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HomeSectionHeader(
                            title: "내 방",
                            subtitle: String(localized: "rooms.count", defaultValue: "\(snapshot.visibleRooms.count)개", comment: "Number of rooms (plural)")
                        )
                        // Top-aligned, and each card fills its row's height (`RoomCard`): an
                        // empty room next to one with sensors and warnings keeps the same top
                        // edge and icon line instead of being centered in the taller row.
                        LazyVGrid(
                            columns: PogoTheme.cardColumns(for: dynamicTypeSize, alignment: .top),
                            spacing: PogoTheme.gridSpacing
                        ) {
                            ForEach(snapshot.visibleRooms) { room in
                                NavigationLink(value: AppRoute.room(room.id)) {
                                    RoomCard(
                                        room: room,
                                        modules: snapshot.modules(in: room),
                                        isCurrentStateVerified: appModel.health.isCurrentStateVerified
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    RoomContextMenu(room: room, actions: actions)
                                }
                            }
                        }
                    }
                }

                // Apple Home's own rooms, read from HomeKit — never merged with, copied into, or
                // matched by name against the POGO rooms above.
                AppleHomeRoomsSection()
            }
            .padding()
        }
        .screenBackground()
    }
}

/// Wide iPad and Mac windows: every room in a list, the selected one's devices beside it
/// (`ListDetailLayout`); a device opened from the room is pushed on the tab's stack.
private struct RoomsListDetail: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppleHomeModel.self) private var appleHome
    @Environment(RoomActions.self) private var actions
    @Binding var selection: RoomSelection?

    private var snapshot: HomeSnapshot { appModel.snapshot }

    var body: some View {
        ListDetailLayout(listWidth: 300) {
            ListDetailList(selection: $selection, order: listOrder) {
                pogoSection
                appleHomeSections
            }
        } detail: {
            detail
                // The pane shows one room at a time; its scroll position doesn't carry over.
                .id(selection)
        }
        .onAppear(perform: selectFirstRoomIfNeeded)
        .onChange(of: snapshot.visibleRooms.map(\.id)) { _, _ in selectFirstRoomIfNeeded() }
    }

    /// The rooms in the order of the rows below, for ↑/↓.
    private var listOrder: [RoomSelection] {
        let pogo = snapshot.visibleRooms.map { RoomSelection.pogo($0.id) }
        guard appleHome.snapshot.accessState == .ready else { return pogo }
        let appleHomeRooms = appleHome.layout(pogo: snapshot).homes.flatMap { home in
            home.rooms.map { RoomSelection.appleHome($0.id) }
        }
        return pogo + appleHomeRooms
    }

    @ViewBuilder
    private var pogoSection: some View {
        Section {
            if snapshot.visibleRooms.isEmpty {
                Text("모듈이 연결되면 방이 여기에 표시됩니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.visibleRooms) { room in
                    let modules = snapshot.modules(in: room)
                    SplitListRow(
                        symbolName: SymbolAvailability.resolvedName(for: room.symbolName),
                        tint: .blue,
                        title: room.name,
                        subtitle: RoomStatusText.summary(modules: modules, isCurrentStateVerified: appModel.health.isCurrentStateVerified)
                    )
                    .listDetailRow(RoomSelection.pogo(room.id), selection: $selection)
                    .contextMenu {
                        RoomContextMenu(room: room, actions: actions)
                    }
                }
            }
        } header: {
            Text("내 방")
        }
    }

    @ViewBuilder
    private var appleHomeSections: some View {
        let state = appleHome.snapshot.accessState
        let layout = appleHome.layout(pogo: snapshot)
        if state != .ready {
            Section {
                AppleHomeAccessNotice(state: state)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } header: {
                Text("Apple 홈")
            }
        } else if layout.homes.isEmpty {
            Section {
                Text("Apple 홈의 방에 표시할 기기가 없습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Apple 홈")
            }
        } else {
            ForEach(layout.homes) { home in
                Section {
                    ForEach(home.rooms) { room in
                        SplitListRow(
                            symbolName: room.isUnassigned ? "questionmark.square.dashed" : "square.grid.2x2.fill",
                            tint: room.isUnassigned ? Color(.systemGray) : .orange,
                            title: AppleHomeRoomText.name(of: room),
                            subtitle: AppleHomeRoomText.summary(of: room),
                            isSubtitleAlert: room.notRespondingCount > 0
                        )
                        .listDetailRow(RoomSelection.appleHome(room.id), selection: $selection)
                    }
                } header: {
                    Label {
                        Text(verbatim: "\(String(localized: "Apple 홈", comment: "Source badge of an Apple Home room")) · \(home.home.name)")
                    } icon: {
                        Image(systemName: "homekit")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case let .pogo(roomID):
            RoomDetailView(roomID: roomID)
        case let .appleHome(key):
            AppleHomeRoomDetailView(key: key)
        case nil:
            SplitDetailPlaceholder(
                title: "방을 선택하세요",
                systemImage: "square.grid.2x2",
                message: "목록에서 방을 고르면 그 방의 기기와 센서 값이 여기에 표시됩니다."
            )
        }
    }

    /// Opens on the first room rather than an empty detail column, as long as nothing (still
    /// existing) is selected.
    private func selectFirstRoomIfNeeded() {
        if case let .pogo(id)? = selection, snapshot.visibleRooms.contains(where: { $0.id == id }) { return }
        if case .appleHome? = selection { return }
        selection = snapshot.visibleRooms.first.map { .pogo($0.id) }
    }
}

/// The room card's status line, shared with the list row of the wide layout.
enum RoomStatusText {
    static func summary(modules: [SensorModule], isCurrentStateVerified: Bool) -> String {
        if modules.isEmpty { return String(localized: "등록된 기기 없음", comment: "Room card: no devices") }
        guard isCurrentStateVerified else { return String(localized: "연결 상태 확인 중", comment: "Room card: connection not verified") }
        let online = modules.filter(\.isOnline).count
        return String(localized: "온라인 \(online)/\(modules.count)", comment: "Room card: online modules / total modules")
    }
}

private struct RoomCard: View {
    let room: Room
    let modules: [SensorModule]
    let isCurrentStateVerified: Bool

    private var onlineCount: Int { modules.filter(\.isOnline).count }
    private var attentionCount: Int { modules.filter(\.hasAttentionNeeded).count }
    private var representativeReading: SensorReading? {
        modules.first?.sortedReadings.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IconCircle(systemName: SymbolAvailability.resolvedName(for: room.symbolName), diameter: 38)

            Text(room.name)
                .font(.headline)
                .foregroundStyle(.primary)

            if modules.isEmpty {
                Text("등록된 기기 없음", comment: "Room card: no devices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Group {
                    if isCurrentStateVerified {
                        Text("온라인 \(onlineCount)/\(modules.count)", comment: "Room card: online modules / total modules")
                    } else {
                        Text("연결 상태 확인 중", comment: "Room card: connection not verified")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if isCurrentStateVerified, attentionCount > 0 {
                    Text("확인 필요 \(attentionCount)개", comment: "Room card: number of devices needing attention (plural)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

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
        // No fixed height: a long name or large text grows the card (and its row); a shorter
        // card beside it stretches to the row's height.
        .frame(minHeight: 142, maxHeight: .infinity, alignment: .topLeading)
        .background(PogoTheme.tile, in: RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    RoomsView()
        .environment(AppModel.preview)
        .environment(AppleHomeModel.preview)
}
