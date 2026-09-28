import SwiftUI

struct ModuleEditorSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let moduleID: UUID

    @State private var name = ""
    @State private var roomID = ModuleCatalog.unspecifiedRoomID
    @State private var errorMessage: String?
    /// `.pickerStyle(.navigationLink)` pushes a system picker screen; popping back from it
    /// re-fires `onAppear` on this root Form. Without this guard, `loadInitialValues()` would
    /// run again on that pop and silently reset `roomID`/`name` to the module's still-persisted
    /// values, discarding the selection the user just made before Save ever runs.
    @State private var hasLoadedInitialValues = false
    @State private var isSaving = false
    /// The shared settings revision `name`/`roomID` were loaded from; see
    /// `AppModel.configurationEditBase`.
    @State private var editBase: ConfigurationEditBase = .current

    var body: some View {
        NavigationStack {
            Form {
                SheetTitleRow(title: "기기 편집")

                ConfigurationEditBlockedNotice()

                if let module = appModel.module(with: moduleID) {
                    Section {
                        ClearableNameField(title: "기기 이름", text: $name, placeholder: module.hardwareName)
                        LabeledContent("제품 이름", value: module.hardwareName)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("기기 정보")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("이름을 비우면 제품 이름으로 되돌아갑니다.")
                            ConfigurationStorageNote()
                        }
                    }

                    Section(String(localized: "module.editor.roomSection", defaultValue: "방", comment: "Device editor section for choosing the device's room (singular)")) {
                        Picker("배치할 방", selection: $roomID) {
                            ForEach(appModel.editableRooms) { room in
                                Label(room.name, systemImage: SymbolAvailability.resolvedName(for: room.symbolName))
                                    .tag(room.id)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }

                    if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    ContentUnavailableView("기기를 찾을 수 없습니다", systemImage: "sensor")
                }
            }
            .sheetTitle("기기 편집")
            .editorSheetActions(
                isSaveDisabled: appModel.module(with: moduleID) == nil || isSaving || !appModel.canEditConfiguration,
                onCancel: { dismiss() },
                onSave: save
            )
            .interactiveDismissDisabled(isSaving)
            .onAppear(perform: loadInitialValues)
        }
    }

    private func loadInitialValues() {
        guard !hasLoadedInitialValues else { return }
        hasLoadedInitialValues = true
        loadCurrentValues()
    }

    private func loadCurrentValues() {
        editBase = appModel.configurationEditBase
        guard let module = appModel.module(with: moduleID) else { return }
        // The persisted custom name, verbatim; empty (showing `hardwareName` in gray) when
        // the module has none.
        name = appModel.customName(forModule: module.id) ?? ""
        roomID = appModel.editableRooms.contains(where: { $0.id == module.roomID })
            ? module.roomID
            : ModuleCatalog.unspecifiedRoomID
    }

    private func save() {
        guard !isSaving, let module = appModel.module(with: moduleID) else { return }
        let customName = ModuleNameInput.customName(input: name, hardwareName: module.hardwareName)
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                // While sharing, this returns once the hub has stored the name and room.
                try await appModel.updateModule(id: moduleID, customName: customName, roomID: roomID, basedOn: editBase)
                dismiss()
            } catch SharedSettingsEditError.conflict {
                // Another device changed the settings first: show the name and room as they are now.
                loadCurrentValues()
                errorMessage = SharedSettingsEditError.conflict.localizedDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
