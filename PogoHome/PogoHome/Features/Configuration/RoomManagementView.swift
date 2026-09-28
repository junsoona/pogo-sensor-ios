import SwiftUI

/// The Apple Home-style "방 편집" screen, reached from `RoomsView`'s meatball menu: rename,
/// re-icon, delete (with confirmation), and drag-reorder every room except the fallback
/// ("미지정 공간"), which is always shown last, and is never draggable, editable, or
/// deletable. Like every room list, it hides "미지정 공간" while no module is placed there
/// (`HomeSnapshot.visibleRooms`).
struct RoomManagementView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var rooms: [Room] = []
    /// The shared settings revision `rooms` was loaded from: a reorder is saved only on top of it
    /// (see `AppModel.configurationEditBase`), so an order made from an older list never replaces
    /// another device's change.
    @State private var roomsBase: ConfigurationEditBase = .current
    /// One reorder at a time: the next drag starts from the list the hub confirmed.
    @State private var isSavingOrder = false
    @State private var editingRoom: Room?
    @State private var roomPendingDeletion: PendingRoomDeletion?
    @State private var editError: String?

    var body: some View {
        List {
            ConfigurationEditBlockedNotice()

            Section {
                ForEach(rooms) { room in
                    HStack(spacing: 12) {
                        IconCircle(systemName: SymbolAvailability.resolvedName(for: room.symbolName), diameter: 30)
                        Text(room.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editingRoom = room }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            requestDeletion(of: room)
                        } label: {
                            Label("삭제", systemImage: "trash")
                        }
                        Button {
                            editingRoom = room
                        } label: {
                            Label("편집", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
                .onMove(perform: moveAction)
                .onDelete { offsets in
                    guard let index = offsets.first else { return }
                    requestDeletion(of: rooms[index])
                }
            } footer: {
                Text("드래그하여 순서를 바꿀 수 있습니다.")
            }

            if appModel.snapshot.hasModulesInUnspecifiedRoom {
                unspecifiedRoomSection
            }
        }
        .navigationTitle(String(localized: "rooms.manage", defaultValue: "방 편집", comment: "Opens the screen for renaming, reordering and deleting all rooms"))
        .navigationBarTitleDisplayMode(.inline)
        .modifier(RoomManagementButtons(onDone: { dismiss() }))
        .onAppear(perform: reload)
        .sheet(item: $editingRoom) { room in
            RoomEditorSheet(mode: .edit(room))
        }
        .alert(
            "방을 삭제할까요?",
            isPresented: Binding(
                get: { roomPendingDeletion != nil },
                set: { if !$0 { roomPendingDeletion = nil } }
            ),
            presenting: roomPendingDeletion
        ) { pending in
            Button("삭제", role: .destructive) {
                roomPendingDeletion = nil
                Task {
                    do {
                        // Its devices move to 미지정 공간 in the same change. Refused unsent (a
                        // conflict) when a newer list arrived after this one was shown.
                        try await appModel.deleteRoom(id: pending.room.id, basedOn: pending.base)
                    } catch {
                        editError = error.localizedDescription
                    }
                    reload()
                }
            }
            Button("취소", role: .cancel) {
                roomPendingDeletion = nil
            }
        } message: { pending in
            Text("‘\(pending.room.name)’에 있는 기기는 미지정 공간으로 이동합니다.", comment: "Delete-room confirmation; the room name is user data")
        }
        .onChange(of: editingRoom == nil, initial: false) { _, _ in reload() }
        // Another device's change, or the hub's copy after a conflict.
        .onChange(of: appModel.editableRooms.map(\.id)) { _, _ in reload() }
        .onChange(of: appModel.configurationEditBase) { _, _ in
            reload()
            if let pending = roomPendingDeletion, !pending.isCurrent(in: appModel) {
                // Confirmed against an older list; never delete on it.
                roomPendingDeletion = nil
                editError = SharedSettingsEditError.conflict.localizedDescription
            }
        }
        .alert(
            String(localized: "설정을 저장하지 못했습니다", comment: "Alert title when a room change could not be saved"),
            isPresented: Binding(get: { editError != nil }, set: { if !$0 { editError = nil } }),
            presenting: editError
        ) { _ in
            Button("확인") { editError = nil }
        } message: { message in
            Text(verbatim: message)
        }
    }

    /// Shown only while a module is actually placed in the fallback room — see
    /// `HomeSnapshot.visibleRooms`. Read straight from the observed snapshot, so it appears or
    /// disappears live as modules move, independent of the reorderable `rooms` copy.
    private var unspecifiedRoomSection: some View {
        Section {
            HStack(spacing: 12) {
                IconCircle(
                    systemName: SymbolAvailability.resolvedName(for: ModuleCatalog.unspecifiedRoom.symbolName),
                    diameter: 30,
                    background: Color(.tertiarySystemFill),
                    foreground: Color.secondary
                )
                Text(ModuleCatalog.unspecifiedRoom.name)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } footer: {
            Text("미지정 공간은 이름 변경, 삭제, 순서 변경이 불가능하며 항상 마지막에 표시됩니다.")
        }
    }

    private func reload() {
        rooms = appModel.editableRooms.filter { $0.id != ModuleCatalog.unspecifiedRoomID }
        roomsBase = appModel.configurationEditBase
    }

    /// Confirms against the list on screen. Not while an order is being saved: that save's own new
    /// revision would close the confirmation as if another device had changed the list.
    private func requestDeletion(of room: Room) {
        guard !isSavingOrder else { return }
        roomPendingDeletion = PendingRoomDeletion(room: room, base: roomsBase)
    }

    /// Reordering is off while shared settings can't be changed, and while an order is being saved.
    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard appModel.canEditConfiguration, !isSavingOrder else { return nil }
        return { source, destination in move(from: source, to: destination) }
    }

    private func move(from source: IndexSet, to destination: Int) {
        rooms.move(fromOffsets: source, toOffset: destination)
        let order = rooms.map(\.id)
        let base = roomsBase
        isSavingOrder = true
        Task {
            defer { isSavingOrder = false }
            do {
                // Refused unsent (a conflict) when a newer list arrived after `rooms` was loaded.
                try await appModel.reorderRooms(orderedIDs: order, basedOn: base)
            } catch {
                editError = error.localizedDescription
                // Back to the order that is actually saved.
                reload()
            }
        }
    }
}

/// 편집 (reorder) and 완료: in the navigation bar on iPhone and iPad; at the bottom of the sheet on
/// the Mac, where the sheet's bar squeezes text buttons into fixed-size circles (see
/// `editorSheetActions`).
private struct RoomManagementButtons: ViewModifier {
    let onDone: () -> Void
    /// The list's edit (reorder) mode on the Mac, owned here: an `EditButton` outside the
    /// navigation bar doesn't reach the list's.
    @State private var editMode: EditMode = .inactive

    func body(content: Content) -> some View {
        if PlatformSupport.isMacCatalyst {
            content
                .environment(\.editMode, $editMode)
                .safeAreaBar(edge: .bottom) {
                    HStack(spacing: 12) {
                        Button(editMode.isEditing ? "완료" : "편집") {
                            withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                        }
                        Spacer(minLength: 0)
                        // Two "완료" side by side would be ambiguous: the sheet closes once
                        // reordering is done.
                        if !editMode.isEditing {
                            Button("완료", action: onDone)
                                .keyboardShortcut(.defaultAction)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .controlSize(.large)
                    .padding()
                }
        } else {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("완료", action: onDone)
                    }
                }
        }
    }
}

#Preview {
    NavigationStack {
        RoomManagementView()
            .environment(AppModel.preview)
    }
}
