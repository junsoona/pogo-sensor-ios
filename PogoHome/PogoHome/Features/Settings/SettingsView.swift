import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isEditingHomeName = false
    @State private var isFindingHubs = false

    @AppStorage(PogoSettingsKeys.dataSourceMode) private var dataSourceModeRaw = DataSourceMode.live.rawValue
    @AppStorage(PogoSettingsKeys.liveBaseURL) private var liveBaseURLString = PogoAPIEndpoint.defaultBaseURLString
    @AppStorage(PogoSettingsKeys.selectedHub) private var selectedHubValue = ""

    private var dataSourceMode: DataSourceMode {
        DataSourceMode(rawValue: dataSourceModeRaw) ?? .live
    }

    /// The hub picked in "Find hubs" that the Live connection follows, if any.
    private var selectedHub: SelectedHub? {
        SelectedHub(storedValue: selectedHubValue)
    }

    /// The address field. Typing an address means connecting to that address: it leaves the hub
    /// picked in "Find hubs" (address first, then the choice — see `DataSourceFactory.apply`).
    private var manualAddress: Binding<String> {
        Binding(
            get: { liveBaseURLString },
            set: { newValue in
                guard newValue != liveBaseURLString else { return }
                liveBaseURLString = newValue
                if !selectedHubValue.isEmpty {
                    selectedHubValue = ""
                }
            }
        )
    }

    /// Product version and build number, read from the bundle (docs/versioning.md). A missing
    /// value is shown as unknown; no number is made up in its place.
    private var buildInfo: AppBuildInfo { .current }

    var body: some View {
        NavigationStack {
            List {
                if let configurationError = appModel.configurationError {
                    Section {
                        Label(configurationError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Button("확인") { appModel.clearConfigurationError() }
                    } header: {
                        Text("설정 저장 문제")
                    }
                }

                Section {
                    Button {
                        isEditingHomeName = true
                    } label: {
                        LabeledContent {
                            Text(appModel.homeName)
                        } label: {
                            Text("집 이름")
                        }
                    }
                    // A settings row that opens an editor, not a link-styled action.
                    .tint(.primary)
                    .accessibilityHint(Text("집 이름을 편집합니다", comment: "VoiceOver hint for the home name row"))
                } header: {
                    Text("집")
                } footer: {
                    Text("조각보 홈 앱에서만 표시되는 이름입니다. Apple 홈 앱의 집 이름은 바뀌지 않습니다.")
                }

                SharedSettingsSection()

                AppleHomeSettingsSection()

                WatchSettingsSection()

                LocalStorageSection()

                Section {
                    Picker("데이터 소스", selection: $dataSourceModeRaw) {
                        ForEach(DataSourceMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }

                    if dataSourceMode == .live {
                        if let selectedHub {
                            LabeledContent {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(verbatim: selectedHub.serviceName)
                                    Text("허브 ID \(HubIDText.short(selectedHub.hubID))", comment: "Hub discovery row: short hub id; argument is 8 hex digits")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            } label: {
                                Text("센서 허브", comment: "Settings: the sensor hub picked in Find hubs")
                            }
                        }
                        Button {
                            isFindingHubs = true
                        } label: {
                            Label {
                                Text("허브 찾기", comment: "Settings button and sheet title: find sensor hubs on the network")
                            } icon: {
                                Image(systemName: "magnifyingglass")
                            }
                        }
                        TextField(text: manualAddress, prompt: Text(verbatim: PogoAPIEndpoint.defaultBaseURLString)) {
                            Text("API 주소", comment: "Label of the live hub URL field")
                        }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        LabeledContent("연결 상태", value: appModel.connectionStatus.displayText)
                        if appModel.connectionStatus != .connected {
                            Text(PlatformSupport.localNetworkPermissionHint)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        LabeledContent("연결 상태") {
                            Text("모의 데이터 사용 중")
                        }
                    }
                } header: {
                    Text("데이터 소스")
                } footer: {
                    if dataSourceMode == .live {
                        if selectedHub != nil {
                            Text("찾은 허브에 연결되어 있습니다. 허브의 주소가 바뀌면 같은 허브를 다시 찾아 연결합니다. 주소를 직접 입력하면 입력한 주소로 연결합니다.", comment: "Settings footer while following a discovered hub")
                        } else {
                            Text("‘허브 찾기’로 같은 네트워크의 센서 허브를 찾거나, 허브의 주소를 직접 입력하세요.", comment: "Settings footer while connecting by a typed address")
                        }
                    }
                }

                Section {
                    Text("Live 모드는 같은 Wi-Fi에 있는 OTBR(조각보 허브)에 연결합니다. Apple 홈 기기는 위의 ‘Apple 홈’에서 따로 켭니다. 집·방·기기 이름을 다른 기기와 함께 쓰려면 ‘허브 설정 공유’에서 이 기기를 연결하세요.", comment: "Settings: about Live mode and hub settings sharing")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("안내")
                }

                Section("앱 정보") {
                    NavigationLink {
                        NameMeaningView()
                    } label: {
                        Text("이름에 담긴 뜻", comment: "Settings row and screen title: the meaning of the app's name")
                    }
                    LabeledContent { Text(verbatim: buildInfo.version) } label: { Text(verbatim: BuildDetailsText.version) }
                    LabeledContent { Text(verbatim: buildInfo.buildNumber) } label: { Text(verbatim: BuildDetailsText.buildNumber) }
                    NavigationLink {
                        BuildDetailsView()
                    } label: {
                        Text(verbatim: BuildDetailsText.title)
                    }
                    LabeledContent("번들 ID", value: Bundle.main.bundleIdentifier ?? "com.junsoona.PogoHome")
                }
            }
            .listScreenBackground()
            .tabRootTitle(Text("설정"))
            .sheet(isPresented: $isEditingHomeName) {
                HomeNameEditorSheet()
            }
            .sheet(isPresented: $isFindingHubs) {
                HubDiscoverySheet(currentHubID: selectedHub?.hubID) { hub in
                    DataSourceFactory.apply(hub, in: .standard)
                }
            }
        }
    }
}

/// What PogoHome keeps only on this device. There is no iCloud/CloudKit sync: the SwiftData store
/// and `UserDefaults` live in this app's own container, so an iPhone, an iPad and a Mac each have
/// their own copy — the same names are not carried over by themselves.
private struct LocalStorageSection: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Section {
            if !appModel.usesSharedSettings {
                Label {
                    Text("방 구성, 방·기기 이름, 집 이름")
                } icon: {
                    Image(systemName: "internaldrive")
                }
            }
            Label {
                Text("데이터 소스, 선택한 센서 허브와 API 주소, Apple 홈 표시 설정")
            } icon: {
                Image(systemName: "internaldrive")
            }
        } header: {
            Text("이 기기에만 저장")
        } footer: {
            if appModel.usesSharedSettings {
                Text("방 구성과 이름은 지금 허브와 공유하고 있습니다. 위 항목은 기기마다 따로 저장됩니다.", comment: "Settings footer while hub settings sharing is on")
            } else {
                Text("이 정보는 기기마다 따로 저장되고 다른 기기와 동기화되지 않습니다. 같은 이름을 함께 쓰려면 ‘허브 설정 공유’를 켜세요. Apple 홈의 기기와 방 이름은 Apple 홈에서 가져오므로 어느 기기에서나 같습니다.", comment: "Settings footer: what stays on this device")
            }
        }
    }
}

/// One line under a name editor: where the name is kept — on this device only, or on the hub for
/// every device sharing its settings.
struct ConfigurationStorageNote: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if appModel.usesSharedSettings {
            Text("이 이름은 허브에 저장되어 같은 허브와 설정을 공유하는 iPhone, iPad, Mac에 함께 표시됩니다.", comment: "Name editor footer while hub settings sharing is on")
        } else {
            Text("이 이름은 이 기기에만 저장되며 다른 iPhone, iPad, Mac과 동기화되지 않습니다.")
        }
    }
}

/// Shown at the top of an editor while shared settings can't be changed (hub offline, access
/// revoked, …), with the reason. Nothing while editing works.
struct ConfigurationEditBlockedNotice: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if let reason = appModel.configurationEditBlockedReason {
            Section {
                Label(reason, systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppModel.preview)
        .environment(AppleHomeModel.preview)
}
