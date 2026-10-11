import SwiftUI

/// One Apple Home accessory: where it comes from, whether it responds, when PogoHome last
/// read it, the values HomeKit exposes, and — only for supported, writable characteristics —
/// its controls.
struct AppleHomeAccessoryDetailView: View {
    @Environment(AppleHomeModel.self) private var appleHome
    @Environment(AppModel.self) private var appModel
    @Environment(\.detailPlacement) private var placement
    let accessoryID: UUID

    private var accessory: AppleHomeAccessory? { appleHome.snapshot.accessory(with: accessoryID) }

    var body: some View {
        Group {
            if let accessory {
                content(accessory)
            } else if appleHome.snapshot.accessState != .ready {
                CenteredEmptyState {
                    AppleHomeAccessNotice(state: appleHome.snapshot.accessState)
                }
            } else {
                CenteredEmptyState {
                    ContentUnavailableView(
                        "기기를 찾을 수 없습니다",
                        systemImage: "questionmark.circle",
                        description: Text("Apple 홈에서 이 기기가 삭제되었거나 다른 집으로 옮겨졌을 수 있습니다.")
                    )
                }
            }
        }
        .detailTitle(accessory?.name ?? String(localized: "device.detail.fallbackTitle", defaultValue: "기기", comment: "Title of a device screen whose device no longer exists (singular)")) {
            if let accessory {
                if appleHome.refreshingAccessoryIDs.contains(accessoryID) {
                    ProgressView()
                } else {
                    Button("다시 읽기", systemImage: "arrow.clockwise") {
                        Task { await appleHome.refresh(accessoryID: accessoryID) }
                    }
                    .disabled(!accessory.isOperable)
                }
            }
        }
        .task(id: accessoryID) {
            if placement == .pane {
                // Beside the device list, ↑/↓ pass through devices one after another: only the
                // one the selection stops on is read. Moving on replaces this pane, which cancels
                // the wait.
                do { try await Task.sleep(for: PogoTheme.listDetailReadDelay) } catch { return }
            }
            await appleHome.refresh(accessoryID: accessoryID)
        }
    }

    private func content(_ accessory: AppleHomeAccessory) -> some View {
        let controls = AppleHomeCapabilities.controls(of: accessory)
        let values = AppleHomeCapabilities.values(of: accessory)
        let support = AppleHomeCapabilities.featureSupport(of: accessory)
        return List {
            Section {
                LabeledContent("출처") {
                    Text(verbatim: AppleHomeText.source(of: accessory))
                }
                if let home = appleHome.snapshot.home(with: accessory.homeID) {
                    LabeledContent("집") { Text(verbatim: home.name) }
                }
                LabeledContent {
                    Text(verbatim: accessory.roomName ?? String(localized: "방 미지정", comment: "Device card: module has no room"))
                } label: {
                    Text(String(localized: "device.detail.room", defaultValue: "방", comment: "Label: the room a device is in (singular)"))
                }
                LabeledContent("연결 상태") {
                    Text(AppleHomeText.connection(of: accessory))
                        .foregroundStyle(accessory.isOperable ? Color.secondary : Color.red)
                }
                LabeledContent("마지막 확인") {
                    lastCheckedValue(accessory)
                }
                switch AppleHomeValueStatus.resolve(accessory) {
                case let .failed(error):
                    Label {
                        Text("마지막 읽기 실패: \(error)", comment: "Apple Home: the latest read failed; the argument is the reason")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.footnote)
                    .foregroundStyle(.orange)
                case let .retrying(attempt, maxAttempts):
                    Label(AppleHomeText.retrying(attempt: attempt, maxAttempts: maxAttempts), systemImage: "arrow.clockwise")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                case .nothingToRead, .checking, .checked, .notChecked:
                    EmptyView()
                }
            } footer: {
                if !accessory.isOperable {
                    Text("기기가 응답하지 않는 동안 표시된 값은 마지막으로 확인한 값이며, 제어할 수 없습니다.")
                }
            }

            if !controls.isEmpty {
                Section {
                    ForEach(controls) { control in
                        AppleHomeControlRow(accessoryID: accessory.id, control: control)
                    }
                } header: {
                    Text("제어")
                } footer: {
                    Text("기기가 변경된 상태를 다시 보고해야 적용된 것으로 표시합니다.")
                }
            }

            if !values.isEmpty {
                Section("값") {
                    ForEach(values) { value in
                        LabeledContent {
                            if let text = value.displayValue {
                                Text(verbatim: text)
                                    .foregroundStyle(value.needsAttention ? Color.red : Color.secondary)
                            } else {
                                Text("아직 읽지 않음")
                                    .foregroundStyle(.tertiary)
                            }
                        } label: {
                            Label(value.label, systemImage: SymbolAvailability.resolvedName(for: value.symbolName))
                        }
                    }
                }
            }

            featureSupportSection(support)

            if hasDeviceInfo(accessory) {
                deviceInfoSection(accessory)
            }

            duplicateSection(accessory)
        }
        .listScreenBackground()
        .refreshable {
            await appleHome.refresh(accessoryID: accessory.id)
        }
    }

    /// Where to use what this screen can't show: the whole device when nothing on it is shown
    /// here, otherwise only the named features the Home app has beyond the shown ones.
    @ViewBuilder
    private func featureSupportSection(_ support: AppleHomeFeatureSupport) -> some View {
        switch support {
        case .appleHomeOnly:
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text("Apple 홈에서 사용해 주세요")
                            .font(.headline)
                    } icon: {
                        Image(systemName: "homekit")
                            .foregroundStyle(.orange)
                    }
                    Text("현재 조각보 홈에서는 이 기기의 상태를 확인하거나 조작할 수 없습니다. Apple 홈 앱에서 사용할 수 있습니다.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
        case let .supported(otherFeatureNames) where !otherFeatureNames.isEmpty:
            Section {
                ForEach(otherFeatureNames, id: \.self) { name in
                    Label {
                        Text(verbatim: name)
                    } icon: {
                        Image(systemName: "homekit")
                    }
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Apple 홈 앱에서 사용할 수 있는 기능")
            } footer: {
                Text("이 기능은 조각보 홈에 표시되지 않습니다. Apple 홈 앱에서 확인하고 조작할 수 있습니다.")
            }
        case .supported:
            EmptyView()
        }
    }

    @ViewBuilder
    private func lastCheckedValue(_ accessory: AppleHomeAccessory) -> some View {
        if let checked = accessory.lastCheckedAt {
            Text(checked, format: .dateTime.hour().minute().second())
        } else if AppleHomeValueStatus.resolve(accessory) == .nothingToRead {
            Text(String(localized: "읽을 수 있는 값 없음", comment: "Apple Home accessory: it has no value PogoHome can read (not a failure)"))
        } else if AppleHomeValueStatus.resolve(accessory).isPending {
            Text(String(localized: "상태 확인 중…", comment: "Apple Home tile: reading the device's state"))
        } else {
            Text("아직 읽지 않음")
        }
    }

    private func hasDeviceInfo(_ accessory: AppleHomeAccessory) -> Bool {
        [accessory.manufacturer, accessory.model, accessory.firmwareVersion, accessory.categoryDescription]
            .contains { !($0 ?? "").isEmpty } || accessory.isBridged
    }

    private func deviceInfoSection(_ accessory: AppleHomeAccessory) -> some View {
        Section("기기 정보") {
            if let manufacturer = accessory.manufacturer, !manufacturer.isEmpty {
                LabeledContent("제조사") { Text(verbatim: manufacturer) }
            }
            if let model = accessory.model, !model.isEmpty {
                LabeledContent("모델") { Text(verbatim: model) }
            }
            if let firmware = accessory.firmwareVersion, !firmware.isEmpty {
                LabeledContent("펌웨어") { Text(verbatim: firmware) }
            }
            if !accessory.categoryDescription.isEmpty {
                LabeledContent("종류") { Text(verbatim: accessory.categoryDescription) }
            }
            if accessory.isBridged {
                Text("브리지를 통해 Apple 홈에 연결된 기기입니다.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Lets the user say "this is the same sensor as that 조각보 sensor" — see `DeviceDirectory`.
    /// Only the user's choice links the two, never a matching name.
    private func duplicateSection(_ accessory: AppleHomeAccessory) -> some View {
        let modules = appModel.snapshot.modules.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let linked = appleHome.linkedModuleID(forAccessory: accessory.id)
        let linkedModule = linked.flatMap { id in modules.first { $0.id == id } }
        return Section {
            if let linkedModule {
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text("이 센서는 센서 목록에도 표시됩니다")
                            .font(.subheadline.weight(.semibold))
                    } icon: {
                        Image(systemName: "link")
                            .foregroundStyle(.blue)
                    }
                    Text("같은 센서가 Apple 홈과 조각보 센서 목록에 각각 표시됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                NavigationLink(value: AppRoute.module(linkedModule.id)) {
                    LabeledContent {
                        Text(verbatim: linkedModule.name)
                    } label: {
                        Label {
                            Text("조각보 센서에서 보기")
                        } icon: {
                            Image(systemName: "sensor.fill")
                        }
                    }
                }
            } else if linked != nil {
                Label {
                    Text("연결한 조각보 센서가 지금 목록에 없어 이 기기를 숨기지 않고 표시합니다.")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
            }
            Picker(selection: Binding(
                get: { linked },
                set: { appleHome.link(accessoryID: accessory.id, toPogoModule: $0) }
            )) {
                Text("선택 안 함").tag(UUID?.none)
                ForEach(modules) { module in
                    Text(verbatim: module.name).tag(Optional(module.id))
                }
                if let linked, linkedModule == nil {
                    Text("현재 목록에 없는 조각보 센서").tag(Optional(linked))
                }
            } label: {
                Text("같은 조각보 센서")
            }
        } header: {
            Text("조각보 센서와 같은 센서")
        } footer: {
            if linkedModule != nil {
                Text("조각보 홈에서 이 기기를 숨기고, 기기 목록과 방 화면 아래 ‘조각보 센서와 같은 Apple 홈 기기’에 모아 둡니다. Apple 홈에서는 아무것도 삭제되지 않습니다.")
            } else {
                Text("OTBR(조각보 허브)를 Apple 홈에 추가하면 같은 센서가 Apple 홈과 조각보 센서에 각각 표시됩니다. 같은 조각보 센서를 고르면 조각보 홈에서 이 Apple 홈 기기를 숨깁니다. Apple 홈에서는 아무것도 삭제되지 않습니다.")
            }
        }
    }
}
