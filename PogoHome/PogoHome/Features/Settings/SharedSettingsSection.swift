import SwiftUI

/// Settings → "허브 설정 공유": whether this device shows its own home settings or the ones it shares
/// through the hub it follows, and turning that on and off. See `SharedSettingsController`.
struct SharedSettingsSection: View {
    @Environment(AppModel.self) private var appModel
    @State private var isSettingUp = false
    @State private var isConfirmingStop = false

    private var controller: SharedSettingsController { appModel.sharedSettings }

    var body: some View {
        Section {
            SharedSettingsStatusRow(status: controller.status)

            if let detail {
                Text(verbatim: detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if controller.hubID == nil {
                Text(appModel.sourceIdentity.isSimulated
                     ? String(localized: "모의 데이터를 쓰는 동안에는 설정을 공유하지 않습니다.", comment: "Shared settings: simulated data is never shared")
                     : String(localized: "‘허브 찾기’로 선택한 허브와 설정을 공유할 수 있습니다.", comment: "Shared settings: needs a hub picked in Find hubs"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !controller.isActive {
                Button {
                    isSettingUp = true
                } label: {
                    Label {
                        Text(controller.isPaired
                             ? String(localized: "허브와 설정 공유 시작", comment: "Shared settings: start sharing on a paired device")
                             : String(localized: "코드로 이 기기 연결", comment: "Shared settings: pair this device with a one-time code"))
                    } icon: {
                        Image(systemName: "link")
                    }
                }
            } else {
                if case .failed = controller.status {
                    Button {
                        controller.retry()
                    } label: {
                        Label(String(localized: "다시 확인", comment: "Shared settings: check with the hub again"), systemImage: "arrow.clockwise")
                    }
                }
                if controller.status == .conflict {
                    Button {
                        controller.acknowledgeConflict()
                    } label: {
                        Label(String(localized: "확인했습니다", comment: "Shared settings: dismiss the conflict notice"), systemImage: "checkmark")
                    }
                }
                if needsRepair {
                    Button {
                        isSettingUp = true
                    } label: {
                        Label(String(localized: "코드로 다시 연결", comment: "Shared settings: pair again after access was refused"), systemImage: "link")
                    }
                }
                if let deviceID = controller.pairedDeviceID {
                    LabeledContent {
                        Text(verbatim: deviceID)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    } label: {
                        Text("이 기기 ID", comment: "Shared settings: this device's id on the hub (for revoking it there)")
                    }
                }
                Button(role: .destructive) {
                    isConfirmingStop = true
                } label: {
                    Label(String(localized: "이 기기에서 공유 끄기", comment: "Shared settings: stop sharing on this device"), systemImage: "xmark.circle")
                }
            }
        } header: {
            Text("허브 설정 공유", comment: "Settings section title: sharing home settings through the hub")
        } footer: {
            Text("공유하면 집 이름, 방, 조각보 센서 이름과 방 배치가 같은 허브를 쓰는 iPhone, iPad, Mac에 똑같이 표시됩니다. 센서 값, Apple 홈, 모의 데이터, 언어·화면 설정, Watch에 표시할 센서는 공유하지 않습니다.", comment: "Shared settings footer: what is and isn't shared")
        }
        .sheet(isPresented: $isSettingUp) {
            SharedSettingsSetupSheet()
        }
        .confirmationDialog(
            String(localized: "이 기기에서 공유를 끌까요?", comment: "Shared settings: stop sharing confirmation title"),
            isPresented: $isConfirmingStop,
            titleVisibility: .visible
        ) {
            Button(String(localized: "공유 끄기", comment: "Shared settings: confirm stop sharing"), role: .destructive) {
                Task { await controller.stopSharing() }
            }
        } message: {
            Text("이 기기는 공유 전 이 기기에 저장해 둔 설정을 다시 사용합니다. 허브의 공유 설정과 다른 기기는 그대로입니다.", comment: "Shared settings: stop sharing confirmation message")
        }
    }

    private var needsRepair: Bool {
        controller.status == .failed(.unauthorized) || controller.status == .failed(.certificateChanged)
    }

    private var detail: String? {
        switch controller.status {
        case .conflict:
            return SharedSettingsEditError.conflict.errorDescription
        case let .failed(failure):
            return SharedSettingsController.message(for: failure)
        case .shared:
            guard let at = controller.lastConfirmedAt else { return nil }
            return String(localized: "마지막 확인: \(at.formatted(date: .omitted, time: .shortened))", comment: "Shared settings: time of the last confirmation with the hub")
        case .localOnly, .checking:
            return nil
        }
    }
}

/// "이 기기에만 저장" / "허브와 공유 중" / "연결 확인 중" / "수정 충돌" / "동기화 실패".
struct SharedSettingsStatusRow: View {
    let status: SharedSettingsController.Status

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if status == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
                Text(title)
            }
        } label: {
            Text("공유 상태", comment: "Shared settings: status row label")
        }
    }

    private var title: String {
        switch status {
        case .localOnly: return String(localized: "이 기기에만 저장", comment: "Shared settings status")
        case .checking: return String(localized: "연결 확인 중", comment: "Shared settings status")
        case .shared: return String(localized: "허브와 공유 중", comment: "Shared settings status")
        case .conflict: return String(localized: "수정 충돌", comment: "Shared settings status")
        case .failed: return String(localized: "동기화 실패", comment: "Shared settings status")
        }
    }

    private var symbol: String {
        switch status {
        case .localOnly: return "internaldrive"
        case .checking: return "arrow.triangle.2.circlepath"
        case .shared: return "checkmark.circle.fill"
        case .conflict: return "exclamationmark.triangle.fill"
        case .failed: return "exclamationmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .localOnly: return .secondary
        case .checking: return .secondary
        case .shared: return .green
        case .conflict: return .orange
        case .failed: return .red
        }
    }
}
