import SwiftUI

struct RoomEditorSheet: View {
    enum Mode {
        case create
        case edit(Room)
    }

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let mode: Mode

    @State private var name: String
    @State private var symbolName: String
    @State private var errorMessage: String?
    @State private var isSaving = false
    /// The room as `name`/`symbolName` were loaded from it, and the shared settings revision it
    /// came from (see `AppModel.configurationEditBase`). Adding a room overwrites nothing, so it
    /// is saved against whatever copy is current.
    @State private var loadedRoom: Room?
    @State private var editBase: ConfigurationEditBase = .current
    @State private var hasLoadedCurrentValues = false

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _symbolName = State(initialValue: RoomIconCatalog.categories[0].symbolNames[0])
        case let .edit(room):
            _name = State(initialValue: room.name)
            _symbolName = State(initialValue: room.symbolName)
            _loadedRoom = State(initialValue: room)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                SheetTitleRow(title: title)

                ConfigurationEditBlockedNotice()

                Section {
                    ClearableNameField(title: "방 이름", text: $name, placeholder: suggestedName)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("방 정보")
                } footer: {
                    ConfigurationStorageNote()
                }

                Section("아이콘") {
                    RoomIconPicker(selection: $symbolName)
                        .padding(.vertical, 8)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .sheetTitle(title)
            .editorSheetActions(isSaveDisabled: isSaving || !appModel.canEditConfiguration, onCancel: { dismiss() }, onSave: save)
            .interactiveDismissDisabled(isSaving)
            .onAppear {
                guard !hasLoadedCurrentValues else { return }
                hasLoadedCurrentValues = true
                loadCurrentValues()
            }
        }
    }

    /// The room as it is now (the one this sheet was opened with may already be older), together
    /// with the revision it belongs to.
    private func loadCurrentValues() {
        guard let id = editingRoomID else { return }
        editBase = appModel.configurationEditBase
        guard let room = appModel.editableRooms.first(where: { $0.id == id }) else { return }
        loadedRoom = room
        name = room.name
        symbolName = room.symbolName
    }

    private var editingRoomID: UUID? {
        switch mode {
        case .create: return nil
        case let .edit(room): return room.id
        }
    }

    /// Shown in gray while the field is empty and saved if it's still empty on Save —
    /// recomputed from the current icon on every render, so changing the icon updates it
    /// immediately, while any name the user typed is untouched. Saved as an app-provided name,
    /// so it keeps following the app language (see `RoomNameSource`).
    private var suggestedNameSource: RoomNameSource {
        appModel.suggestedRoomNameSource(for: symbolName, excludingRoomID: editingRoomID)
    }

    private var suggestedName: String {
        suggestedNameSource.displayName(in: appModel.language)
    }

    private var title: LocalizedStringKey {
        switch mode {
        case .create: return "방 추가"
        case .edit: return "방 편집"
        }
    }

    private func save() {
        guard !isSaving else { return }
        let nameSource = RoomNameSuggestion.resolvedSource(
            input: name,
            suggestion: suggestedNameSource,
            editing: loadedRoom
        )
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                // While sharing, this returns once the hub has stored the room.
                switch mode {
                case .create:
                    try await appModel.createRoom(nameSource: nameSource, symbolName: symbolName)
                case let .edit(room):
                    try await appModel.updateRoom(id: room.id, nameSource: nameSource, symbolName: symbolName, basedOn: editBase)
                }
                dismiss()
            } catch SharedSettingsEditError.conflict {
                // Another device changed the settings first: show the room as it is now.
                loadCurrentValues()
                errorMessage = SharedSettingsEditError.conflict.localizedDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
