import SwiftUI

/// Edits the PogoHome-only home name shown as the Dashboard title. Mirrors the sensor
/// editor: the field holds only the user's own name, the localized default ("우리 집") shows
/// in gray while it's empty, and saving an empty field goes back to that default — so the
/// default keeps following the app language, while a typed name is kept verbatim.
/// Never touches Apple Home.
struct HomeNameEditorSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var errorMessage: String?
    @State private var hasLoadedInitialValue = false
    @State private var isSaving = false
    /// The shared settings revision `name` was loaded from; see `AppModel.configurationEditBase`.
    @State private var editBase: ConfigurationEditBase = .current

    var body: some View {
        NavigationStack {
            Form {
                SheetTitleRow(title: "집 이름")

                ConfigurationEditBlockedNotice()

                Section {
                    ClearableNameField(title: "집 이름", text: $name, placeholder: appModel.defaultHomeName)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("이름을 비우면 기본 이름(\(appModel.defaultHomeName))으로 되돌아갑니다. 이 이름은 조각보 홈 앱에만 저장되며 Apple 홈 앱의 집 이름은 바뀌지 않습니다.", comment: "Home name editor footer; the argument is the default home name")
                        ConfigurationStorageNote()
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .sheetTitle("집 이름")
            .editorSheetActions(isSaveDisabled: isSaving || !appModel.canEditConfiguration, onCancel: { dismiss() }, onSave: save)
            .interactiveDismissDisabled(isSaving)
            .onAppear {
                guard !hasLoadedInitialValue else { return }
                hasLoadedInitialValue = true
                loadCurrentValue()
            }
        }
    }

    private func loadCurrentValue() {
        name = appModel.customHomeName ?? ""
        editBase = appModel.configurationEditBase
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                // While sharing, this returns once the hub has stored the name.
                try await appModel.updateHomeName(input: name, basedOn: editBase)
                dismiss()
            } catch SharedSettingsEditError.conflict {
                // Another device changed the settings first: show its name, not the stale one.
                loadCurrentValue()
                errorMessage = SharedSettingsEditError.conflict.localizedDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    HomeNameEditorSheet()
        .environment(AppModel.preview)
}
