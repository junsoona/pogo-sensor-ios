import SwiftUI
import PowerBaseBLEKit

/// What the user entered on "삭제 확인". In memory only, like the registration screen's form.
struct PowerBaseReleaseConfirmationForm: Equatable {
    /// Bluetooth is used only from the moment the user asks to look for the board.
    var didStartFinding = false
    var selectedBoardID: UUID?
    /// The setup code and, when it came from a QR code, the one board it belongs to.
    var code = PowerBaseSetupCodeField()

    init(didStartFinding: Bool = false, selectedBoardID: UUID? = nil, setupCode: String = "") {
        self.didStartFinding = didStartFinding
        self.selectedBoardID = selectedBoardID
        code = PowerBaseSetupCodeField(typed: setupCode)
    }

    /// What the field shows. Setting it is the user typing.
    var setupCode: String {
        get { code.text }
        set { code.edit(newValue) }
    }

    /// `board` is the selection (`nil`: the selection is gone). A code that belongs to another
    /// board does not come along.
    mutating func select(_ board: PowerBaseBLEDiscoveredBoard?) {
        selectedBoardID = board?.id
        code.select(boardEUI64: board?.advertisedEUI64)
    }
}

/// "삭제 확인": completes the removal of a Power Base that has released its registration, by
/// reading the board's release receipt over Bluetooth and handing it to the hub.
///
/// Everything that matters is decided by `PowerBaseReleaseConfirmationController` and, in the
/// end, by the hub: this screen shows "삭제 완료" only when the hub answered `completed`. The owner
/// is handed that answer (`onConfirmed`) and closes the screen with it; the "삭제 완료" section and
/// its button are what is shown should the screen stay.
struct PowerBaseReleaseConfirmationView: View {
    let powerBaseIdentifier: String
    /// What the hub knew of the removal when this screen was opened: only the explanation differs.
    var origin = PowerBaseReleaseConfirmationOrigin.released
    var makeController: () -> PowerBaseReleaseConfirmationController
    /// Replaced in tests.
    var makeQRIntake: () -> PowerBaseSetupQRIntake = { PowerBaseSetupQRIntake() }
    /// What the screen starts with instead of an empty form. For tests.
    var initialForm: PowerBaseReleaseConfirmationForm?
    /// The hub confirmed the removal: its answer, the job as completed.
    var onConfirmed: (PowerBaseRemoval) -> Void = { _ in }

    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var controller: PowerBaseReleaseConfirmationController?
    @State private var qrIntake: PowerBaseSetupQRIntake?
    @State private var form = PowerBaseReleaseConfirmationForm()

    var body: some View {
        List {
            if let controller, let qrIntake {
                PowerBaseReleaseConfirmationContent(controller: controller, form: $form, qr: qrIntake, origin: origin, onDone: { dismiss() })
            }
        }
        .sheetListSpacing()
        .navigationTitle(Text(verbatim: PowerBaseManagementText.confirmErase))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if controller == nil {
                // Created, not activated: Bluetooth is first used when the user asks to look.
                let created = makeController()
                created.targetDidChange(target)
                controller = created
                qrIntake = makeQRIntake()
                if let initialForm { form = initialForm }
            }
            qrIntake?.hubDidChange(target.hubID)
            qrIntake?.screenDidAppear()
            PowerBaseReleaseConfirmationScene.apply(scenePhase, to: controller, qr: qrIntake)
        }
        // Reading a receipt changes nothing on the board, so leaving needs no clean-up: the
        // connection just ends.
        .onDisappear {
            controller?.leave()
            qrIntake?.screenDidDisappear()
        }
        .onChange(of: target) { _, target in
            controller?.targetDidChange(target)
            qrIntake?.hubDidChange(target.hubID)
        }
        // Here, on the screen itself, not on a list row: what a QR code may be read for follows
        // the selection and the run, whichever rows happen to be drawn.
        .onChange(of: qrTarget, initial: true) { _, target in qrIntake?.targetDidChange(target) }
        // The registration flow's rule: nothing new over Bluetooth or to the hub in the background.
        .onChange(of: scenePhase) { _, phase in PowerBaseReleaseConfirmationScene.apply(phase, to: controller, qr: qrIntake) }
        .onChange(of: controller?.phase) { _, phase in
            if case let .confirmed(removal)? = phase {
                form.setupCode = ""
                onConfirmed(removal)
            }
        }
    }

    private var target: PowerBaseHubTarget { PowerBaseHubTarget(appModel: appModel) }

    private var qrTarget: PowerBaseSetupQRIntake.Target? {
        controller.flatMap { PowerBaseReleaseConfirmationContent.qrTarget(controller: $0, form: form) }
    }
}

/// What a scene phase means for a confirmation run, the same way the registration screen reads
/// it: `background` holds every new command back, `active` lets them go on, and `inactive` (the
/// app switcher, a system alert) changes nothing.
enum PowerBaseReleaseConfirmationScene {
    @MainActor
    static func apply(_ phase: ScenePhase, to controller: PowerBaseReleaseConfirmationController?, qr: PowerBaseSetupQRIntake? = nil) {
        switch phase {
        case .background:
            controller?.sceneDidEnterBackground()
            qr?.sceneDidEnterBackground()
        case .active:
            controller?.sceneDidBecomeActive()
            qr?.sceneDidBecomeActive()
        default: break
        }
    }
}

/// The screen's sections. Separate from the owner above so every state can be rendered in a test.
struct PowerBaseReleaseConfirmationContent: View {
    let controller: PowerBaseReleaseConfirmationController
    @Binding var form: PowerBaseReleaseConfirmationForm
    /// Reads the removed board's QR code into the setup code field, and nothing else.
    let qr: PowerBaseSetupQRIntake
    var origin = PowerBaseReleaseConfirmationOrigin.released
    var onDone: () -> Void = {}

    private typealias T = PowerBaseReleaseConfirmationText
    private typealias S = PowerBaseSetupText

    var body: some View {
        introSection
        if let reason = controller.ineligibility {
            Section {
                SheetIconRow(systemImage: "exclamationmark.triangle.fill", iconStyle: .orange) {
                    Text(verbatim: PowerBaseManagementText.unavailableMessage(.hubNotEligible(reason)) ?? "").sheetParagraph()
                }
                .accessibilityElement(children: .combine)
            }
            .sheetRowInsets()
        } else {
            switch controller.phase {
            case .idle:
                findSection
                if form.didStartFinding, selectedBoard != nil {
                    codeSection
                }
            case .connecting, .reading, .sendingToHub:
                progressSection
            case .confirmed:
                confirmedSection
            case let .failed(failure):
                failedSection(failure)
            }
        }
    }

    private var label: String { PowerBaseManagementPresentation.label(forIdentifier: controller.powerBaseIdentifier) }

    private var introSection: some View {
        Section {
            SheetIconRow {
                IconCircle.powerBase(diameter: 24)
            } content: {
                Text(verbatim: label)
                    .font(.headline)
                    .sheetParagraph()
                Text(verbatim: T.intro(origin)).sheetParagraph()
            }
            .accessibilityElement(children: .combine)
        } footer: {
            Text(verbatim: T.introFooter).sheetFooter()
        }
        .sheetRowInsets()
    }

    // MARK: Finding

    private var selectedBoard: PowerBaseBLEDiscoveredBoard? {
        controller.boards.first { $0.id == form.selectedBoardID }
    }

    @ViewBuilder
    private var findSection: some View {
        Section {
            if !form.didStartFinding {
                Button {
                    form.didStartFinding = true
                    controller.activate()
                    controller.startScanning()
                } label: {
                    SheetIconRow(systemImage: "dot.radiowaves.left.and.right") { Text(verbatim: T.startFinding) }
                }
            } else if let bluetooth = S.bluetoothMessage(controller.availability) {
                SheetIconRow(systemImage: "antenna.radiowaves.left.and.right.slash", iconStyle: .orange) {
                    Text(verbatim: bluetooth).sheetParagraph()
                }
                .accessibilityElement(children: .combine)
                if controller.availability == .denied {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        SheetIconRow(systemImage: "gearshape") { Text(verbatim: S.openSettings) }
                    }
                }
            } else {
                ForEach(controller.boards) { board in
                    boardRow(board)
                }
                if controller.boards.isEmpty {
                    SheetIconRow {
                        SheetRowProgress()
                    } content: {
                        Text(verbatim: T.finding).sheetParagraph()
                        if controller.foundNothingSoFar {
                            Text(verbatim: T.nothingFound)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .sheetParagraph()
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Button {
                    form.select(nil)
                    controller.startScanning()
                } label: {
                    SheetIconRow(systemImage: "arrow.clockwise") { Text(verbatim: S.findAgain) }
                }
            }
        } header: {
            Text(verbatim: T.findHeader)
        } footer: {
            if !form.didStartFinding {
                Text(verbatim: T.startFindingHint).sheetFooter()
            }
        }
        .sheetRowInsets()
        // Bluetooth came (back) on while the list is shown: look again without another tap.
        .onChange(of: controller.availability) { _, availability in
            if form.didStartFinding, availability == .poweredOn, !controller.isBusy, !controller.isScanning {
                controller.startScanning()
            }
        }
        // The removed Base is the only board offered: when it shows up it is the selection.
        .onChange(of: controller.boards.map(\.id)) { _, ids in
            if form.selectedBoardID == nil || !ids.contains(form.selectedBoardID!) {
                form.select(controller.boards.first)
            }
        }
    }

    private func boardRow(_ board: PowerBaseBLEDiscoveredBoard) -> some View {
        let isSelected = board.id == form.selectedBoardID
        return Button {
            form.select(board)
        } label: {
            SheetIconRow(systemImage: isSelected ? "checkmark.circle.fill" : "circle", iconStyle: isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)) {
                Text(verbatim: label).foregroundStyle(.primary)
                Text(verbatim: S.signal(board.rssi))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Setup code

    private var canConfirm: Bool {
        // Never a code that is known to belong to another board than the selected one.
        selectedBoard != nil && form.code.codeForSelectedBoard.flatMap(PowerBaseSetupCode.normalized) != nil && controller.canStart
    }

    private var qrTarget: PowerBaseSetupQRIntake.Target? { Self.qrTarget(controller: controller, form: form) }

    /// The board a QR code may be read for on "삭제 확인": the selected row -- which must be the
    /// Power Base this removal is about -- while the setup code field is shown. `nil`: nothing
    /// may be read.
    static func qrTarget(controller: PowerBaseReleaseConfirmationController, form: PowerBaseReleaseConfirmationForm) -> PowerBaseSetupQRIntake.Target? {
        guard controller.ineligibility == nil, controller.phase == .idle, form.didStartFinding,
              let board = controller.boards.first(where: { $0.id == form.selectedBoardID }), let eui64 = board.advertisedEUI64 else { return nil }
        return PowerBaseSetupQRIntake.Target(boardID: board.id, boardEUI64: eui64, requiredEUI64: controller.powerBaseIdentifier)
    }

    @ViewBuilder
    private var codeSection: some View {
        Section {
            PowerBaseSetupCodeEntry(field: $form.code, qrTarget: qrTarget, qr: qr)
        } header: {
            Text(verbatim: S.codeHeader)
        } footer: {
            Text(verbatim: T.codeFooter).sheetFooter()
        }
        .sheetRowInsets()

        Section {
            Button {
                guard let board = selectedBoard, let code = form.code.codeForSelectedBoard else { return }
                controller.confirm(boardID: board.id, setupCode: code)
            } label: {
                Text(verbatim: PowerBaseManagementText.confirmErase)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canConfirm)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    // MARK: Progress and results

    private var progressSection: some View {
        Section {
            ForEach(Array(T.steps.enumerated()), id: \.offset) { index, title in
                let position = T.stepIndex(of: controller.phase)
                SheetIconRow {
                    if index == position {
                        SheetRowProgress()
                    } else {
                        SymbolIcon(systemImage: index < position ? "checkmark.circle.fill" : "circle", style: AnyShapeStyle(index < position ? Color.green : Color.secondary))
                    }
                } content: {
                    Text(verbatim: title)
                        .foregroundStyle(index <= position ? .primary : .secondary)
                        .fontWeight(index == position ? .semibold : .regular)
                }
                .accessibilityElement(children: .combine)
            }
            if controller.isSuspended {
                SheetIconRow(systemImage: "info.circle", iconStyle: .secondary) {
                    Text(verbatim: T.backgroundHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .sheetParagraph()
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text(verbatim: S.progressHeader)
        }
        .sheetRowInsets()
    }

    @ViewBuilder
    private var confirmedSection: some View {
        Section {
            SheetIconRow(systemImage: "checkmark.circle.fill", iconStyle: .green) {
                Text(verbatim: PowerBaseManagementText.removalTitle(.completed))
                    .font(.headline)
                    .sheetParagraph()
                Text(verbatim: PowerBaseManagementText.removalMessage(.completed)).sheetParagraph()
            }
            .accessibilityElement(children: .combine)
        }
        .sheetRowInsets()
        Section {
            Button(action: onDone) {
                Text(verbatim: T.done)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func failedSection(_ failure: PowerBaseReleaseConfirmationController.Failure) -> some View {
        Section {
            SheetIconRow(systemImage: "xmark.circle.fill", iconStyle: .red) {
                Text(verbatim: T.failedTitle)
                    .font(.headline)
                    .sheetParagraph()
                Text(verbatim: T.failureMessage(failure)).sheetParagraph()
            }
            .accessibilityElement(children: .combine)
        }
        .sheetRowInsets()
        Section {
            if controller.canSendAgain {
                // The receipt is in hand: only the hub is missing, and no Bluetooth is needed.
                Button {
                    controller.sendAgain()
                } label: {
                    SheetIconRow(systemImage: "arrow.up.circle") { Text(verbatim: T.sendAgain) }
                }
            }
            Button {
                form.select(nil)
                controller.acknowledgeResult()
                if form.didStartFinding {
                    controller.activate()
                    controller.startScanning()
                }
            } label: {
                SheetIconRow(systemImage: "arrow.clockwise") { Text(verbatim: S.retry) }
            }
        }
        .sheetRowInsets()
    }
}

/// The wording of "삭제 확인", in the app's language.
nonisolated enum PowerBaseReleaseConfirmationText {
    typealias Failure = PowerBaseReleaseConfirmationController.Failure

    static func intro(_ origin: PowerBaseReleaseConfirmationOrigin) -> String {
        switch origin {
        case .released:
            return String(localized: "삭제가 끝났는지 아직 확인되지 않았습니다. Power Base 가까이에서 설정 코드로 확인하면 삭제가 완료됩니다.", comment: "Confirm removal: what this screen is for")
        case .resultUnknown:
            return String(localized: "허브가 삭제 결과를 확인하지 못했습니다. Power Base가 삭제를 마쳤다면 가까이에서 설정 코드로 확인해 완료할 수 있습니다. 마치지 않았다면 아무것도 바뀌지 않습니다.", comment: "Confirm removal: what this screen is for when the hub never heard the result of the removal")
        }
    }
    static var backgroundHint: String { String(localized: "앱이 다시 화면에 보이면 삭제 확인을 이어서 진행합니다.", comment: "Confirm removal: the run is paused while the app is in the background") }
    static var introFooter: String { String(localized: "확인은 Bluetooth로 하며, Power Base의 아무것도 바꾸지 않습니다.", comment: "Confirm removal: why Bluetooth is needed; reading changes nothing") }
    static var findHeader: String { String(localized: "Power Base 찾기", comment: "Confirm removal: section header of the scan") }
    static var startFinding: String { String(localized: "주변에서 이 Power Base 찾기", comment: "Confirm removal: button that starts the Bluetooth scan for the removed Power Base") }
    static var startFindingHint: String { String(localized: "버튼을 누르면 Bluetooth로 이 Power Base를 찾습니다.", comment: "Confirm removal: says that Bluetooth is only used after the button") }
    static var finding: String { String(localized: "이 Power Base를 찾는 중입니다.", comment: "Confirm removal: scanning") }
    static var nothingFound: String { String(localized: "아직 찾지 못했습니다. Power Base는 전원을 켠 뒤 15분 동안만 Bluetooth로 응답합니다. Power Base 가까이에서 전원을 껐다 켠 뒤 다시 찾아보세요.", comment: "Confirm removal: the board was not found, with what to do") }
    static var codeFooter: String { String(localized: "이 Power Base의 26자리 설정 코드를 입력하세요. 코드는 이 화면에서만 쓰이며 저장되지 않습니다.", comment: "Confirm removal: the setup code authenticates the board; it is not stored") }
    static var done: String { String(localized: "닫기", comment: "Confirm removal: leaves the screen after the hub confirmed") }
    static var failedTitle: String { String(localized: "삭제를 확인하지 못했습니다", comment: "Confirm removal: failure title") }
    static var sendAgain: String { String(localized: "허브에 다시 보내기", comment: "Confirm removal: sends the receipt that was already read to the hub again") }

    /// The steps of a run, in order.
    static var steps: [String] {
        [
            String(localized: "Power Base 확인 중", comment: "Confirm removal step: connecting and authenticating the board"),
            String(localized: "삭제 결과 읽는 중", comment: "Confirm removal step: reading the board's receipt"),
            String(localized: "허브에 전달하는 중", comment: "Confirm removal step: handing the receipt to the hub"),
        ]
    }

    static func stepIndex(of phase: PowerBaseReleaseConfirmationController.Phase) -> Int {
        switch phase {
        case .connecting: return 0
        case .reading: return 1
        case .sendingToHub: return 2
        case .idle, .confirmed, .failed: return -1
        }
    }

    static func failureMessage(_ failure: Failure) -> String {
        switch failure {
        case let .notEligible(reason):
            return PowerBaseManagementText.unavailableMessage(.hubNotEligible(reason)) ?? ""
        case .credentialUnavailable:
            return PowerBaseManagementText.failureMessage(.credentialUnavailable)
        case .invalidSetupCode:
            return String(localized: "설정 코드는 26자리(A–Z, 2–7)입니다. 다시 확인하세요.", comment: "Confirm removal failure: the code is not a setup code")
        case let .bluetooth(availability):
            return PowerBaseSetupText.bluetoothMessage(availability) ?? PowerBaseSetupText.reasonMessage(.bluetooth(availability))
        case .boardNotFound, .boardUnreachable:
            return PowerBaseSetupText.reasonMessage(.boardUnreachable)
        case .wrongSetupCode:
            return PowerBaseSetupText.reasonMessage(.wrongSetupCode)
        case .boardLocked:
            return PowerBaseSetupText.reasonMessage(.boardLocked)
        case .differentBoard:
            return String(localized: "설정 코드로 확인된 Power Base가 삭제한 Power Base와 다릅니다. 아무것도 전달하지 않았습니다.", comment: "Confirm removal failure: the authenticated board is not the removed one")
        case .boardNeedsUpdate:
            return String(localized: "이 Power Base의 펌웨어는 삭제 확인을 지원하지 않아 여기서 삭제를 완료할 수 없습니다.", comment: "Confirm removal failure: firmware without the release receipt")
        case .noReceipt:
            return String(localized: "Power Base가 아직 삭제를 마치지 못했습니다. 전원을 껐다 켠 뒤 다시 확인하세요. 그사이 다시 등록을 시작한 Power Base는 여기서 확인할 수 없습니다.", comment: "Confirm removal failure: the board has no receipt")
        case let .hub(error):
            switch error {
            case .receiptRejected, .rejected:
                return PowerBaseManagementText.requestFailureMessage(.receiptRejected)
            case .notSupported:
                return String(localized: "연결된 허브가 삭제 확인을 받는 기능을 지원하지 않습니다. 허브를 업데이트해야 합니다.", comment: "Confirm removal failure: the hub has no receipt route")
            case .unauthorized, .forbidden, .certificateMismatch:
                return PowerBaseManagementText.requestFailureMessage(.unauthorized)
            default:
                return String(localized: "Power Base는 확인했지만 허브에 전달하지 못했습니다. 허브에 연결된 뒤 '허브에 다시 보내기'를 누르세요. 이 화면을 벗어나면 처음부터 다시 확인해야 합니다.", comment: "Confirm removal failure: the receipt was read but the hub could not be reached")
            }
        }
    }
}
