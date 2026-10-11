import SwiftUI

/// Device edits started from either layout of the Devices tab, presented once by `DevicesView`.
@MainActor
@Observable
final class DeviceActions {
    var editingModule: SensorModule?
    var isAddingDevice = false
    /// The Power Base whose management sheet (state, removal) is shown.
    var managingPowerBase: PowerBaseManagementTarget?
}

/// What the list-and-detail layout shows in its detail column.
enum DeviceSelection: Hashable {
    case pogo(UUID)
    case appleHome(UUID)
}

struct DevicesView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    /// The window's tab selection; `nil` where the tab is shown by itself (previews, tests).
    @Environment(AppNavigator.self) private var navigator: AppNavigator?
    @State private var actions: DeviceActions
    /// Power Base removal jobs of the hub the app follows. Kept by the tab, not by the sheet: a
    /// job goes on at the hub whether or not its sheet is open.
    @State private var removals: PowerBaseRemovalController
    /// Kept here so it survives switching between the two layouts (iPad window resizing).
    @State private var selection: DeviceSelection?
    /// How long a "삭제 완료" notice stays on screen.
    private let noticeDuration: Duration
    /// Tells VoiceOver that a removal was completed. Replaced in tests.
    private let announce: @MainActor (String) -> Void

    /// Every argument is replaced in tests only.
    init(
        actions: DeviceActions = DeviceActions(),
        removals: PowerBaseRemovalController = PowerBaseRemovalController(),
        noticeDuration: Duration = .seconds(5),
        announce: @escaping @MainActor (String) -> Void = PowerBaseRemovalCompletionNotice.announce
    ) {
        _actions = State(initialValue: actions)
        _removals = State(initialValue: removals)
        self.noticeDuration = noticeDuration
        self.announce = announce
    }

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
        .environment(removals)
        .sheet(item: $actions.editingModule) { module in
            ModuleEditorSheet(moduleID: module.id)
        }
        .sheet(isPresented: $actions.isAddingDevice) {
            AddDeviceSheet()
        }
        .sheet(item: $actions.managingPowerBase) { target in
            PowerBaseManagementSheet(target: target, controller: removals)
        }
        .onAppear { removals.targetDidChange(hubTarget) }
        .onChange(of: hubTarget) { _, target in removals.targetDidChange(target) }
        // Every word of the hub about its removal jobs, from the first snapshot on and whether or
        // not a management sheet is open: this is how a removal the hub carries out by itself is
        // seen to end. Here on the tab, not on a row of a list.
        .onChange(of: removalReport, initial: true) { _, report in
            removals.sourceDidReport(
                report.jobs, forgets: report.forgets, powerBases: report.powerBases, departures: report.departures, from: report.source
            )
        }
        // Once per hub: what the hub's own list says, for a job the snapshot does not carry.
        .task(id: hubTarget.hubID) { await removals.refresh() }
        // "삭제 완료", for removals that ended while the app was following them: taken in whenever
        // the hub says so, shown and announced only while this tab is really on screen.
        .onChange(of: NoticeCheck(isOnScreen: isOnScreen, waiting: removals.notices.waiting), initial: true) { _, check in
            if check.isOnScreen {
                for completion in removals.showWaitingNotices() { announce(PowerBaseRemovalCompletionNotice.text(for: completion)) }
            } else {
                removals.noticesWereInterrupted()
            }
        }
        .overlay(alignment: .bottom) {
            let shown = removals.notices.shown
            if isOnScreen, !shown.isEmpty {
                PowerBaseRemovalCompletionNotice(completions: shown, duration: noticeDuration) { removals.noticesWereShown(shown) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: removals.notices.shown)
    }

    private var hubTarget: PowerBaseHubTarget { PowerBaseHubTarget(appModel: appModel) }

    private var removalReport: RemovalReport {
        RemovalReport(
            source: appModel.sourceIdentity, jobs: appModel.snapshot.powerBaseRemovals, forgets: appModel.snapshot.powerBaseForgets,
            powerBases: appModel.snapshot.powerBases, departures: appModel.snapshot.powerBaseDepartures
        )
    }

    /// Whether the user can see this tab now: the app is in the foreground, the tab is the
    /// selected one, and none of its sheets is over it. A notice is shown, announced and timed
    /// only then.
    private var isOnScreen: Bool {
        scenePhase == .active
            && (navigator?.selectedTab ?? .devices) == .devices
            && actions.editingModule == nil && !actions.isAddingDevice && actions.managingPowerBase == nil
    }

    /// The hub's removal jobs as of the snapshot on screen, and the source they are from.
    private struct RemovalReport: Equatable {
        let source: SensorSourceIdentity
        let jobs: [PowerBaseRemoval]
        /// The Bases the hub took out of its list (not removals).
        let forgets: [PowerBaseForget]
        /// The Bases the hub lists, with their registrations: what a request of this device that
        /// has no final word is checked against (`PowerBaseRemovalController.settleRequests`).
        let powerBases: [PowerBase]
        /// The Bases the hub names as out of its list: a removal request without an answer ends
        /// when its Base is one of them.
        let departures: [PowerBaseDeparture]
    }

    /// What decides whether notices are shown: read together, compared together.
    private struct NoticeCheck: Equatable {
        let isOnScreen: Bool
        let waiting: [PowerBaseRemovalCompletions.Completion]
    }
}

/// The short notice that a Power Base was removed: at the bottom of the Devices tab for a few
/// seconds, once per removal (`PowerBaseRemovalCompletions` decides which removals get one,
/// `PowerBaseRemovalNotices` when). Several removals that ended together are one notice with a
/// line each. Tapping it puts it away at once.
///
/// The view only draws and counts its time while it is in the hierarchy; its owner puts it there
/// only while the tab is really on screen, and announces it.
struct PowerBaseRemovalCompletionNotice: View {
    let completions: [PowerBaseRemovalCompletions.Completion]
    /// How long the notice stays when it is not tapped.
    var duration: Duration = .seconds(5)
    var onDismiss: () -> Void = {}

    static func text(for completion: PowerBaseRemovalCompletions.Completion) -> String {
        let label = PowerBaseManagementPresentation.label(forIdentifier: completion.powerBaseIdentifier)
        switch completion.kind {
        case .removalCompleted: return PowerBaseManagementText.completionNotice(label: label)
        // Not a removal: said as what it is.
        case .removedFromHubList: return PowerBaseManagementText.forgetNotice(label: label)
        }
    }

    var body: some View {
        Button(action: onDismiss) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(completions) { completion in
                    Label {
                        Text(verbatim: Self.text(for: completion))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        switch completion.kind {
                        case .removalCompleted:
                            Image(systemName: PowerBaseManagementContent.symbol(.completed))
                                .foregroundStyle(PowerBaseManagementContent.style(.completed))
                        case .removedFromHubList:
                            // Not the mark of a completed removal.
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius, style: .continuous).strokeBorder(.separator))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: PogoTheme.emptyStateMaxWidth)
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
        // Restarts when another removal joins the notice.
        .task(id: completions) {
            guard (try? await Task.sleep(for: duration)) != nil else { return }
            onDismiss()
        }
    }

    /// Spoken even while VoiceOver is moving to the screen under the sheet that just closed.
    static func announce(_ text: String) {
        var announcement = AttributedString(text)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
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
    @Environment(PowerBaseRemovalController.self) private var removals
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
        let pendingRemovals = PowerBaseManagementPresentation.openRemovalsWithoutPowerBase(in: snapshot)
        if snapshot.modules.isEmpty && snapshot.powerBases.isEmpty {
            if !pendingRemovals.isEmpty {
                PowerBaseRemovalCards(removals: pendingRemovals)
                    .padding()
            }
            ContentUnavailableView(
                "연결된 조각보 센서가 없습니다",
                systemImage: "sensor.fill",
                description: Text("모듈이 연결되면 여기에 표시됩니다.")
            )
            .padding(.top, pendingRemovals.isEmpty ? 60 : 20)
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
                if !pendingRemovals.isEmpty {
                    PowerBaseRemovalCards(removals: pendingRemovals)
                }
            }
            .padding()
        }
    }

    private func powerBaseSection(_ base: PowerBase) -> some View {
        let modules = snapshot.chainOrderedModules(on: base)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                PowerBaseHeader(
                    base: base, isCurrentStateVerified: appModel.isPowerBaseStateVerified,
                    removal: removals.removal(for: base.hardwareIdentifier, in: snapshot)
                )
                PowerBaseManageButton(identifier: base.hardwareIdentifier)
            }
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
    @Environment(PowerBaseRemovalController.self) private var removals
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
            removalRowsSection
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
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label {
                                Text(verbatim: base.shortLabel)
                            } icon: {
                                Image(systemName: "powerplug.fill")
                            }
                            Text(PowerBaseConnectionText.summary(of: base))
                                .font(.caption)
                                .foregroundStyle(appModel.isPowerBaseStateVerified && !base.isOnline ? Color.red : Color.secondary)
                            PowerBaseRemovalBadge(removal: removals.removal(for: base.hardwareIdentifier, in: snapshot))
                        }
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: 0)
                        PowerBaseManageButton(identifier: base.hardwareIdentifier)
                    }
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
            removalRowsSection
        }
    }

    /// Removal jobs of Bases the hub no longer lists that are still under way: shown, so a job the
    /// user started never just vanishes. A completed one leaves the list.
    @ViewBuilder
    private var removalRowsSection: some View {
        let pending = PowerBaseManagementPresentation.openRemovalsWithoutPowerBase(in: snapshot)
        if !pending.isEmpty {
            Section {
                ForEach(pending) { removal in
                    PowerBaseRemovalRow(removal: removal)
                }
            } header: {
                Text(verbatim: PowerBaseManagementText.listHeader)
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
    /// The Base's removal job, when the list shows one ("삭제 대기", …).
    var removal: PowerBaseRemoval? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconCircle(systemName: "powerplug.fill", diameter: 34, background: isCurrentStateVerified && base.isOnline ? .indigo : .gray)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: base.shortLabel)
                    .font(.title3.weight(.semibold))
                Text(PowerBaseConnectionText.summary(of: base))
                    .font(.caption)
                    .foregroundStyle(isCurrentStateVerified && !base.isOnline ? Color.red : Color.secondary)
                PowerBaseRemovalBadge(removal: removal)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One removal job of a Base the hub no longer lists, as a row that opens its management sheet.
struct PowerBaseRemovalRow: View {
    let removal: PowerBaseRemoval
    @Environment(DeviceActions.self) private var actions: DeviceActions?

    var body: some View {
        Button {
            actions?.managingPowerBase = PowerBaseManagementTarget(identifier: removal.powerBaseIdentifier)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: PowerBaseManagementPresentation.label(forIdentifier: removal.powerBaseIdentifier))
                        .foregroundStyle(.primary)
                    PowerBaseRemovalBadge(removal: removal)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// The same rows for the card layout, under their own title.
struct PowerBaseRemovalCards: View {
    let removals: [PowerBaseRemoval]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: PowerBaseManagementText.listHeader)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            ForEach(removals) { removal in
                PowerBaseRemovalRow(removal: removal)
                    .padding(PogoTheme.cardPadding)
                    .background(PogoTheme.tile, in: RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    /// The name stands apart from what describes it. The gap is on the room's line, not a spacing
    /// of the stack: each text still takes its own lines, and the gap grows with the text size.
    @ScaledMetric(relativeTo: .caption) private var nameGap: CGFloat = 6
    /// Between the room, the chain position and the status: a wrapped line stays with its own.
    @ScaledMetric(relativeTo: .caption) private var detailGap: CGFloat = 2

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
                .padding(.top, nameGap)
            if let connectionText {
                Text(connectionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, detailGap)
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(isCurrentStateVerified && !module.isOnline ? Color.red : Color.secondary)
                .lineLimit(2)
                .padding(.top, detailGap)
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
