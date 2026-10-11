import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Turning settings sharing on for the hub the app follows:
/// 1. pair this device with the one-time code from the hub (`pogohome-hubctl pair`);
/// 2. the hub has settings → show them and use them here (download);
///    the hub has none → show exactly what this device would share, and upload it only on "올리기".
/// This device's own settings are never changed: they stay stored and come back when sharing is off.
struct SharedSettingsSetupSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        case code
        case loading
        case download(HubSettingsState, SharedSettingsSummary)
        case upload(SharedSettingsSummary)
    }

    @State private var step: Step = .code
    @State private var code = ""
    @State private var deviceName = Self.defaultDeviceName
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var hasStarted = false

    private var controller: SharedSettingsController { appModel.sharedSettings }

    var body: some View {
        NavigationStack {
            Form {
                SheetTitleRow(title: "허브 설정 공유")

                switch step {
                case .code:
                    codeSections
                case .loading:
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("허브의 설정을 확인하는 중…", comment: "Shared settings setup: reading the hub's settings")
                        }
                    }
                case let .download(state, summary):
                    downloadSections(state: state, summary: summary)
                case let .upload(summary):
                    uploadSections(summary: summary)
                }

                if let notice {
                    Section {
                        Label(notice, systemImage: "info.circle")
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .sheetTitle("허브 설정 공유")
            .sheetCloseAction { dismiss() }
            .interactiveDismissDisabled(isWorking)
            .onAppear(perform: startIfNeeded)
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var codeSections: some View {
        Section {
            TextField(text: $code, prompt: Text(verbatim: "XXXX-XXXX-XXXX")) {
                Text("연결 코드", comment: "Shared settings setup: the one-time pairing code field")
            }
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .font(.body.monospaced())
            TextField(text: $deviceName) {
                Text("이 기기 이름", comment: "Shared settings setup: this device's name as the hub lists it")
            }
            .autocorrectionDisabled()
        } header: {
            if let hubID = controller.hubID {
                Text("허브 ID \(HubIDText.short(hubID))", comment: "Hub discovery row: short hub id; argument is 8 hex digits")
            }
        } footer: {
            Text("OTBR에서 허브 서비스 계정으로 ‘pogohome-hubctl --state-dir <상태 디렉터리> pair’를 실행해 만든 12자리 연결 코드를 입력하세요. 코드는 한 번만, 정해진 시간 동안 쓸 수 있습니다. 이 기기 이름은 허브의 기기 목록에 표시됩니다.", comment: "Shared settings setup: where the pairing code comes from")
        }

        Section {
            Button {
                pair()
            } label: {
                HStack {
                    Text("연결", comment: "Shared settings setup: pair button")
                    if isWorking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isWorking || HubPairingCode.normalized(code) == nil)
        }
    }

    @ViewBuilder
    private func downloadSections(state: HubSettingsState, summary: SharedSettingsSummary) -> some View {
        Section {
            Text("이 허브에는 이미 공유 설정이 있습니다. 이 기기에서도 아래 설정을 사용합니다.", comment: "Shared settings setup: the hub already has settings")
        }
        SharedSettingsSummarySections(summary: summary)
        Section {
            Button {
                useHubSettings(state)
            } label: {
                Text("허브 설정 사용", comment: "Shared settings setup: use the hub's settings on this device")
            }
            .disabled(isWorking)
        } footer: {
            Text("이 기기에 저장된 기존 설정은 지워지지 않고 보관되며, 이 기기에서 공유를 끄면 다시 사용합니다.", comment: "Shared settings setup: local settings are kept as a backup")
        }
    }

    @ViewBuilder
    private func uploadSections(summary: SharedSettingsSummary) -> some View {
        Section {
            Text("이 허브에는 아직 공유 설정이 없습니다. 아래 설정을 이 허브의 첫 공유 설정으로 올리면 이 허브를 쓰는 다른 기기에도 표시됩니다.", comment: "Shared settings setup: the hub has no settings yet")
        }
        SharedSettingsSummarySections(summary: summary)
        Section {
            Button {
                upload(summary.document)
            } label: {
                HStack {
                    Text("이 설정을 허브에 올리기", comment: "Shared settings setup: upload this device's settings as the hub's first settings")
                    if isWorking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isWorking)
        } footer: {
            Text("그 사이 다른 기기가 먼저 올렸다면 덮어쓰지 않고 그 설정을 사용합니다. 이 기기에 저장된 기존 설정은 그대로 보관됩니다.", comment: "Shared settings setup: first upload never overwrites")
        }
    }

    // MARK: - Actions

    private func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        // Already paired (and not re-pairing because access was refused): go straight to the choice.
        if controller.isPaired && !controller.isActive {
            step = .loading
            Task { await load { try await controller.fetchForSetup() } }
        }
    }

    private func pair() {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        let code = code
        let name = deviceName
        Task {
            await load { try await controller.pair(code: code, deviceName: name) }
            isWorking = false
        }
    }

    /// Shows the right choice for what the hub has now.
    private func load(_ read: () async throws -> HubSettingsState) async {
        do {
            let state = try await read()
            if state.initialized, let settings = state.settings {
                if controller.isActive {
                    // Re-paired for settings already shared here: nothing to choose.
                    try controller.useHubSettings(state)
                    dismiss()
                    return
                }
                step = .download(state, appModel.sharedSettingsSummary(of: settings))
            } else if controller.isActive, let cached = controller.entry?.settings {
                // The hub lost its settings: offer this device's last confirmed shared copy.
                step = .upload(appModel.sharedSettingsSummary(of: cached))
            } else {
                step = .upload(appModel.sharedSettingsUploadSummary())
            }
        } catch {
            errorMessage = error.localizedDescription
            if case .loading = step { step = .code }
        }
    }

    private func useHubSettings(_ state: HubSettingsState) {
        do {
            try controller.useHubSettings(state)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func upload(_ document: HubSettingsDocument) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                switch try await controller.uploadAsFirstSettings(document) {
                case .uploaded:
                    dismiss()
                case .hubAlreadyHadSettings:
                    notice = String(localized: "다른 기기가 먼저 설정을 올려서 그 설정을 사용합니다. 이 기기의 설정은 덮어쓰지 않았습니다.", comment: "Shared settings setup: another device uploaded first")
                    if let settings = controller.entry?.settings {
                        step = .download(
                            HubSettingsState(schemaVersion: 1, hubID: controller.hubID ?? "", initialized: true, revision: controller.entry?.revision, updatedAtUnixMs: controller.entry?.updatedAtUnixMs, settings: settings),
                            appModel.sharedSettingsSummary(of: settings)
                        )
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static var defaultDeviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        Brand.appName
        #endif
    }
}

/// Home name, rooms and sensor names/rooms of a shared-settings document, as a device would show them.
struct SharedSettingsSummarySections: View {
    let summary: SharedSettingsSummary

    var body: some View {
        Section {
            LabeledContent {
                Text(verbatim: summary.homeName)
            } label: {
                Text("집 이름")
            }
        } header: {
            Text("집")
        }

        Section {
            if summary.rooms.isEmpty {
                Text("방이 없습니다", comment: "Shared settings summary: no rooms")
                    .foregroundStyle(.secondary)
            }
            ForEach(summary.rooms) { room in
                Label(room.name, systemImage: SymbolAvailability.resolvedName(for: room.symbolName))
            }
        } header: {
            Text("방 \(summary.rooms.count)개", comment: "Shared settings summary: rooms header with count")
        }

        Section {
            if summary.modules.isEmpty {
                Text("이름이나 방을 지정한 센서가 없습니다", comment: "Shared settings summary: no module settings")
                    .foregroundStyle(.secondary)
            }
            ForEach(summary.modules) { module in
                LabeledContent {
                    Text(verbatim: module.roomName)
                } label: {
                    Text(verbatim: module.name)
                }
            }
        } header: {
            Text("조각보 센서 \(summary.modules.count)개", comment: "Shared settings summary: sensors header with count")
        } footer: {
            if summary.leftOutModuleCount > 0 {
                Text("이 허브에 지금 연결되어 있지 않은 센서 \(summary.leftOutModuleCount)개의 설정은 올리지 않습니다.", comment: "Shared settings summary: module settings not uploaded; argument is a count")
            }
        }
    }
}
