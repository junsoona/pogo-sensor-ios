import SwiftUI

/// Settings › Apple Watch — iPhone only (hidden where no Watch can be paired). Which values the
/// Watch lists, whether the Watch app is reachable, and how the Watch gets its data.
struct WatchSettingsSection: View {
    /// `nil` in previews.
    @Environment(PhoneWatchRelay.self) private var relay: PhoneWatchRelay?
    @State private var selectionCount = PhoneWatchSettings.selection(in: .standard).count

    var body: some View {
        if let relay, relay.isSupported {
            Section {
                NavigationLink {
                    WatchValuePickerView()
                } label: {
                    LabeledContent {
                        Text(String(localized: "watch.selection.count", defaultValue: "\(selectionCount)개 선택", comment: "Settings: number of values chosen for the Apple Watch (plural)"))
                    } label: {
                        Text("Watch에 표시할 값", comment: "Settings: row that opens the Apple Watch value picker")
                    }
                }
                LabeledContent {
                    Text(stateText(relay.watchState))
                } label: {
                    Text("상태")
                }
                switch relay.handOver {
                case let .handedOver(sentAt):
                    LabeledContent {
                        Text(sentAt.formatted(date: .omitted, time: .shortened))
                    } label: {
                        Text("마지막으로 보낸 시각", comment: "Settings: when the iPhone last handed data to the Apple Watch")
                    }
                case .pending:
                    LabeledContent {
                        Text("Watch 연결 대기 중", comment: "Settings: the Watch settings wait until the Apple Watch link is ready")
                    } label: {
                        Text("설정 전달", comment: "Settings: row showing whether the settings were handed to the Apple Watch")
                    }
                case .failed:
                    LabeledContent {
                        Text("보내지 못함 · 다시 시도합니다", comment: "Settings: handing the settings to the Apple Watch failed and will be retried")
                    } label: {
                        Text("설정 전달", comment: "Settings: row showing whether the settings were handed to the Apple Watch")
                    }
                }
            } header: {
                Text(verbatim: "Apple Watch")
            } footer: {
                Text("Watch는 허브와 같은 Wi‑Fi에 있으면 직접, 아니면 가까이 있는 이 iPhone을 통해 값을 받습니다. 집 밖에서는 마지막 값과 확인 시각을 표시합니다. 허브 주소와 표시할 값, 이름은 이 iPhone에서 전달됩니다.", comment: "Settings footer: how the Apple Watch gets POGO data")
            }
            .onAppear {
                selectionCount = PhoneWatchSettings.selection(in: .standard).count
                relay.recheck()
            }
        }
    }

    private func stateText(_ state: PhoneWatchRelay.WatchState) -> String {
        switch state {
        case .unsupported:
            return String(localized: "확인 중…", comment: "Control Center value: reading the state")
        case .activating:
            return String(localized: "연결 준비 중…", comment: "Settings: the Apple Watch link is still being set up")
        case .notPaired:
            return String(localized: "페어링된 Apple Watch 없음", comment: "Settings: no Apple Watch is paired with this iPhone")
        case .appNotInstalled:
            return String(localized: "Watch에 조각보 홈 없음", comment: "Settings: PogoHome isn't installed on the paired Apple Watch")
        case .ready:
            return String(localized: "연결됨", comment: "Connection status")
        }
    }
}

/// Picks up to `WatchSettings.maximumSelectedValues` values for the Watch, from what the app has
/// stored for its widgets. POGO and Apple Home values stay separate even with the same name.
struct WatchValuePickerView: View {
    @Environment(PhoneWatchRelay.self) private var relay: PhoneWatchRelay?
    @Environment(HomeGlancePublisher.self) private var publisher: HomeGlancePublisher?
    @State private var selection = PhoneWatchSettings.selection(in: .standard)
    @State private var glance: HomeGlanceSnapshot?

    private var available: [HomeGlanceSensor] {
        guard let glance else { return [] }
        return glance.appleHome.access == .ready ? glance.sensors : glance.pogoSensors
    }

    private var missingSelection: [String] {
        let ids = Set(available.map(\.id.stringValue))
        return selection.filter { !ids.contains($0) }
    }

    var body: some View {
        List {
            Section {
                ForEach(available.filter { $0.source == .pogoLinuxAPI }) { row($0) }
            } header: {
                Text("조각보 센서", comment: "Dashboard status source: 조각보 sensors")
            }
            let appleHome = available.filter { $0.source == .appleHome }
            if !appleHome.isEmpty {
                Section {
                    ForEach(appleHome) { row($0) }
                } header: {
                    Text("Apple 홈", comment: "Dashboard status source: Apple Home")
                }
            }
            if !missingSelection.isEmpty {
                Section {
                    ForEach(missingSelection, id: \.self) { id in
                        Button(role: .destructive) {
                            toggle(id)
                        } label: {
                            Label {
                                Text("선택한 센서를 찾을 수 없음", comment: "Sensor widget: the selected sensor no longer exists")
                            } icon: {
                                Image(systemName: "minus.circle.fill")
                            }
                        }
                    }
                } footer: {
                    Text("눌러서 선택에서 뺍니다.", comment: "Watch value picker: tap a missing value to remove it from the selection")
                }
            }
        }
        .navigationTitle(Text("Watch에 표시할 값", comment: "Settings: row that opens the Apple Watch value picker"))
        .safeAreaInset(edge: .bottom) {
            Text(String(localized: "watch.selection.limit", defaultValue: "최대 \(WatchSettings.maximumSelectedValues)개까지 고를 수 있습니다. 고른 순서대로 Watch에 표시됩니다.", comment: "Watch value picker: how many values can be chosen and in which order they show"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
        .onAppear {
            glance = publisher?.latestSnapshot()
            selection = PhoneWatchSettings.selection(in: .standard)
        }
    }

    private func row(_ sensor: HomeGlanceSensor) -> some View {
        let id = sensor.id.stringValue
        let position = selection.firstIndex(of: id)
        let isFull = selection.count >= WatchSettings.maximumSelectedValues
        return Button {
            toggle(id)
        } label: {
            HStack {
                Image(systemName: HomeGlanceValueText.symbolName(of: sensor))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(HomeGlanceValueText.kindLabel(of: sensor)) · \(sensor.deviceName)")
                        .foregroundStyle(.primary)
                    if let room = sensor.roomName {
                        Text(room)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let position {
                    Image(systemName: "\(position + 1).circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel(Text(String(localized: "watch.selection.position", defaultValue: "\(position + 1)번째", comment: "Watch value picker: VoiceOver position of a chosen value")))
                }
            }
        }
        // A list row that toggles a choice, not a link-styled action.
        .tint(.primary)
        .disabled(position == nil && isFull)
        .accessibilityAddTraits(position == nil ? [] : .isSelected)
    }

    private func toggle(_ id: String) {
        guard PhoneWatchSettings.toggle(id, in: .standard) else { return }
        selection = PhoneWatchSettings.selection(in: .standard)
        relay?.settingsDidChange()
    }
}
