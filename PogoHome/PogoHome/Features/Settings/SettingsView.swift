import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel

    @AppStorage(PogoSettingsKeys.dataSourceMode) private var dataSourceModeRaw = DataSourceMode.live.rawValue
    @AppStorage(PogoSettingsKeys.liveBaseURL) private var liveBaseURLString = PogoAPIEndpoint.defaultBaseURLString

    private var dataSourceMode: DataSourceMode {
        DataSourceMode(rawValue: dataSourceModeRaw) ?? .live
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("데이터 소스") {
                    Picker("데이터 소스", selection: $dataSourceModeRaw) {
                        ForEach(DataSourceMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }

                    if dataSourceMode == .live {
                        TextField("http://192.168.50.129:8787", text: $liveBaseURLString)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        LabeledContent("연결 상태", value: appModel.connectionStatus.displayText)
                    } else {
                        LabeledContent("연결 상태", value: "모의 데이터 사용 중")
                    }
                }

                Section {
                    Text("Live 모드는 같은 Wi-Fi 네트워크에 있는 Linux PogoHome API에 연결합니다. HomeKit·Matter 연동, 자동 기기 검색(Bonjour), 인증은 다음 단계에서 제공될 예정입니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("안내")
                }

                Section("앱 정보") {
                    LabeledContent("버전", value: appVersion)
                    LabeledContent("번들 ID", value: Bundle.main.bundleIdentifier ?? "com.junsoona.PogoHome")
                }
            }
            .navigationTitle("설정")
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppModel.preview)
}
