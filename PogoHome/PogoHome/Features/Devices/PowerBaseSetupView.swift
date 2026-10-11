import SwiftUI
import PowerBaseBLEKit

/// What the user entered on "Power Base 추가". Kept in memory by the screen only: the setup code
/// is never stored, copied or logged, and is dropped with the screen (and as soon as the hub
/// confirmed the registration).
struct PowerBaseSetupForm: Equatable {
    /// Bluetooth is in use for this screen: the search began -- by itself when the screen was
    /// entered, or with the "find" button where it could not. From then on the list is shown.
    var didStartFinding = false
    var selectedBoardID: UUID?
    /// The setup code and, when it came from a QR code or from the screen before, the one board
    /// it belongs to.
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

    /// The form the screen starts with when "다른 허브에 연결하기" hands over the code it
    /// authenticated a board with: the code waits, bound to that board, and shows up only if
    /// that board is the one picked here.
    static func starting(with handoff: PowerBaseSetupCodeHandoff?) -> PowerBaseSetupForm {
        var form = PowerBaseSetupForm()
        if let handoff { form.code = PowerBaseSetupCodeField(handoff: handoff) }
        return form
    }
}

/// The product "Power Base 추가" screen: pick the hub's unregistered Power Base found over
/// Bluetooth, enter its setup code, and register it.
///
/// Everything that matters is decided by `PowerBaseEnrollmentBLEController` (the same controller,
/// transport, Bluetooth lifecycle and Security 2 code the DEBUG test uses), here with
/// `requireManagement`: the board is authenticated with the setup code before the hub is asked for
/// anything, the hub's address and its management credential travel from the hub to the board
/// without ever being shown, and the only success is the hub's own `heartbeat_received`.
///
/// This view never asks for an EUI-64, an address, a port or a PSKd, and shows none of them.
struct PowerBaseSetupView: View {
    /// The setup code the screen that led here ("다른 허브에 연결하기") authenticated a board
    /// with, and that board. Handed over in memory only. The field starts with it when the user
    /// picks that same board here, and the user can change it; for any other board it is
    /// dropped. `nil`: the field starts empty, as before.
    var initialSetupCode: PowerBaseSetupCodeHandoff?
    /// Replaced in tests and previews.
    var makeController: () -> PowerBaseEnrollmentBLEController = {
        PowerBaseEnrollmentBLEController(
            provider: PowerBaseEnrollmentBLECentral(), requireManagement: true, automaticSearch: true,
            receiptRelay: URLSessionPowerBaseRemovalTransport()
        )
    }
    /// Replaced in tests.
    var makeQRIntake: () -> PowerBaseSetupQRIntake = { PowerBaseSetupQRIntake() }
    /// What the screen starts with instead of an empty form. For tests.
    var initialForm: PowerBaseSetupForm?
    /// The user is done with the whole sheet ("기기 목록으로").
    var onFinished: () -> Void = {}

    @Environment(AppModel.self) private var appModel
    @Environment(AppNavigator.self) private var navigator: AppNavigator?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PogoSettingsKeys.selectedHub) private var selectedHubValue = ""
    @State private var controller: PowerBaseEnrollmentBLEController?
    @State private var qrIntake: PowerBaseSetupQRIntake?
    @State private var form = PowerBaseSetupForm()

    var body: some View {
        screen
            .navigationTitle(Text(verbatim: PowerBaseSetupText.screenTitle))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if controller == nil {
                    let created = makeController()
                    created.targetDidChange(target)
                    controller = created
                    qrIntake = makeQRIntake()
                    form = initialForm ?? .starting(with: initialSetupCode)
                }
                // The background first: a screen that appears while the app is away must not
                // start looking. Then the appearance -- which is where the controller begins to
                // look for boards by itself (once; a screen that is only rebuilt, or comes back
                // from under the QR camera, starts nothing again). Here, on the screen: never on
                // a list row.
                if scenePhase == .background {
                    controller?.sceneDidEnterBackground()
                    qrIntake?.sceneDidEnterBackground()
                }
                controller?.screenDidAppear()
                qrIntake?.hubDidChange(target.hubID)
                qrIntake?.screenDidAppear()
                if controller?.usesBluetooth == true { form.didStartFinding = true }
            }
            // The search began (now, or later: back in the foreground, a hub that can be used
            // at last): the list takes the place of the "find" button.
            .onChange(of: controller?.usesBluetooth) { _, uses in
                if uses == true { form.didStartFinding = true }
            }
            // The screen, not a row: list rows come and go while scrolling. A view that is only
            // rebuilt disappears and appears again at once, which the controller does not take
            // for leaving. Reading a QR code has nothing to clean up, so it simply ends.
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
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    controller?.sceneDidEnterBackground()
                    qrIntake?.sceneDidEnterBackground()
                case .active:
                    controller?.sceneDidBecomeActive()
                    qrIntake?.sceneDidBecomeActive()
                default: break
                }
            }
            .onChange(of: controller?.phase) { _, phase in
                // Confirmed by the hub: the code has done its job.
                if case let .finished(outcome)? = phase, outcome.session.state == .heartbeatReceived {
                    form.setupCode = ""
                }
            }
    }

    @ViewBuilder
    private var screen: some View {
        let list = List {
            if let controller, let qrIntake {
                PowerBaseSetupContent(
                    controller: controller, form: $form, hubName: hubName, qr: qrIntake,
                    onOpenSettings: {
                        navigator?.selectedTab = .settings
                        onFinished()
                    },
                    onFinished: onFinished
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
        controller.flatMap { PowerBaseSetupPresentation.qrTarget(controller: $0, form: form) }
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

/// The screen's sections. Separate from the owner above so every state can be rendered in a test.
struct PowerBaseSetupContent: View {
    let controller: PowerBaseEnrollmentBLEController
    @Binding var form: PowerBaseSetupForm
    let hubName: String?
    /// Reads the selected board's QR code into the setup code field, and nothing else.
    let qr: PowerBaseSetupQRIntake
    var onOpenSettings: () -> Void = {}
    var onFinished: () -> Void = {}

    private typealias T = PowerBaseSetupText

    var body: some View {
        hubSection
        if controller.ineligibility == nil {
            if let result = PowerBaseSetupPresentation.result(of: controller.phase) {
                resultSections(result)
            } else if controller.isBusy {
                progressSection
            } else {
                findSection
                if form.didStartFinding, selectedBoard != nil {
                    codeSection
                }
            }
        }
    }

    // MARK: Hub

    private var hubSection: some View {
        Section {
            if let reason = controller.ineligibility {
                SheetIconRow(systemImage: "exclamationmark.triangle.fill", iconStyle: .orange) {
                    Text(verbatim: T.hubMessage(reason))
                        .sheetParagraph()
                }
                .accessibilityElement(children: .combine)
                Button(action: onOpenSettings) {
                    SheetIconRow(systemImage: "gearshape") {
                        Text(verbatim: T.openSettings)
                    }
                }
            } else {
                SheetIconRow(systemImage: "server.rack", iconStyle: .tint) {
                    Text(verbatim: hubName ?? "")
                        .sheetParagraph()
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text(verbatim: T.hubHeader)
        } footer: {
            if controller.ineligibility == nil {
                Text(verbatim: T.hubFooter).sheetFooter()
            }
        }
        .sheetRowInsets()
    }

    // MARK: Finding and choosing

    private var boards: [PowerBaseBLEDiscoveredBoard] { PowerBaseSetupPresentation.selectableBoards(controller.boards) }

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
                    controller.activate()
                    controller.startScanning()
                } label: {
                    SheetIconRow(systemImage: "dot.radiowaves.left.and.right") {
                        Text(verbatim: T.startFinding)
                    }
                }
            } else if let bluetooth = T.bluetoothMessage(controller.availability) {
                SheetIconRow(systemImage: "antenna.radiowaves.left.and.right.slash", iconStyle: .orange) {
                    Text(verbatim: bluetooth).sheetParagraph()
                }
                .accessibilityElement(children: .combine)
                if controller.availability == .denied {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        SheetIconRow(systemImage: "gearshape") { Text(verbatim: T.openSettings) }
                    }
                }
            } else {
                ForEach(boards) { board in
                    boardRow(board)
                }
                if boards.isEmpty {
                    PowerBaseSearchStatusRow(
                        isSearching: controller.isScanning, foundNothingSoFar: controller.foundNothingSoFar,
                        searching: T.finding, nothingFound: T.nothingFound, stillSearching: T.stillFinding, paused: T.findingPaused
                    )
                }
                Button {
                    form.select(nil)
                    controller.startScanning()
                } label: {
                    SheetIconRow(systemImage: "arrow.clockwise") { Text(verbatim: T.findAgain) }
                }
            }
        } header: {
            Text(verbatim: T.findHeader)
        } footer: {
            // Looking starts by itself; the "find" button is only what is left when it could not.
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
                Text(verbatim: PowerBaseSetupPresentation.label(forAdvertisedEUI64: board.advertisedEUI64 ?? ""))
                    .foregroundStyle(.primary)
                Text(verbatim: T.signal(board.rssi))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Setup code

    /// The code to send: never one that is known to belong to another board than the selected.
    private var normalizedCode: String? { form.code.codeForSelectedBoard.flatMap(PowerBaseSetupCode.normalized) }

    private var canRegister: Bool {
        selectedBoard?.advertisedEUI64 != nil && normalizedCode != nil && controller.canStart
    }

    private var qrTarget: PowerBaseSetupQRIntake.Target? { PowerBaseSetupPresentation.qrTarget(controller: controller, form: form) }

    @ViewBuilder
    private var codeSection: some View {
        Section {
            PowerBaseSetupCodeEntry(field: $form.code, qrTarget: qrTarget, qr: qr)
        } header: {
            Text(verbatim: T.codeHeader)
        } footer: {
            Text(verbatim: T.codeFooter).sheetFooter()
        }
        .sheetRowInsets()

        // A section of its own: a prominent button inside the card above would cut the card.
        Section {
            Button {
                guard let board = selectedBoard, let eui64 = board.advertisedEUI64, let code = form.code.codeForSelectedBoard else { return }
                // The advertised EUI-64 is only whom to try: the controller authenticates the
                // board with the setup code and compares the board's own word before the hub
                // is asked for anything. That holds for a code read from a QR code just the same.
                controller.start(boardID: board.id, expectedEUI64: eui64, setupCode: code)
            } label: {
                Text(verbatim: T.register)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canRegister)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    // MARK: Progress

    private var progressSection: some View {
        let current = PowerBaseSetupPresentation.stage(phase: controller.phase, boardProgress: controller.boardProgress)
        return Section {
            ForEach(PowerBaseSetupStage.allCases, id: \.self) { stage in
                stageRow(stage, current: current)
            }
            if let detail = T.progressDetail(phase: controller.phase, boardProgress: controller.boardProgress) {
                Text(verbatim: detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .sheetParagraph()
            }
            if controller.isSuspended {
                hint(T.backgroundHint)
            } else if controller.pollProblem != nil {
                hint(T.hubProblemHint)
            }
            if controller.phase == .hubUncertain {
                Button {
                    controller.askHubAgain()
                } label: {
                    SheetIconRow(systemImage: "arrow.clockwise") { Text(verbatim: T.askHubAgain) }
                }
            }
            if controller.canCancel {
                Button(role: .cancel) {
                    controller.cancel()
                } label: {
                    SheetIconRow(systemImage: "xmark.circle") { Text(verbatim: T.cancel) }
                }
            }
        } header: {
            Text(verbatim: T.progressHeader)
        }
        .sheetRowInsets()
    }

    private func stageRow(_ stage: PowerBaseSetupStage, current: PowerBaseSetupStage?) -> some View {
        // A run only exists once a board was found and picked, so "찾는 중" is always behind it.
        let position = current?.rawValue ?? PowerBaseSetupStage.verifyingBoard.rawValue
        let isDone = stage.rawValue < position
        let isCurrent = stage.rawValue == position
        return SheetIconRow {
            if isCurrent {
                SheetRowProgress()
            } else {
                SymbolIcon(systemImage: isDone ? "checkmark.circle.fill" : "circle", style: AnyShapeStyle(isDone ? Color.green : Color.secondary))
            }
        } content: {
            Text(verbatim: T.stageTitle(stage))
                .foregroundStyle(isDone || isCurrent ? .primary : .secondary)
                .fontWeight(isCurrent ? .semibold : .regular)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? [.updatesFrequently] : [])
    }

    private func hint(_ text: String) -> some View {
        SheetIconRow(systemImage: "info.circle", iconStyle: .secondary) {
            Text(verbatim: text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .sheetParagraph()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Result

    @ViewBuilder
    private func resultSections(_ result: PowerBaseSetupPresentation.Result) -> some View {
        Section {
            SheetIconRow(systemImage: resultSymbol(result), iconStyle: resultStyle(result)) {
                Text(verbatim: T.resultTitle(result))
                    .font(.headline)
                    .sheetParagraph()
                Text(verbatim: T.resultMessage(result))
                    .sheetParagraph()
            }
            .accessibilityElement(children: .combine)
        }
        .sheetRowInsets()

        if result == .registered {
            Section {
                SheetIconRow(systemImage: "sensor.fill", iconStyle: .tint) {
                    Text(verbatim: T.nextSensors).sheetParagraph()
                }
                .accessibilityElement(children: .combine)
            } header: {
                Text(verbatim: T.nextHeader)
            }
            .sheetRowInsets()

            Section {
                Button(action: onFinished) {
                    Text(verbatim: T.backToDevices)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        } else {
            Section {
                // A new attempt is a new run: a new hub session, a new request id and a new
                // one-time code. Nothing of the ended run is reused.
                Button {
                    form.select(nil)
                    controller.acknowledgeResult()
                    if form.didStartFinding {
                        controller.activate()
                        controller.startScanning()
                    }
                } label: {
                    SheetIconRow(systemImage: "arrow.clockwise") { Text(verbatim: T.retry) }
                }
                Button(action: onFinished) {
                    SheetIconRow(systemImage: "list.bullet") { Text(verbatim: T.backToDevices) }
                }
            }
            .sheetRowInsets()
        }
    }

    private func resultSymbol(_ result: PowerBaseSetupPresentation.Result) -> String {
        switch result {
        case .registered: return "checkmark.circle.fill"
        case .partlyDone: return "questionmark.circle.fill"
        case .notRegistered: return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        }
    }

    private func resultStyle(_ result: PowerBaseSetupPresentation.Result) -> AnyShapeStyle {
        switch result {
        case .registered: return AnyShapeStyle(Color.green)
        case .partlyDone: return AnyShapeStyle(Color.orange)
        case .notRegistered: return AnyShapeStyle(Color.red)
        case .cancelled: return AnyShapeStyle(Color.secondary)
        }
    }
}

/// What the list says while it has no board to show, three different things: looking (a spinner),
/// nothing found after a while (what to check -- and that it is still looking), and not looking
/// right now (the app was away, or the search was stopped). Shared by the screens that look for a
/// board over Bluetooth.
struct PowerBaseSearchStatusRow: View {
    let isSearching: Bool
    let foundNothingSoFar: Bool
    let searching: String
    let nothingFound: String
    let stillSearching: String
    let paused: String

    var body: some View {
        if isSearching, foundNothingSoFar {
            SheetIconRow(systemImage: "exclamationmark.magnifyingglass", iconStyle: .orange) {
                Text(verbatim: nothingFound).sheetParagraph()
                Text(verbatim: stillSearching)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .sheetParagraph()
            }
            .accessibilityElement(children: .combine)
        } else if isSearching {
            SheetIconRow {
                SheetRowProgress()
            } content: {
                Text(verbatim: searching).sheetParagraph()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        } else {
            SheetIconRow(systemImage: "pause.circle", iconStyle: .secondary) {
                Text(verbatim: paused).sheetParagraph()
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The setup code field with its "n / 26" hint, the paste button and the rows that read the code
/// from the selected board's QR code: shared by the screens that authenticate a board
/// (registration, moving to another hub, and confirming a removal). The code lives in the
/// caller's state only; nothing here stores or copies it.
struct PowerBaseSetupCodeEntry: View {
    @Binding var field: PowerBaseSetupCodeField
    /// The selected board, for which a QR code may be read; `nil` when there is none.
    let qrTarget: PowerBaseSetupQRIntake.Target?
    let qr: PowerBaseSetupQRIntake
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private typealias T = PowerBaseSetupText

    /// The field's text. A change of it is the user typing: a code that came from a QR code is
    /// a typed code from then on, and a QR code that was still being read is not entered over
    /// it (`PowerBaseSetupQRIntake.userTyped`). The text field writing back what it shows is no
    /// change.
    private var code: Binding<String> {
        Binding(get: { field.text }, set: { newValue in qr.userTyped(newValue, into: &field) })
    }

    var body: some View {
        // Wraps instead of cutting the code off at large text sizes. A line break is never part
        // of a code, so Return adds none; no other character is ever removed or replaced.
        TextField(text: Binding(get: { code.wrappedValue }, set: { code.wrappedValue = $0.filter { !$0.isNewline } }), axis: .vertical) {
            Text(verbatim: T.codePlaceholder)
        }
        .lineLimit(1...4)
        .font(.body.monospaced())
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .keyboardType(.asciiCapable)
        .privacySensitive()
        .accessibilityLabel(Text(verbatim: T.codeHeader))
        // Side by side, or one under the other when the text is too large for that.
        let row = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())
        row {
            Text(verbatim: T.codeProgress(PowerBaseSetupPresentation.typedSetupCodeLength(field.text)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            // Reads the pasteboard only when tapped; the app never looks at it by itself.
            PasteButton(payloadType: String.self) { strings in
                if let pasted = strings.first { qr.userPasted(pasted.trimmingCharacters(in: .whitespacesAndNewlines), into: &field) }
            }
            .labelStyle(.titleAndIcon)
            .accessibilityLabel(Text(verbatim: T.paste))
        }
        PowerBaseSetupQRRows(field: $field, target: qrTarget, intake: qr)
    }
}
