import SwiftUI

/// "Find hubs": lists the Jogakbo sensor hubs announcing themselves on this network, and connects
/// to the one the user picks — only after checking it (`HubDiscoveryModel.select`). Closing the
/// sheet stops the search and any check still running; nothing changes then.
struct HubDiscoverySheet: View {
    /// The `hub_id` the app is following now, marked in the list.
    let currentHubID: String?
    /// Called once, with a hub that passed the check; the sheet closes itself afterwards.
    let onSelect: (SelectedHub) -> Void

    @State private var model: HubDiscoveryModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(currentHubID: String?, model: HubDiscoveryModel = HubDiscoveryModel(), onSelect: @escaping (SelectedHub) -> Void) {
        self.currentHubID = currentHubID
        self.onSelect = onSelect
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            List {
                SheetTitleRow(title: "허브 찾기")

                Section {
                    statusRow
                    ForEach(model.hubs) { hub in
                        HubRow(
                            hub: hub,
                            isCurrent: hub.hubID != nil && hub.hubID == currentHubID,
                            isVerifying: model.verifyingHubID == hub.id,
                            failure: model.verificationFailure?.hubID == hub.id ? model.verificationFailure?.message : nil,
                            isDisabled: model.verifyingHubID != nil
                        ) {
                            choose(hub)
                        }
                    }
                } header: {
                    Text("같은 네트워크의 센서 허브", comment: "Hub discovery list header")
                } footer: {
                    Text("조각보 센서 허브(Linux)만 찾습니다. Power Base와 센서 모듈은 허브를 통해 표시됩니다. 고른 허브는 확인을 마친 뒤에 연결됩니다.", comment: "Hub discovery list footer")
                }

                Section {
                    Button {
                        model.restart()
                    } label: {
                        Label {
                            Text("다시 찾기", comment: "Hub discovery: search again")
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(model.verifyingHubID != nil)
                }
            }
            .listScreenBackground()
            .sheetTitle("허브 찾기")
            .sheetCloseAction { dismiss() }
            .onAppear { model.start() }
            .onDisappear { model.stop() }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.searchState {
        case .idle, .searching:
            if model.showsNoResults {
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text("찾은 허브가 없습니다", comment: "Hub discovery: nothing found")
                    } icon: {
                        Image(systemName: "questionmark.circle")
                    }
                    Text("허브가 켜져 있고 API가 활성화되어 있는지, 이 기기와 같은 네트워크에 있는지 확인하세요. 계속 찾는 중입니다.", comment: "Hub discovery: nothing found, hint")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if model.hubs.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("같은 네트워크에서 센서 허브를 찾는 중…", comment: "Hub discovery: searching")
                        .foregroundStyle(.secondary)
                }
            }
        case .localNetworkDenied:
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(PlatformSupport.localNetworkDeniedMessage)
                } icon: {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.orange)
                }
                if let url = PlatformSupport.localNetworkSettingsURL {
                    Button {
                        openURL(url)
                    } label: {
                        if PlatformSupport.isMacCatalyst {
                            Text("시스템 설정 열기")
                        } else {
                            Text("설정 열기")
                        }
                    }
                }
            }
        case let .failed(message):
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("허브를 찾지 못했습니다", comment: "Hub discovery: browsing failed")
                    Text(verbatim: message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private func choose(_ hub: DiscoveredHub) {
        Task {
            guard let selection = await model.select(hub) else { return }
            onSelect(selection)
            dismiss()
        }
    }
}

private struct HubRow: View {
    let hub: DiscoveredHub
    let isCurrent: Bool
    let isVerifying: Bool
    let failure: String?
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "server.rack")
                    .foregroundStyle(hub.problem == nil ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: hub.serviceName)
                        .foregroundStyle(hub.problem == nil ? .primary : .secondary)
                    if let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if isVerifying {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("허브를 확인하는 중…", comment: "Hub discovery: checking the chosen hub")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let failure {
                        Text(verbatim: failure)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Text("현재 연결", comment: "Hub discovery: the hub the app is connected to")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .disabled(isDisabled || hub.problem != nil)
        .accessibilityHint(hub.problem == nil ? Text("이 허브를 확인한 뒤 연결합니다", comment: "VoiceOver hint for a discovered hub") : Text(verbatim: ""))
    }

    private var detail: String? {
        switch hub.problem {
        case .missingHubID:
            return String(localized: "허브 ID가 없는 서비스", comment: "Hub discovery row: the announcement has no hub_id")
        case .unsupportedAPI:
            return String(localized: "지원하지 않는 API 버전", comment: "Hub discovery row: unsupported API version")
        case nil:
            guard let id = hub.hubID else { return nil }
            return String(localized: "허브 ID \(HubIDText.short(id))", comment: "Hub discovery row: short hub id; argument is 8 hex digits")
        }
    }
}

/// The last 8 hex digits of a hub_id — enough to tell two hubs apart at a glance.
enum HubIDText {
    static func short(_ hubID: String) -> String {
        String(hubID.suffix(8))
    }
}

#Preview {
    HubDiscoverySheet(currentHubID: nil) { _ in }
}
