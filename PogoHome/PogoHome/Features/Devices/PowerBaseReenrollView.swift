import SwiftUI
import PowerBaseBLEKit

/// What the user entered on "다른 허브에 연결하기". In memory only, like the registration screen's
/// form: the setup code is never stored, copied or logged, and is dropped with the screen.
struct PowerBaseReenrollForm: Equatable {
    /// Bluetooth is in use for this screen: the search began -- by itself when the screen was
    /// entered, or with the "find" button where it could not. From then on the list is shown.
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

    /// The user picked `board` in the list (`nil`: the selection is gone). A code that belongs
    /// to another board does not come along.
    mutating func select(_ board: PowerBaseBLEDiscoveredBoard?) {
        selectedBoardID = board?.id
        code.select(boardEUI64: board?.advertisedEUI64)
    }
}

/// "다른 허브에 연결하기": moves a registered Power Base to another hub without its old hub and
/// without a computer.
///
/// The first half -- authenticating the board and, after an explicit confirmation, having it erase
/// its own registration -- is `PowerBaseLocalResetController`, which talks to the board only. The
/// second half is the ordinary registration screen (`PowerBaseSetupView`), which this screen opens
/// when the board is verified to hold no registration; there the only success is the new hub's own
/// `heartbeat_received`.
///
/// This view never asks for an EUI-64, an address, a key or a PSKd, and shows none of them.
struct PowerBaseReenrollView: View {
    /// Replaced in tests and previews.
    var makeController: () -> PowerBaseLocalResetController = {
        PowerBaseLocalResetController(provider: PowerBaseEnrollmentBLECentral(), automaticSearch: true)
    }
    /// Replaced in tests.
    var makeQRIntake: () -> PowerBaseSetupQRIntake = { PowerBaseSetupQRIntake() }
    /// What the screen starts with instead of an empty form. For tests.
    var initialForm: PowerBaseReenrollForm?
    /// The user is done with the whole sheet.
    var onFinished: () -> Void = {}

    @Environment(AppModel.self) private var appModel
    @Environment(AppNavigator.self) private var navigator: AppNavigator?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PogoSettingsKeys.selectedHub) private var selectedHubValue = ""
    @State private var controller: PowerBaseLocalResetController?
    @State private var qrIntake: PowerBaseSetupQRIntake?
    @State private var form = PowerBaseReenrollForm()
    @State private var showsRegistration = false

    var body: some View {
        screen
            .navigationTitle(Text(verbatim: PowerBaseReenrollText.entryTitle))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showsRegistration) {
                // The ordinary registration, with the code the board was authenticated with here
                // (in memory only) -- for that board and no other. It finds, authenticates and
                // registers the board by its own rules.
                PowerBaseSetupView(
                    initialSetupCode: PowerBaseReenrollPresentation.handoff(code: form.code, authenticatedBoard: controller?.boardIdentifier),
                    onFinished: onFinished
                )
            }
            .onAppear {
                if controller == nil {
                    let created = makeController()
                    created.targetDidChange(target)
                    controller = created
                    qrIntake = makeQRIntake()
                    if let initialForm { form = initialForm }
                }
                qrIntake?.hubDidChange(target.hubID)
                qrIntake?.screenDidAppear()
                // The scene phase first: a screen that appears while the app is in the background
                // must not start looking. Then the appearance -- where the controller begins to
                // look for boards by itself (once; a screen that is only rebuilt, or comes back
                // from under the QR camera, starts nothing again). Looking opens no BOOT window
                // and resets nothing. Here, on the screen: never on a list row.
                PowerBaseReenrollScene.apply(scenePhase, to: controller, qr: qrIntake)
                controller?.screenDidAppear()
                if controller?.usesBluetooth == true { form.didStartFinding = true }
            }
            // The search began (now, or later: back in the foreground): the list takes the place
            // of the "find" button.
            .onChange(of: controller?.usesBluetooth) { _, uses in
                if uses == true { form.didStartFinding = true }
            }
            // Leaving ends the connection at once. A command that was only scheduled is not sent;
            // one that was sent stays "outcome unknown" (the controller decides which). The search
            // ends when the screen has really gone.
            .onDisappear {
                controller?.screenDidDisappear()
                qrIntake?.screenDidDisappear()
            }
            .onChange(of: target) { _, target in
                controller?.targetDidChange(target)
                qrIntake?.hubDidChange(target.hubID)
            }
            // Here, on the screen itself, not on a list row: what a QR code may be read for
            // follows the selection and the run, whichever rows happen to be drawn.
            .onChange(of: qrTarget, initial: true) { _, target in qrIntake?.targetDidChange(target) }
            .onChange(of: scenePhase) { _, phase in PowerBaseReenrollScene.apply(phase, to: controller, qr: qrIntake) }
    }

    @ViewBuilder
    private var screen: some View {
        let list = List {
            if let controller, let qrIntake {
                PowerBaseReenrollContent(
                    state: PowerBaseReenrollScreenState(controller: controller, hubName: hubName),
                    form: $form,
                    qr: qrIntake,
                    actions: PowerBaseReenrollActions(
                        startFinding: {
                            controller.activate()
                            controller.startScanning()
                        },
                        findAgain: { controller.startScanning() },
                        verify: { boardID, eui64, code in controller.verify(boardID: boardID, expectedEUI64: eui64, setupCode: code) },
                        confirmReset: { controller.confirmReset() },
                        declineConfirmation: { controller.declineConfirmation() },
                        acknowledge: { controller.acknowledgeResult() },
                        register: { showsRegistration = true },
                        openSettings: {
                            navigator?.selectedTab = .settings
                            onFinished()
                        }
                    )
                )
            }
        }
        .sheetListSpacing()
        if PlatformSupport.isMacCatalyst {
            list.sheetCloseAction { dismiss() }
        } else {
            list
        }
    }

    private var target: PowerBaseHubTarget { PowerBaseHubTarget(appModel: appModel) }

    private var qrTarget: PowerBaseSetupQRIntake.Target? {
        controller.flatMap { PowerBaseReenrollPresentation.qrTarget(state: PowerBaseReenrollScreenState(controller: $0, hubName: nil), form: form) }
    }

    /// The hub's readable name as it was when the user picked it in "Find hubs".
    private var hubName: String? {
        guard let hubID = target.hubID else { return nil }
        if let selected = SelectedHub(storedValue: selectedHubValue), selected.hubID == hubID, !selected.serviceName.isEmpty {
            return selected.serviceName
        }
        return PowerBaseSetupText.hubFallbackName(hubID: hubID)
    }
}

/// What a scene phase means for a run, the same way the registration screen reads it:
/// `background` holds every new command back, `active` lets them go on, and `inactive` (the app
/// switcher, a system alert, the confirmation dialog) changes nothing.
enum PowerBaseReenrollScene {
    @MainActor
    static func apply(_ phase: ScenePhase, to controller: PowerBaseLocalResetController?, qr: PowerBaseSetupQRIntake? = nil) {
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

/// What the screen's buttons do. Plain closures, so the sections can be rendered in a test without
/// a controller.
struct PowerBaseReenrollActions {
    var startFinding: () -> Void = {}
    var findAgain: () -> Void = {}
    var verify: (_ boardID: UUID, _ eui64: String, _ setupCode: String) -> Void = { _, _, _ in }
    var confirmReset: () -> Void = {}
    var declineConfirmation: () -> Void = {}
    var acknowledge: () -> Void = {}
    var register: () -> Void = {}
    var openSettings: () -> Void = {}
}

/// The screen's sections, drawn from a plain state so that every state can be rendered in a test.
struct PowerBaseReenrollContent: View {
    let state: PowerBaseReenrollScreenState
    @Binding var form: PowerBaseReenrollForm
    /// Reads the selected board's QR code into the setup code field, and nothing else.
    let qr: PowerBaseSetupQRIntake
    var actions = PowerBaseReenrollActions()

    @State private var asksFinalConfirmation = false

    private typealias T = PowerBaseReenrollText
    private typealias S = PowerBaseSetupText
    private typealias P = PowerBaseReenrollPresentation

    var body: some View {
        introSection
        hubSection
        switch state.phase {
        case .idle:
            buttonSection
            findSection
            if form.didStartFinding, selectedBoard != nil { codeSection }
        case .connecting, .checking, .resetting:
            progressSection
        case .awaitingConfirmation:
            progressSection
            confirmationSection
        case let .uncertain(uncertainty):
            uncertainSection(uncertainty)
            findSection
            if form.didStartFinding, selectedBoard != nil { codeSection }
        case let .ready(ready):
            readySections(ready)
        case let .failed(failure):
            failedSections(failure)
        }
    }

    // MARK: Introduction and the new hub

    private var introSection: some View {
        Section {
            SheetIconRow(systemImage: "arrow.triangle.swap", iconStyle: .tint) {
                Text(verbatim: T.intro).sheetParagraph()
            }
            .accessibilityElement(children: .combine)
        } footer: {
            Text(verbatim: T.introFooter).sheetFooter()
        }
        .sheetRowInsets()
    }

    private var hubSection: some View {
        Section {
            if let reason = state.hubIneligibility {
                SheetIconRow(systemImage: "exclamationmark.triangle.fill", iconStyle: .orange) {
                    Text(verbatim: T.hubNotReady)
                        .font(.headline)
                        .sheetParagraph()
                    Text(verbatim: S.hubMessage(reason)).sheetParagraph()
                    Text(verbatim: T.hubNotReadyConsequence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .sheetParagraph()
                }
                .accessibilityElement(children: .combine)
                Button(action: actions.openSettings) {
                    SheetIconRow(systemImage: "gearshape") { Text(verbatim: S.openSettings) }
                }
            } else {
                SheetIconRow(systemImage: "server.rack", iconStyle: .tint) {
                    Text(verbatim: state.hubName ?? "").sheetParagraph()
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text(verbatim: T.hubHeader)
        } footer: {
            if state.hubIneligibility == nil {
                Text(verbatim: T.hubReadyFooter).sheetFooter()
            }
        }
        .sheetRowInsets()
    }

    // MARK: The BOOT button

    private var buttonSection: some View {
        Section {
            numberedStep(1, T.buttonStep1)
            numberedStep(2, T.buttonStep2)
            numberedStep(3, T.buttonStep3)
        } header: {
            Text(verbatim: T.buttonHeader)
        } footer: {
            Text(verbatim: T.buttonFooter).sheetFooter()
        }
        .sheetRowInsets()
    }

    private func numberedStep(_ number: Int, _ text: String) -> some View {
        SheetIconRow {
            Text(verbatim: "\(number)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.tint)
        } content: {
            Text(verbatim: text).sheetParagraph()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Finding and choosing

    private var boards: [PowerBaseBLEDiscoveredBoard] { P.selectableBoards(state) }

    private var selectedBoard: PowerBaseBLEDiscoveredBoard? {
        boards.first { $0.id == form.selectedBoardID }
    }

    @ViewBuilder
    private var findSection: some View {
        Section {
            if !form.didStartFinding {
                // Only where the search did not start by itself (the screen appeared while the
                // app was in the background, or a test drives it by hand).
                Button {
                    form.didStartFinding = true
                    actions.startFinding()
                } label: {
                    SheetIconRow(systemImage: "dot.radiowaves.left.and.right") { Text(verbatim: T.startFinding) }
                }
            } else if let bluetooth = S.bluetoothMessage(state.availability) {
                SheetIconRow(systemImage: "antenna.radiowaves.left.and.right.slash", iconStyle: .orange) {
                    Text(verbatim: bluetooth).sheetParagraph()
                }
                .accessibilityElement(children: .combine)
                if state.availability == .denied {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        SheetIconRow(systemImage: "gearshape") { Text(verbatim: S.openSettings) }
                    }
                }
            } else {
                ForEach(boards) { board in
                    boardRow(board)
                }
                if boards.isEmpty {
                    PowerBaseSearchStatusRow(
                        isSearching: state.isScanning, foundNothingSoFar: state.foundNothingSoFar,
                        searching: T.finding, nothingFound: T.nothingFound, stillSearching: S.stillFinding, paused: S.findingPaused
                    )
                }
                Button {
                    form.select(nil)
                    actions.findAgain()
                } label: {
                    SheetIconRow(systemImage: "arrow.clockwise") { Text(verbatim: S.findAgain) }
                }
            }
        } header: {
            Text(verbatim: T.findHeader)
        } footer: {
            // Looking starts by itself and is only looking: it is the BOOT button that makes a
            // board show up. The "find" button is what is left when the search could not start.
            Text(verbatim: form.didStartFinding ? T.findFooter : T.startFindingHint).sheetFooter()
        }
        .sheetRowInsets()
        // Bluetooth coming (back) on restarts the search in the controller ("Automatic search"),
        // not here: a list row's own change handlers come and go with the row.
    }

    private func boardRow(_ board: PowerBaseBLEDiscoveredBoard) -> some View {
        let isSelected = board.id == form.selectedBoardID
        return Button {
            form.select(board)
        } label: {
            SheetIconRow(systemImage: isSelected ? "checkmark.circle.fill" : "circle", iconStyle: isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)) {
                Text(verbatim: P.boardLabel(board.advertisedEUI64))
                    .foregroundStyle(.primary)
                Text(verbatim: S.signal(board.rssi))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Setup code

    private var canVerify: Bool {
        // Never a code that is known to belong to another board than the selected one.
        selectedBoard?.advertisedEUI64 != nil && form.code.codeForSelectedBoard.flatMap(PowerBaseSetupCode.normalized) != nil
            && state.availability == .poweredOn
    }

    private var qrTarget: PowerBaseSetupQRIntake.Target? { P.qrTarget(state: state, form: form) }

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

        // A section of its own: a prominent button inside the card above would cut the card.
        Section {
            Button {
                guard let board = selectedBoard, let eui64 = board.advertisedEUI64, let code = form.code.codeForSelectedBoard else { return }
                // Connects and checks. Erases nothing: with an unresolved request it only asks
                // what became of it.
                actions.verify(board.id, eui64, code)
            } label: {
                Text(verbatim: state.hasUnresolvedOperation ? T.checkResult : T.verify)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canVerify)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    // MARK: Progress

    private var progressSection: some View {
        let current = P.stage(of: state.phase)
        return Section {
            ForEach(PowerBaseReenrollStage.allCases, id: \.self) { stage in
                stageRow(stage, current: current)
            }
            if let detail = T.progressDetail(state.phase) {
                Text(verbatim: detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .sheetParagraph()
            }
            if state.isSuspended {
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

    private func stageRow(_ stage: PowerBaseReenrollStage, current: PowerBaseReenrollStage?) -> some View {
        let position = current?.rawValue ?? -1
        let isDone = stage.rawValue < position
        let isCurrent = stage.rawValue == position
        // The confirmation waits for the user: no spinner, it is not the app that is busy.
        let showsSpinner = isCurrent && stage != .confirming
        return SheetIconRow {
            if showsSpinner {
                SheetRowProgress()
            } else {
                SymbolIcon(
                    systemImage: isDone ? "checkmark.circle.fill" : isCurrent ? "hand.raised.circle.fill" : "circle",
                    style: AnyShapeStyle(isDone ? Color.green : isCurrent ? Color.orange : Color.secondary)
                )
            }
        } content: {
            Text(verbatim: T.stageTitle(stage))
                .foregroundStyle(isDone || isCurrent ? .primary : .secondary)
                .fontWeight(isCurrent ? .semibold : .regular)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(showsSpinner ? [.updatesFrequently] : [])
    }

    // MARK: The confirmation

    @ViewBuilder
    private var confirmationSection: some View {
        Section {
            SheetIconRow(systemImage: "exclamationmark.triangle.fill", iconStyle: .orange) {
                Text(verbatim: T.confirmTitle(P.boardLabel(state.boardIdentifier)))
                    .font(.headline)
                    .sheetParagraph()
                Text(verbatim: T.confirmExplanation).sheetParagraph()
                Text(verbatim: T.confirmOldHubRemains).sheetParagraph()
                if state.hubIneligibility != nil {
                    Text(verbatim: T.hubNotReadyConsequence).sheetParagraph()
                }
                if state.windowSecondsLeft > 0 {
                    Text(verbatim: T.confirmTimeLeft(state.windowSecondsLeft))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .sheetParagraph()
                }
            }
            .accessibilityElement(children: .combine)
        }
        .sheetRowInsets()

        Section {
            // Not the erase itself: it opens the final question.
            Button(role: .destructive) {
                asksFinalConfirmation = true
            } label: {
                SheetIconRow(systemImage: "trash", iconStyle: .red) { Text(verbatim: T.eraseButton) }
            }
            .confirmationDialog(Text(verbatim: T.dialogTitle), isPresented: $asksFinalConfirmation, titleVisibility: .visible) {
                Button(role: .destructive, action: actions.confirmReset) {
                    Text(verbatim: T.dialogConfirm)
                }
                Button(role: .cancel) {} label: {
                    Text(verbatim: T.dialogCancel)
                }
            } message: {
                Text(verbatim: T.dialogMessage)
            }
            Button(action: actions.declineConfirmation) {
                SheetIconRow(systemImage: "xmark.circle") { Text(verbatim: T.declineButton) }
            }
        }
        .sheetRowInsets()
    }

    // MARK: Results

    @ViewBuilder
    private func uncertainSection(_ uncertainty: PowerBaseLocalResetController.Uncertainty) -> some View {
        Section {
            SheetIconRow(systemImage: "questionmark.circle.fill", iconStyle: .orange) {
                Text(verbatim: T.uncertainTitle(uncertainty))
                    .font(.headline)
                    .sheetParagraph()
                Text(verbatim: T.uncertainMessage(uncertainty)).sheetParagraph()
                Text(verbatim: T.uncertainGuide).sheetParagraph()
            }
            .accessibilityElement(children: .combine)
        }
        .sheetRowInsets()
    }

    @ViewBuilder
    private func readySections(_ ready: PowerBaseLocalResetController.Ready) -> some View {
        Section {
            SheetIconRow(systemImage: "checkmark.circle.fill", iconStyle: .green) {
                Text(verbatim: T.readyTitle(ready))
                    .font(.headline)
                    .sheetParagraph()
                Text(verbatim: T.readyMessage(ready)).sheetParagraph()
            }
            .accessibilityElement(children: .combine)
        }
        .sheetRowInsets()

        Section {
            Button(action: actions.register) {
                Text(verbatim: T.registerNext)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // The registration screen itself says what a hub that is not ready needs; this
            // button is only offered when there is a hub to register with.
            .disabled(state.hubIneligibility != nil)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } footer: {
            Text(verbatim: T.registerNextFooter).sheetFooter()
        }
    }

    @ViewBuilder
    private func failedSections(_ failure: PowerBaseLocalResetController.Failure) -> some View {
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
            Button {
                form.select(nil)
                actions.acknowledge()
                if form.didStartFinding { actions.startFinding() }
            } label: {
                SheetIconRow(systemImage: "arrow.clockwise") { Text(verbatim: T.retry) }
            }
        }
        .sheetRowInsets()
    }
}
