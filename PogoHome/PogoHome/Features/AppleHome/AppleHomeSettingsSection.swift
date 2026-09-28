import SwiftUI

/// Settings › Apple 홈: turn reading Apple Home on/off in PogoHome and see the access state.
struct AppleHomeSettingsSection: View {
    @Environment(AppleHomeModel.self) private var appleHome
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { appleHome.isEnabled },
                set: { $0 ? appleHome.enable() : appleHome.disable() }
            )) {
                Text("Apple 홈 기기 표시")
            }
            LabeledContent("상태") {
                Text(AppleHomeText.accessStateSummary(appleHome.snapshot.accessState))
            }
            if appleHome.snapshot.accessState == .ready {
                LabeledContent("Apple 홈 기기") {
                    Text(String(localized: "devices.count", defaultValue: "\(appleHome.snapshot.accessories.count)개", comment: "Number of devices (plural)"))
                }
            }
            if appleHome.snapshot.accessState == .denied {
                Button {
                    if let url = PlatformSupport.appleHomePermissionSettingsURL { openURL(url) }
                } label: {
                    Text(PlatformSupport.isMacCatalyst
                        ? String(localized: "시스템 설정에서 홈 데이터 접근 허용", comment: "Mac: opens System Settings at the Apple Home permission")
                        : String(localized: "설정에서 홈 데이터 접근 허용"))
                }
            }
        } header: {
            Text("Apple 홈")
        } footer: {
            Text("켜면 Apple 홈에 추가한 Matter·HomeKit 기기를 읽습니다. 끄면 조각보 홈에서만 보이지 않으며, Apple 홈의 기기와 설정은 바뀌지 않습니다.")
        }
    }
}
