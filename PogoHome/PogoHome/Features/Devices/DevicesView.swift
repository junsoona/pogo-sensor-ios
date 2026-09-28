import SwiftUI

/// Device edits started from either layout of the Devices tab, presented once by `DevicesView`.
@MainActor
@Observable
final class DeviceActions {
    var editingModule: SensorModule?
    var isAddingDevice = false
}

/// What the list-and-detail layout shows in its detail column.
enum DeviceSelection: Hashable {
    case pogo(UUID)
    case appleHome(UUID)
}

struct DevicesView: View {
    @State private var actions = DeviceActions()
    /// Kept here so it survives switching between the two layouts (iPad window resizing).
    @State private var selection: DeviceSelection?

    var body: some View {
        @Bindable var actions = actions
        // One navigation stack for both layouts: resizing a window swaps only its root, so the
        // bar, a pushed screen and the other tabs' stacks are never rebuilt.
        NavigationStack {
            AdaptiveSplitLayout {
                DevicesGrid()
            } wide: {
                DevicesListDetail(selection: $selection)
            }
            .tabRootTitle(Text("기기"))
            .toolbar {
                DevicesToolbar(actions: actions)
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case let .module(moduleID):
                    ModuleDetailView(moduleID: moduleID)
                case let .room(roomID):
                    RoomDetailView(roomID: roomID)
                }
            }
            .appleHomeNavigationDestinations()
        }
        .environment(actions)
        .sheet(item: $actions.editingModule) { module in
            ModuleEditorSheet(moduleID: module.id)
        }
        .sheet(isPresented: $actions.isAddingDevice) {
            AddDeviceSheet()
        }
    }
}

private struct DevicesToolbar: ToolbarContent {
    let actions: DeviceActions

    var body: some ToolbarContent {
        ToolbarAddButton("기기 추가", placement: .topBarTrailing) {
            actions.isAddingDevice = true
        }
    }
}

/// iPhone and narrow windows: device cards per Power Base, pushing a device's screen.
private struct DevicesGrid: View {
    @Environment(AppModel.self) private var appModel
    @Environment(DeviceActions.self) private var actions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var snapshot: HomeSnapshot { appModel.snapshot }

    var body: some View {
        ScrollView {
            pogoContent
            // Apple Home devices come from HomeKit, separately from the POGO Linux API above;
            // any Apple Home state (off, denied, no home) leaves the POGO part untouched.
            AppleHomeDevicesSection()
                .padding([.horizontal, .bottom])
        }
        .screenBackground()
    }

    @ViewBuilder
    private var pogoContent: some View {
        if snapshot.modules.isEmpty && snapshot.powerBases.isEmpty {
            ContentUnavailableView(
                "연결된 조각보 센서가 없습니다",
                systemImage: "sensor.fill",
                description: Text("모듈이 연결되면 여기에 표시됩니다.")
            )
            .padding(.top, 60)
        } else if snapshot.powerBases.isEmpty {
            // A bridge without Power Base reporting (or mock data): the original flat list.
            moduleSection(
                title: "조각보 센서",
                subtitle: String(localized: "devices.count", defaultValue: "\(snapshot.modules.count)개", comment: "Number of devices (plural)"),
                modules: snapshot.modules
            )
            .padding()
        } else {
            VStack(alignment: .leading, spacing: PogoTheme.sectionSpacing) {
                ForEach(snapshot.powerBases) { base in
                    powerBaseSection(base)
                }
                let unassigned = snapshot.modulesWithoutPowerBase
                if !unassigned.isEmpty {
                    moduleSection(
                        title: "Power Base 정보 없음",
                        subtitle: String(localized: "devices.count", defaultValue: "\(unassigned.count)개", comment: "Number of devices (plural)"),
                        modules: unassigned
                    )
                }
            }
            .padding()
        }
    }

    private func powerBaseSection(_ base: PowerBase) -> some View {
        let modules = snapshot.chainOrderedModules(on: base)
        return VStack(alignment: .leading, spacing: 12) {
            PowerBaseHeader(base: base, isCurrentStateVerified: appModel.health.isCurrentStateVerified)
            if modules.isEmpty {
                Text("이 Power Base에 연결된 센서 모듈이 없습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                moduleGrid(modules)
            }
        }
    }

    private func moduleSection(title: LocalizedStringKey, subtitle: String, modules: [SensorModule]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: title, subtitle: subtitle)
            moduleGrid(modules)
        }
    }

    private func moduleGrid(_ modules: [SensorModule]) -> some View {
        LazyVGrid(
            columns: PogoTheme.cardColumns(for: dynamicTypeSize),
            spacing: PogoTheme.gridSpacing
        ) {
            ForEach(modules) { module in
                NavigationLink(value: AppRoute.module(module.id)) {
                    DeviceCard(
                        module: module,
                        room: snapshot.room(for: module),
                        isCurrentStateVerified: appModel.health.isCurrentStateVerified,
                        connectionText: PowerBaseConnectionText.chainPosition(of: module, in: snapshot),
                        isPowerBaseOffline: snapshot.isOfflineBecausePowerBaseIsOffline(module)
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("기기 편집", systemImage: "pencil") {
                        actions.editingModule = module
                    }
                }
            }
        }
    }
}

/// Wide iPad and Mac windows: every device in a list — POGO modules under their Power Base,
/// then Apple Home by home — with the selected one's screen beside it (`ListDetailLayout`).
private struct DevicesListDetail: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppleHomeModel.self) private var appleHome
    @Environment(DeviceActions.self) private var actions
    @Binding var selection: DeviceSelection?

    private var snapshot: HomeSnapshot { appModel.snapshot }
    private var isVerified: Bool { appModel.health.isCurrentStateVerified }

    var body: some View {
        ListDetailLayout(listWidth: 340) {
            ListDetailList(selection: $selection, order: listOrder) {
                pogoSections
                appleHomeSections
            }
        } detail: {
            detail
                .id(selection)
        }
        .onAppear(perform: selectFirstDeviceIfNeeded)
        .onChange(of: snapshot.modules.map(\.id)) { _, _ in selectFirstDeviceIfNeeded() }
    }

    /// The devices in the order of the rows below, for ↑/↓.
    private var listOrder: [DeviceSelection] {
        let modules = snapshot.powerBases.isEmpty
            ? snapshot.modules
            : snapshot.powerBases.flatMap { snapshot.chainOrderedModules(on: $0) } + snapshot.modulesWithoutPowerBase
        let pogo = modules.map { DeviceSelection.pogo($0.id) }
        guard appleHome.snapshot.accessState == .ready else { return pogo }
        let layout = appleHome.layout(pogo: snapshot)
        let accessories = layout.homes.flatMap { $0.rooms.flatMap(\.accessories) } + layout.hiddenDuplicates
        return pogo + accessories.map { DeviceSelection.appleHome($0.id) }
    }

    @ViewBuilder
    private var pogoSections: some View {
        if snapshot.modules.isEmpty && snapshot.powerBases.isEmpty {
            Section {
                Text("연결된 조각보 센서가 없습니다")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                Text("조각보 센서")
            }
        } else if snapshot.powerBases.isEmpty {
            Section {
                ForEach(snapshot.modules) { moduleRow($0) }
            } header: {
                Text("조각보 센서")
            }
        } else {
            ForEach(snapshot.powerBases) { base in
                let modules = snapshot.chainOrderedModules(on: base)
                Section {
                    if modules.isEmpty {
                        Text("이 Power Base에 연결된 센서 모듈이 없습니다.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(modules) { moduleRow($0) }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label {
                            Text(verbatim: base.shortLabel)
                        } icon: {
                            Image(systemName: "powerplug.fill")
                        }
                        Text(PowerBaseConnectionText.summary(of: base))
                            .font(.caption)
                            .foregroundStyle(isVerified && !base.isOnline ? Color.red : Color.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            let unassigned = snapshot.modulesWithoutPowerBase
            if !unassigned.isEmpty {
                Section {
                    ForEach(unassigned) { moduleRow($0) }
                } header: {
                    Text("Power Base 정보 없음")
                }
            }
        }
    }

    private func moduleRow(_ module: SensorModule) -> some View {
        let room = snapshot.room(for: module)
        let status = DeviceStatusText.pogo(
            module,
            isCurrentStateVerified: isVerified,
            isPowerBaseOffline: snapshot.isOfflineBecausePowerBaseIsOffline(module)
        )
        let roomName = room?.name ?? String(localized: "방 미지정", comment: "Device card: module has no room")
        return SplitListRow(
            symbolName: SymbolAvailability.resolvedName(for: room?.symbolName ?? "sensor.fill"),
            tint: isVerified && module.isOnline ? .blue : .gray,
            title: module.name,
            subtitle: "\(roomName) · \(status)",
            isSubtitleAlert: isVerified && !module.isOnline
        )
        .listDetailRow(DeviceSelection.pogo(module.id), selection: $selection)
        .contextMenu {
            Button("기기 편집", systemImage: "pencil") {
                actions.editingModule = module
            }
        }
    }

    @ViewBuilder
    private var appleHomeSections: some View {
        let state = appleHome.snapshot.accessState
        let layout = appleHome.layout(pogo: snapshot)
        if state != .ready {
            Section {
                AppleHomeAccessNotice(state: state)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } header: {
                Text("Apple 홈")
            }
        } else if layout.homes.isEmpty && layout.hiddenDuplicates.isEmpty {
            Section {
                Text("Apple 홈에 등록된 기기가 없습니다. 오른쪽 위 + 버튼에서 Matter 기기를 추가할 수 있습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Apple 홈")
            }
        } else {
            ForEach(layout.homes) { home in
                Section {
                    ForEach(home.rooms) { room in
                        ForEach(room.accessories) { accessory in
                            AppleHomeListRow(accessory: accessory)
                                .listDetailRow(DeviceSelection.appleHome(accessory.id), selection: $selection)
                        }
                    }
                } header: {
                    Label {
                        Text(verbatim: "\(String(localized: "Apple 홈", comment: "Source badge of an Apple Home room")) · \(home.home.name)")
                    } icon: {
                        Image(systemName: "homekit")
                    }
                }
            }
            if !layout.hiddenDuplicates.isEmpty {
                Section {
                    ForEach(layout.hiddenDuplicates) { accessory in
                        AppleHomeListRow(accessory: accessory)
                            .listDetailRow(DeviceSelection.appleHome(accessory.id), selection: $selection)
                    }
                } header: {
                    Text("조각보 센서와 같은 Apple 홈 기기 \(layout.hiddenDuplicates.count)개", comment: "Collapsed list of Apple Home accessories hidden as duplicates of POGO sensors (plural)")
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case let .pogo(moduleID):
            ModuleDetailView(moduleID: moduleID)
        case let .appleHome(accessoryID):
            AppleHomeAccessoryDetailView(accessoryID: accessoryID)
        case nil:
            SplitDetailPlaceholder(
                title: "기기를 선택하세요",
                systemImage: "sensor.fill",
                message: "목록에서 기기를 고르면 센서 값과 연결 정보가 여기에 표시됩니다."
            )
        }
    }

    private func selectFirstDeviceIfNeeded() {
        if case let .pogo(id)? = selection, snapshot.modules.contains(where: { $0.id == id }) { return }
        if case .appleHome? = selection { return }
        let first = snapshot.powerBases.lazy.compactMap { snapshot.chainOrderedModules(on: $0).first }.first
            ?? snapshot.modulesWithoutPowerBase.first
            ?? snapshot.modules.first
        selection = first.map { .pogo($0.id) }
    }
}

/// An Apple Home accessory in the device list: the same on/off icon button as its tile
/// (`AppleHomeTileIcon`), so a light can still be switched without opening it.
private struct AppleHomeListRow: View {
    @Environment(AppleHomeModel.self) private var appleHome
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let accessory: AppleHomeAccessory

    var body: some View {
        let quick = appleHome.quickControl(for: accessory)
        let pending = quick.control.flatMap { appleHome.pendingValues[$0.id] }
        let state = AppleHomeTileText.state(
            of: accessory,
            quick: quick,
            pending: pending,
            isReading: appleHome.refreshingAccessoryIDs.contains(accessory.id)
        )
        let problem = AppleHomeTileText.problem(of: accessory, quick: quick, messages: appleHome.controlMessages)
        // Every line wraps in full at accessibility sizes (`SplitListRow`); the icon stays, as it's
        // the device's on/off button.
        let lineLimit = dynamicTypeSize.isAccessibilitySize ? nil : 2
        HStack(spacing: 12) {
            AppleHomeTileIcon(accessory: accessory, quick: quick, isBusy: appleHome.isQuickControlBusy(accessory))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: accessory.name)
                    .lineLimit(lineLimit)
                Text(verbatim: [AppleHomeTileText.roomName(of: accessory), state].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(accessory.isOperable ? Color.secondary : Color.red)
                    .lineLimit(lineLimit)
                if let problem {
                    Text(verbatim: problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(lineLimit)
                }
            }
            .accessibilityElement(children: .combine)
            .listDetailRowAccessibility()
            Spacer(minLength: 0)
        }
    }
}

/// A POGO module's status line, shared by the card and the list row.
enum DeviceStatusText {
    static func pogo(_ module: SensorModule, isCurrentStateVerified: Bool, isPowerBaseOffline: Bool) -> String {
        let count = module.readings.count
        guard isCurrentStateVerified else {
            return String(localized: "상태 확인 중 · 센서 \(count)개", comment: "Device card: status unknown · number of sensors (plural)")
        }
        if !module.isOnline && isPowerBaseOffline {
            return String(localized: "Power Base 연결 끊김", comment: "Device card status: its Power Base went offline")
        }
        return module.isOnline
            ? String(localized: "온라인 · 센서 \(count)개", comment: "Device card: online · number of sensors (plural)")
            : String(localized: "오프라인", comment: "Device card status")
    }
}

/// One Power Base's section title: which Base, whether the bridge still hears it, and how
/// many of its modules are online.
struct PowerBaseHeader: View {
    let base: PowerBase
    let isCurrentStateVerified: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconCircle(systemName: "powerplug.fill", diameter: 34, background: isCurrentStateVerified && base.isOnline ? .indigo : .gray)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: base.shortLabel)
                    .font(.title3.weight(.semibold))
                Text(PowerBaseConnectionText.summary(of: base))
                    .font(.caption)
                    .foregroundStyle(isCurrentStateVerified && !base.isOnline ? Color.red : Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// User-facing wording for Power Base relations, shared by the device list and detail screens.
enum PowerBaseConnectionText {
    static func summary(of base: PowerBase) -> String {
        let state = base.isOnline
            ? String(localized: "연결됨", comment: "Power Base state: the bridge hears it")
            : String(localized: "연결 끊김", comment: "Power Base state: the bridge no longer hears it")
        return String(
            localized: "powerbase.summary",
            defaultValue: "\(state) · 모듈 \(base.onlineModuleCount)/\(base.moduleCount)개 온라인",
            comment: "Power Base header: state · online modules / all modules"
        )
    }

    /// Where the module sits in its POGO chain, from the bridge-reported parent link.
    static func chainPosition(of module: SensorModule, in snapshot: HomeSnapshot) -> String? {
        if module.isDirectlyOnPowerBase {
            return String(localized: "Power Base에 직접 연결", comment: "Device chain position")
        }
        if let parent = snapshot.parentModule(of: module) {
            return String(localized: "\(parent.name) 뒤에 연결", comment: "Device chain position; the name is the upstream module")
        }
        return nil
    }
}

private struct DeviceCard: View {
    let module: SensorModule
    let room: Room?
    let isCurrentStateVerified: Bool
    var connectionText: String? = nil
    var isPowerBaseOffline = false

    private var tint: Color { isCurrentStateVerified && module.isOnline ? .blue : .gray }

    private var roomName: String {
        room?.name ?? String(localized: "방 미지정", comment: "Device card: module has no room")
    }

    private var statusText: String {
        DeviceStatusText.pogo(module, isCurrentStateVerified: isCurrentStateVerified, isPowerBaseOffline: isPowerBaseOffline)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                IconCircle(systemName: SymbolAvailability.resolvedName(for: room?.symbolName ?? "sensor.fill"), diameter: 38, background: tint)
                Spacer()
                Image(
                    systemName: isCurrentStateVerified
                        ? module.isOnline ? "checkmark.circle.fill" : "xmark.circle.fill"
                        : "questionmark.circle.fill"
                )
                    .foregroundStyle(isCurrentStateVerified && module.isOnline ? .green : .secondary)
                    .accessibilityHidden(true)
            }

            Spacer(minLength: 18)

            Text(module.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text(roomName)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let connectionText {
                Text(connectionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(isCurrentStateVerified && !module.isOnline ? Color.red : Color.secondary)
                .lineLimit(2)
        }
        .padding(PogoTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 154, alignment: .topLeading)
        .background(PogoTheme.tile, in: RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(module.name)
        .accessibilityValue(
            connectionText.map { Text(verbatim: "\(roomName), \(statusText), \($0)") }
                ?? Text("\(roomName), \(statusText)", comment: "VoiceOver value of a device card: room name, status")
        )
    }
}

#Preview {
    DevicesView()
        .environment(AppModel.preview)
        .environment(AppleHomeModel.preview)
}
