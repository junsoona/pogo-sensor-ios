#if DEBUG
import PowerBaseBLEKit
import SwiftUI

/// "BLE 등록 시험", reached from `PowerBaseConnectionView` in DEBUG builds only: the tester picks an
/// unenrolled spare board found over Bluetooth, confirms the EUI-64 it should have, types that
/// board's setup code, and starts the run that `PowerBaseEnrollmentBLEController` drives. Nothing
/// starts until the tester presses the start button.
///
/// This view owns the controller for as long as the screen is on the navigation stack. It tells
/// the controller when the screen appeared or disappeared (the controller decides whether that
/// was an exit), when the source changed, and when the app went to the background.
struct PowerBaseEnrollmentBLETestView: View {
    /// What a clean-up after leaving this screen achieved, for the screen below it.
    let onCleanupReport: (PowerBaseEnrollmentBLEController.CleanupReport) -> Void
    /// The real Bluetooth and hub; a test supplies scripted ones.
    var makeController: () -> PowerBaseEnrollmentBLEController = {
        PowerBaseEnrollmentBLEController(provider: PowerBaseEnrollmentBLECentral())
    }

    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var controller: PowerBaseEnrollmentBLEController?
    @State private var form = PowerBaseEnrollmentBLEForm()

    var body: some View {
        screen
        .navigationTitle(Text("BLE 등록 시험", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: screen title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if controller == nil {
                let created = makeController()
                created.onCleanupReport = onCleanupReport
                created.targetDidChange(enrollmentTarget)
                created.activate()
                created.startScanning()
                controller = created
            }
            controller?.screenDidAppear()
            if scenePhase == .background { controller?.sceneDidEnterBackground() }
        }
        // The screen, not a row: list rows come and go while scrolling.
        .onDisappear { controller?.screenDidDisappear() }
        .onChange(of: enrollmentTarget) { _, target in controller?.targetDidChange(target) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: controller?.sceneDidEnterBackground()
            case .active: controller?.sceneDidBecomeActive()
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

    /// The list. On the Mac it also gets the sheet's own 닫기 button below it (Esc), which leaves this
    /// screen like the back button does: a Mac sheet's bar is easy to miss in a small window, and
    /// the root screen's button is not shown on a pushed screen.
    @ViewBuilder
    private var screen: some View {
        let list = List {
            if let controller {
                PowerBaseEnrollmentBLETestContent(controller: controller, form: $form)
            }
        }
        .sheetListSpacing()
        if PlatformSupport.isMacCatalyst {
            list.sheetCloseAction { dismiss() }
        } else {
            list
        }
    }

    /// The same rule as the USB test: only a hub picked in "Find hubs" that this device is paired with.
    private var enrollmentTarget: PowerBaseEnrollmentController.Target {
        PowerBaseEnrollmentController.Target(appModel: appModel)
    }
}

extension PowerBaseEnrollmentController.Target {
    /// The source the app reads now, as the enrollment tests see it.
    init(appModel: AppModel) {
        let identity = appModel.sourceIdentity
        let shared = appModel.sharedSettings
        let hubID = identity.hubID
        self.init(
            hubID: hubID,
            baseURL: hubID == nil ? nil : appModel.sourceAddress,
            isSimulated: identity.isSimulated,
            isPaired: hubID != nil && shared.hubID == hubID && shared.isPaired
        )
    }
}

/// What the tester entered. Kept in memory by the screen only; the setup code is never stored,
/// shown, copied or logged, and is dropped with the screen.
struct PowerBaseEnrollmentBLEForm: Equatable {
    var selectedBoardID: UUID?
    var expectedEUI64 = ""
    /// The tester said that `expectedEUI64` is the prepared board's value. Any change resets it.
    var confirmedEUI64 = false
    var setupCode = ""
}

/// The screen's sections. Separate from the owner above so every state can be rendered in a test.
struct PowerBaseEnrollmentBLETestContent: View {
    let controller: PowerBaseEnrollmentBLEController
    @Binding var form: PowerBaseEnrollmentBLEForm

    private typealias Texts = PowerBaseEnrollmentBLEText

    private var normalizedEUI64: String? { PowerBaseEUI64.normalized(form.expectedEUI64) }
    private var normalizedSetupCode: String? { PowerBaseSetupCode.normalized(form.setupCode) }
    private var selectedBoard: PowerBaseBLEDiscoveredBoard? { controller.boards.first { $0.id == form.selectedBoardID } }

    /// The picked row advertises another EUI-64 than the one entered.
    private var advertisedNameDiffers: Bool {
        guard let advertised = selectedBoard?.advertisedEUI64, let expected = normalizedEUI64 else { return false }
        return advertised != expected
    }

    private var canPressStart: Bool {
        controller.canStart && selectedBoard != nil && normalizedEUI64 != nil && form.confirmedEUI64 && normalizedSetupCode != nil
            && !advertisedNameDiffers
    }

    var body: some View {
        introSection
        scanSection
        identitySection
        runSection
    }

    // MARK: - Intro

    private var introSection: some View {
        Section {
            if let reason = controller.ineligibility {
                SheetIconRow(systemImage: "exclamationmark.triangle.fill", iconStyle: .orange) {
                    PowerBaseEnrollmentText.ineligibility(reason)
                        .foregroundStyle(.orange)
                        .sheetParagraph()
                }
                .accessibilityElement(children: .combine)
            }
            Text("미등록 상태의 여분 Power Base에 Bluetooth로 일회용 Thread 가입 코드(PSKd)를 전달하는 시험입니다. 보드를 설정 코드로 인증한 뒤 허브에 등록 세션을 만들고, 허브가 가입을 허용하면 보드에 코드를 전달합니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: what the test does")
                .sheetParagraph()
        } header: {
            Text("BLE 등록 시험 (DEBUG)", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: first section header")
        } footer: {
            Text("DEBUG 빌드에만 있는 시험 기능이며 출시용 등록 기능이 아닙니다. 보드 준비(시험 펌웨어와 준비 이미지 기록), 설정 코드 생성, Bridge 주소 설정은 컴퓨터에서 미리 해 두어야 합니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: scope of the test")
                .sheetFooter()
        }
        .sheetRowInsets()
    }

    // MARK: - 1. Find the board

    private var scanSection: some View {
        Section {
            if controller.availability != .poweredOn {
                SheetIconRow(systemImage: "antenna.radiowaves.left.and.right.slash", iconStyle: .orange) {
                    Texts.availability(controller.availability)
                        .foregroundStyle(.orange)
                        .sheetParagraph()
                }
                .accessibilityElement(children: .combine)
            } else if controller.isScanning && controller.boards.isEmpty {
                SheetIconRow {
                    SheetRowProgress()
                } content: {
                    if controller.foundNothingSoFar {
                        Text("아직 찾지 못했습니다. 계속 찾는 중입니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: scanning for a while without result")
                            .sheetParagraph()
                        Text("보드가 켜져 있고 가까이 있는지, 미등록 상태인지 확인하세요. 이미 등록된 보드와 전원을 켠 지 15분이 지난 보드는 Bluetooth를 열지 않습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: why no board may be found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .sheetParagraph()
                    } else {
                        Text("주변의 미등록 Power Base를 찾는 중입니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: scanning")
                            .sheetParagraph()
                    }
                }
                .accessibilityElement(children: .combine)
            } else if controller.boards.isEmpty {
                SheetIconRow(systemImage: "magnifyingglass", iconStyle: .secondary) {
                    Text("찾은 보드가 없습니다. 검색을 시작하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: not scanning, nothing found")
                        .foregroundStyle(.secondary)
                        .sheetParagraph()
                }
                .accessibilityElement(children: .combine)
            }

            ForEach(controller.boards) { board in
                boardRow(board)
            }

            if controller.availability == .poweredOn {
                Button {
                    if controller.isScanning {
                        controller.stopScanning()
                    } else {
                        controller.startScanning()
                    }
                } label: {
                    SheetIconRow(systemImage: controller.isScanning ? "stop.circle" : "arrow.clockwise") {
                        if controller.isScanning {
                            Text("검색 중지", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: stop scanning button")
                                .sheetParagraph()
                        } else {
                            Text("다시 검색", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: scan again button")
                                .sheetParagraph()
                        }
                    }
                }
                .disabled(controller.isBusy)
            }
        } header: {
            Text("1. 보드 찾기", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: scan section header")
        } footer: {
            Text("목록의 이름과 EUI-64는 보드가 광고한 값일 뿐 인증된 정보가 아닙니다. 고르는 데만 쓰입니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: scan results are hints")
                .sheetFooter()
        }
        .sheetRowInsets()
    }

    private func boardRow(_ board: PowerBaseBLEDiscoveredBoard) -> some View {
        let isSelected = board.id == form.selectedBoardID
        return Button {
            guard !controller.isBusy else { return }
            form.selectedBoardID = board.id
            // A starting point for the field below; the tester still has to confirm it.
            if let advertised = board.advertisedEUI64 { form.expectedEUI64 = advertised }
            form.confirmedEUI64 = false
        } label: {
            SheetIconRow(systemImage: isSelected ? "checkmark.circle.fill" : "circle", iconStyle: isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)) {
                if let name = board.name {
                    Text(verbatim: name)
                        .font(.body.monospaced())
                        .foregroundStyle(.primary)
                        .sheetParagraph()
                } else {
                    Text("이름 없는 보드", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: a scan result without an advertised name")
                        .foregroundStyle(.primary)
                        .sheetParagraph()
                }
                if board.advertisedEUI64 == nil {
                    Text("광고 이름에 EUI-64가 없습니다. 아래에 직접 입력하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: the advertised name carries no EUI-64")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .sheetParagraph()
                }
                Text("신호 세기 \(board.rssi) dBm", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: RSSI of a scan result")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .sheetParagraph()
            }
        }
        .disabled(controller.isBusy)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - 2. Which board, and its setup code

    private var identitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: SheetRowLayout.paragraphSpacing) {
                Text("예상 EUI-64", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: expected EUI-64 field title")
                    .font(.subheadline.weight(.semibold))
                    .sheetParagraph()
                // Vertical, so 16 digits wrap instead of being cut off at large text sizes.
                TextField(text: expectedEUI64Binding, prompt: Text(verbatim: "0123456789abcdef"), axis: .vertical) {
                    Text("EUI-64 (16자리 16진수)", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: EUI-64 field label")
                }
                .font(.body.monospaced())
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .textContentType(nil)
                .disabled(controller.isBusy)
                if !form.expectedEUI64.isEmpty && normalizedEUI64 == nil {
                    Text("16자리 16진수만 입력하세요. 구분자(:, -), *, 모두 0인 값은 쓸 수 없습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: EUI-64 validation message")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .sheetParagraph()
                } else if advertisedNameDiffers {
                    Text("선택한 보드가 광고하는 EUI-64와 다릅니다. 목록에서 맞는 보드를 고르거나 값을 확인하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: the entered EUI-64 differs from the picked row's advertised one")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .sheetParagraph()
                }
                Text("보드를 준비할 때 기록한 값(esptool read-mac)과 같아야 합니다. 이 값이 인증에 쓰이며, 인증 뒤 보드가 알려 주는 실제 EUI-64와 다르면 중단합니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: where the expected EUI-64 comes from and how it is used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .sheetParagraph()
            }

            Toggle(isOn: $form.confirmedEUI64) {
                Text("준비한 보드의 EUI-64와 같은지 확인했습니다", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: confirmation toggle for the expected EUI-64")
                    .sheetParagraph()
            }
            .disabled(controller.isBusy || normalizedEUI64 == nil)

            VStack(alignment: .leading, spacing: SheetRowLayout.paragraphSpacing) {
                Text("보드별 설정 코드", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: setup code field title")
                    .font(.subheadline.weight(.semibold))
                    .sheetParagraph()
                SecureField(text: $form.setupCode) {
                    Text("설정 코드 (26자)", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: setup code field label")
                }
                .font(.body.monospaced())
                // The keyboard offers capitals and leaves the text alone; what is sent is the text
                // with surrounding whitespace dropped and ASCII lower case raised -- nothing else.
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .textContentType(nil)
                .privacySensitive()
                .disabled(controller.isBusy)
                if !form.setupCode.isEmpty && normalizedSetupCode == nil {
                    Text("설정 코드는 A–Z와 2–7로 된 26자입니다. 지금 \(form.setupCode.trimmingCharacters(in: .whitespacesAndNewlines).count)자가 입력되었거나 쓸 수 없는 문자가 있습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: setup code validation; the argument is the number of characters typed")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .sheetParagraph()
                }
                Text("준비 도구가 이 보드용으로 만든 코드입니다. 앞뒤 공백만 지우고 소문자는 대문자로 바꿔 보냅니다. 화면에 표시하거나 저장·복사·기록하지 않으며, 이 화면을 나가면 지웁니다. Thread 가입 코드(PSKd)와는 다른 값입니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: how the setup code is handled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .sheetParagraph()
            }
        } header: {
            Text("2. 보드 확인과 설정 코드", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: identity section header")
        }
        .sheetRowInsets()
    }

    /// Editing the EUI-64 withdraws the confirmation.
    private var expectedEUI64Binding: Binding<String> {
        Binding {
            form.expectedEUI64
        } set: { value in
            if value != form.expectedEUI64 { form.confirmedEUI64 = false }
            form.expectedEUI64 = value
        }
    }

    // MARK: - 3. The run

    private var runSection: some View {
        Section {
            Button {
                guard let boardID = form.selectedBoardID else { return }
                controller.start(boardID: boardID, expectedEUI64: form.expectedEUI64, setupCode: form.setupCode)
            } label: {
                SheetIconRow(systemImage: "play.circle.fill") {
                    Text("BLE 등록 시험 시작", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: start button")
                        .sheetParagraph()
                    Text("누르기 전에는 아무것도 시작하지 않습니다. 시작할 때마다 새 가입 코드를 만듭니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: start button subtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .sheetParagraph()
                }
            }
            .disabled(!canPressStart)

            phaseRows

            if let problem = controller.pollProblem, controller.isBusy {
                SheetIconRow(systemImage: "wifi.exclamationmark", iconStyle: .orange) {
                    PowerBaseEnrollmentText.error(problem)
                        .foregroundStyle(.orange)
                        .sheetParagraph()
                    Text("세션은 허브에서 계속 진행됩니다. 약 1초마다 상태를 다시 확인합니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: a status check failed but the session continues")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .sheetParagraph()
                }
                .accessibilityElement(children: .combine)
            }

            if controller.canCancel {
                Button(role: .destructive) {
                    controller.cancel()
                } label: {
                    SheetIconRow(systemImage: "stop.circle") {
                        Text("시험 취소", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: cancel button")
                            .sheetParagraph()
                        Text("허브의 이 세션과 보드의 이 요청에 취소를 요청합니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: cancel button subtitle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .sheetParagraph()
                    }
                }
            }
        } header: {
            Text("3. 등록 시험", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: run section header")
        } footer: {
            Text("성공은 허브가 이 세션에서 보드의 첫 신호(heartbeat)를 받았다고 답할 때만 표시합니다. 보드의 응답, Bluetooth 연결 종료, Thread 가입은 진행 상황일 뿐입니다. 센서 모듈이 없는 Power Base의 첫 신호는 센서가 정상이라는 뜻이 아닙니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: what counts as success")
                .sheetFooter()
        }
        .sheetRowInsets()
    }

    @ViewBuilder
    private var phaseRows: some View {
        switch controller.phase {
        case .idle:
            EmptyView()
        case .authenticating:
            progressRow(
                Text("보드 인증 중", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment phase: authenticating the board"),
                Text("보드에 연결해 규약 버전을 확인하고 설정 코드로 인증합니다. 허브에는 아직 아무것도 보내지 않았습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment phase: authenticating, description")
            )
        case .requestingHub:
            progressRow(
                Text("허브에 등록 세션을 요청하는 중", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment phase: POST in flight"),
                Text("보드 인증을 마쳤고 보드가 알려 준 실제 EUI-64가 예상 값과 같습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment phase: POST in flight, description")
            )
        case .hubUncertain:
            SheetIconRow(systemImage: "questionmark.circle.fill", iconStyle: .orange) {
                Text("허브의 답을 받지 못했습니다", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment phase: the POST got no answer")
                    .font(.headline)
                    .sheetParagraph()
                Text("허브가 등록 요청을 받았는지 알 수 없습니다. 보드에는 아무것도 보내지 않았습니다. 요청을 자동으로 다시 보내지 않으며, 그동안 새 시험은 시작할 수 없습니다. 같은 요청으로 허브에 다시 묻거나 시험을 취소하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment phase: the POST got no answer, description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .sheetParagraph()
            }
            .accessibilityElement(children: .combine)
            Button {
                controller.askHubAgain()
            } label: {
                SheetIconRow(systemImage: "arrow.triangle.2.circlepath") {
                    Text("허브에 다시 묻기", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: repeat the POST with the same values")
                        .sheetParagraph()
                }
            }
        case let .preparingHub(session):
            progressRow(
                Text("허브에서 가입 허용 준비 중", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment phase: hub is preparing"),
                Text("허브가 Commissioner를 확인하고 이 EUI-64를 Joiner로 추가하는 중입니다. 준비가 끝나기 전에는 보드에 아무것도 보내지 않습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment phase: hub is preparing, description")
            )
            sessionRows(session)
        case let .delivering(session):
            progressRow(
                Text("보드에 등록 요청 전달 중", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment phase: delivering pb-start"),
                Text("허브가 가입을 허용했습니다. 보드에서 새 challenge를 받아 가입 코드를 전달합니다. 연결이 끊겼다면 먼저 다시 인증합니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment phase: delivering, description")
            )
            sessionRows(session)
        case let .joining(session):
            boardProgressRow
            sessionRows(session)
        case let .deliveryUncertain(session):
            SheetIconRow(systemImage: "questionmark.circle.fill", iconStyle: .orange) {
                Text("보드가 요청을 받았는지 확인하지 못했습니다", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment phase: pb-start answer lost and board unreachable")
                    .font(.headline)
                    .sheetParagraph()
                Text("등록 요청을 보냈지만 답을 받지 못했고 보드에 다시 연결하지 못했습니다. 보드는 가입을 진행 중일 수 있습니다. 새 요청으로 다시 시작하지 않고 허브의 답을 계속 확인합니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment phase: delivery uncertain, description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .sheetParagraph()
            }
            .accessibilityElement(children: .combine)
            sessionRows(session)
        case let .earlierHubSession(session):
            SheetIconRow(systemImage: "info.circle.fill", iconStyle: .orange) {
                Text("이 기기의 허브 세션이 이미 진행 중입니다", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment phase: a session of this device runs on the hub")
                    .font(.headline)
                    .sheetParagraph()
                Text("이 세션의 가입 코드를 이 시험이 확신할 수 없으므로 보드에는 아무것도 보내지 않습니다. 세션이 끝나기를 기다리거나 취소한 뒤 새로 시작하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment phase: earlier hub session, description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .sheetParagraph()
            }
            .accessibilityElement(children: .combine)
            if let progress = controller.boardProgress {
                boardDetailRow(progress)
            }
            sessionRows(session)
        case .cancelling:
            progressRow(
                Text("정리하는 중", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment phase: cleaning up"),
                Text("원래 허브의 이 세션과 보드의 이 요청에 취소를 요청하고 있습니다. 진행 중이던 요청이 끝날 때까지 잠시 걸릴 수 있습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment phase: cleaning up, description")
            )
        case let .finished(outcome):
            outcomeRows(outcome)
        case let .failed(failure):
            SheetIconRow(systemImage: "xmark.octagon.fill", iconStyle: .red) {
                Texts.failure(failure)
                    .sheetParagraph()
                if let note = Texts.failureNote(failure) {
                    note
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .sheetParagraph()
                }
            }
            .accessibilityElement(children: .combine)
            if let cleanup = Texts.cleanup(of: failure) {
                cleanupRows(cleanup)
            }
        }
    }

    private func progressRow(_ title: Text, _ description: Text) -> some View {
        SheetIconRow {
            SheetRowProgress()
        } content: {
            title
                .font(.headline)
                .sheetParagraph()
            description
                .font(.caption)
                .foregroundStyle(.secondary)
                .sheetParagraph()
        }
        .accessibilityElement(children: .combine)
    }

    /// The board has the request; what it last said about it.
    @ViewBuilder
    private var boardProgressRow: some View {
        let progress = controller.boardProgress ?? .accepted
        progressRow(Texts.progressTitle(progress), Texts.progressDescription(progress))
        boardDetailRow(progress)
    }

    private func boardDetailRow(_ progress: PowerBaseEnrollmentBLEController.BoardProgress) -> some View {
        Text(verbatim: "board: \(Texts.progressCode(progress))")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .sheetParagraph()
    }

    @ViewBuilder
    private func sessionRows(_ session: PowerBaseEnrollmentSession) -> some View {
        if let expiresAround = controller.expiresAround {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = Int(expiresAround.timeIntervalSince(context.date).rounded(.up))
                SheetIconRow(systemImage: "timer", iconStyle: .secondary) {
                    if remaining > 0 {
                        Text("허브 기준 약 \(remaining)초 남음", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: seconds left in the hub's Joiner window (guidance)")
                            .monospacedDigit()
                            .sheetParagraph()
                    } else {
                        Text("허브의 제한 시간이 지났을 수 있습니다. 허브의 최종 상태를 기다리는 중입니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: local countdown ran out; the hub decides the end")
                            .sheetParagraph()
                    }
                }
            }
        }
        sessionDetails(session)
    }

    private func sessionDetails(_ session: PowerBaseEnrollmentSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "state: \(session.state.rawValue)")
            Text(verbatim: "eui64: \(session.eui64)")
            Text(verbatim: "joiner_entry: \(session.joinerEntry)")
            Text(verbatim: "session: \(session.sessionID.prefix(8))…")
        }
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .sheetParagraph()
    }

    @ViewBuilder
    private func outcomeRows(_ outcome: PowerBaseEnrollmentBLEController.Outcome) -> some View {
        let (symbol, style): (String, Color) = switch outcome.session.state {
        case .heartbeatReceived: ("checkmark.circle.fill", .green)
        case .expired: ("clock.badge.exclamationmark", .orange)
        case .cancelled: ("xmark.circle", .secondary)
        case .failed: ("xmark.octagon.fill", .red)
        case .preparing, .waitingForHeartbeat: ("questionmark.circle", .secondary)
        }
        SheetIconRow(systemImage: symbol, iconStyle: style) {
            Texts.outcomeTitle(outcome)
                .font(.headline)
                .sheetParagraph()
            Texts.outcomeDescription(outcome)
                .font(.caption)
                .foregroundStyle(.secondary)
                .sheetParagraph()
            if outcome.session.state == .failed {
                Text(verbatim: "error: \(outcome.session.error ?? "null")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .sheetParagraph()
            }
        }
        .accessibilityElement(children: .combine)
        if outcome.delivery == .uncertain {
            SheetIconRow(systemImage: "questionmark.circle", iconStyle: .orange) {
                Text("보드가 등록 요청을 받았는지는 끝까지 확인하지 못했습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment outcome: delivery stayed uncertain")
                    .sheetParagraph()
            }
        }
        if let progress = outcome.boardProgress {
            boardDetailRow(progress)
        }
        if let cleanup = outcome.cleanup {
            cleanupRows(cleanup)
        }
        sessionDetails(outcome.session)
    }

    @ViewBuilder
    private func cleanupRows(_ cleanup: PowerBaseEnrollmentBLEController.Cleanup) -> some View {
        PowerBaseEnrollmentBLECleanupRows(cleanup: cleanup)
    }
}

/// What a clean-up achieved on the hub and on the board, one row each. Also shown on the screen
/// below, after this screen was left with a run under way.
struct PowerBaseEnrollmentBLECleanupRows: View {
    let cleanup: PowerBaseEnrollmentBLEController.Cleanup

    var body: some View {
        let hubSettled = Self.isSettled(cleanup.hub)
        let boardSettled = Self.isSettled(cleanup.board)
        if let hub = PowerBaseEnrollmentBLEText.hubCancel(cleanup.hub) {
            SheetIconRow(systemImage: Self.symbol(settled: hubSettled), iconStyle: hubSettled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange)) {
                hub.sheetParagraph()
            }
            .accessibilityElement(children: .combine)
        }
        SheetIconRow(systemImage: Self.symbol(settled: boardSettled), iconStyle: boardSettled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange)) {
            PowerBaseEnrollmentBLEText.boardCancel(cleanup.board)
                .sheetParagraph()
        }
        .accessibilityElement(children: .combine)
    }

    /// The check mark is for a side that is known to be settled; anything refused, unanswered or
    /// undelivered gets the warning sign.
    static func symbol(settled: Bool) -> String {
        settled ? "checkmark.circle" : "exclamationmark.triangle"
    }

    static func isSettled(_ cancel: PowerBaseEnrollmentBLEController.HubCancel) -> Bool {
        switch cancel {
        case .notDelivered, .unknownSession: return false
        case .notNeeded, .cancelled, .alreadyFinal: return true
        }
    }

    /// Only a cancel the board took, or one there was nothing to cancel for, is settled. A board
    /// that refused the cancel (`BUSY`, `CLOSED`, …) or did not answer may still run its attempt.
    static func isSettled(_ cancel: PowerBaseEnrollmentBLEController.BoardCancel) -> Bool {
        switch cancel {
        case .notNeeded, .taken, .nothingToCancel: return true
        case .refused, .unconfirmed, .notDelivered: return false
        }
    }
}

/// The BLE test's messages, from the `PowerBaseEnrollmentDebug` table (a literal at every use, so
/// each key is filed into that table, which a Release build leaves out).
enum PowerBaseEnrollmentBLEText {
    typealias Controller = PowerBaseEnrollmentBLEController

    static func availability(_ availability: PowerBaseBLEAvailability) -> Text {
        switch availability {
        case .unknown:
            return Text("Bluetooth 상태를 확인하는 중입니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: Bluetooth state unknown")
        case .resetting:
            return Text("Bluetooth가 다시 시작되는 중입니다. 잠시 후 다시 시도하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: Bluetooth resetting")
        case .unsupported:
            return Text("이 기기는 Bluetooth LE를 지원하지 않아 이 시험을 할 수 없습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: Bluetooth unsupported")
        case .denied:
            #if targetEnvironment(macCatalyst)
            return Text("이 앱의 Bluetooth 권한이 꺼져 있습니다. 시스템 설정 > 개인정보 보호 및 보안 > Bluetooth에서 조각보 홈을 켜세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test, Mac: Bluetooth permission denied")
            #else
            return Text("이 앱의 Bluetooth 권한이 꺼져 있습니다. 설정 > 개인정보 보호 및 보안 > Bluetooth에서 조각보 홈을 켜세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test, iPhone/iPad: Bluetooth permission denied")
            #endif
        case .restricted:
            return Text("이 기기에서는 Bluetooth 사용이 제한되어 있어 이 시험을 할 수 없습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: Bluetooth restricted")
        case .poweredOff:
            return Text("Bluetooth가 꺼져 있습니다. Bluetooth를 켜면 검색을 시작합니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: Bluetooth off")
        case .poweredOn:
            return Text("Bluetooth를 사용할 수 있습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: Bluetooth on")
        }
    }

    // MARK: Board progress

    static func progressTitle(_ progress: Controller.BoardProgress) -> Text {
        switch progress {
        case .accepted, .queued:
            return Text("보드가 요청을 받음", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE board progress: accepted or queued")
        case .joining, .attaching:
            return Text("보드가 Thread 가입 중", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE board progress: joining or attaching")
        case .enrolled, .unreachable, .forgotten:
            return Text("허브의 첫 신호를 기다리는 중", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE board progress: waiting for the hub's heartbeat")
        case .failed, .cancelled:
            return Text("보드의 시도가 끝남", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE board progress: the board's attempt ended without enrolling")
        }
    }

    static func progressDescription(_ progress: Controller.BoardProgress) -> Text {
        switch progress {
        case .accepted, .queued:
            return Text("보드가 등록 요청을 받았습니다. Thread 가입이 성공했다는 뜻도, 허브에 등록됐다는 뜻도 아닙니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE board progress: accepted, description")
        case .joining:
            return Text("보드가 Joiner로 Thread 네트워크 가입을 시도하고 있습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE board progress: joining, description")
        case .attaching:
            return Text("보드가 Joiner 단계를 마치고 네트워크에 붙는 중입니다. 아직 등록이 끝난 것이 아닙니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE board progress: attaching, description")
        case .enrolled:
            return Text("보드는 Thread 가입과 기록을 마쳤다고 답했습니다. 이것만으로는 성공이 아니며, 허브가 이 보드의 첫 신호를 받았다고 답해야 합니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE board progress: enrolled on the board, description")
        case .unreachable:
            return Text("보드와의 Bluetooth 연결이 끊겼고 다시 연결하지 못했습니다. 보드는 등록을 마치면 Bluetooth를 끄므로 정상일 수 있고, 연결이 끊겨도 보드의 가입 시도는 계속됩니다. 허브의 답을 계속 확인합니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE board progress: link lost, description")
        case .forgotten:
            return Text("보드가 이 요청을 기억하지 못합니다(다시 시작했을 수 있습니다). 새 요청을 보내지 않고 허브의 답을 계속 확인합니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE board progress: the board doesn't know the request, description")
        case .failed, .cancelled:
            return Text("허브의 세션과 보드의 요청을 정리합니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE board progress: attempt ended, description")
        }
    }

    /// The board's own words, for the detail line (not translated: protocol names).
    static func progressCode(_ progress: Controller.BoardProgress) -> String {
        switch progress {
        case .accepted: return "accepted"
        case .queued: return "queued"
        case .joining: return "running / joining"
        case .attaching: return "running / attaching"
        case .enrolled: return "enrolled"
        case let .failed(result): return "failed / \(PowerBaseBLEResult.name(result))"
        case .cancelled: return "cancelled"
        case .forgotten: return "unknown request"
        case .unreachable: return "unreachable"
        }
    }

    // MARK: Outcome

    static func outcomeTitle(_ outcome: Controller.Outcome) -> Text {
        switch outcome.session.state {
        case .heartbeatReceived:
            return Text("허브가 신호를 받아 등록 확인", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment outcome: heartbeat_received (the only success)")
        case .expired where outcome.delivery != .notSent:
            return Text("보드는 가입했을 수 있으나 허브 확인 시간 만료", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment outcome: expired after delivery")
        case .expired:
            return Text("허브 세션 만료", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment outcome: expired before delivery")
        case .cancelled:
            return Text("취소됨", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment state cancelled")
        case .failed:
            return Text("허브 세션 실패", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment outcome: hub session failed")
        case .preparing, .waitingForHeartbeat:
            return PowerBaseEnrollmentText.stateTitle(outcome.session.state)
        }
    }

    static func outcomeDescription(_ outcome: Controller.Outcome) -> Text {
        switch outcome.session.state {
        case .heartbeatReceived:
            return Text("허브(Linux Bridge)가 이 세션을 시작한 뒤 이 Power Base의 첫 신호(heartbeat)를 받았습니다. Power Base가 허브에 닿았다는 뜻이며, 센서 모듈이나 센서가 정상이라는 뜻은 아닙니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment outcome: heartbeat_received, description")
        case .expired where outcome.delivery != .notSent:
            return Text("허브의 제한 시간 안에 이 보드의 첫 신호가 오지 않았습니다. 보드는 Thread에 가입했을 수 있지만 허브가 확인하지 못했으므로 성공이 아닙니다. 보드의 등록 기록과 Thread 연결은 건드리지 않았습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment outcome: expired after delivery, description")
        case .expired:
            return Text("보드에 등록 요청을 전달하기 전에 허브의 제한 시간이 끝났습니다. 보드에는 아무것도 보내지 않았습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment outcome: expired before delivery, description")
        case .cancelled:
            return Text("허브가 이 세션을 취소했고 Joiner 항목을 지웁니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment outcome: cancelled, description")
        case .failed:
            return Text("허브가 세션을 진행하지 못했습니다. 아래 오류 코드를 확인하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment state failed, description")
        case .preparing, .waitingForHeartbeat:
            return PowerBaseEnrollmentText.stateDescription(outcome.session.state)
        }
    }

    // MARK: Failures

    static func failure(_ failure: Controller.Failure) -> Text {
        switch failure {
        case .invalidEUI64:
            return Text("EUI-64 형식이 올바르지 않아 요청을 보내지 않았습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test failure")
        case .invalidSetupCode:
            return Text("설정 코드 형식이 올바르지 않아 아무것도 보내지 않았습니다. A–Z와 2–7로 된 26자여야 합니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment failure: malformed setup code")
        case .advertisedNameMismatch:
            return Text("선택한 보드가 광고하는 EUI-64가 확인한 값과 달라 연결하지 않았습니다. 목록에서 맞는 보드를 고르세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment failure: the picked row advertises another EUI-64")
        case .randomnessUnavailable:
            return Text("안전한 난수를 만들 수 없어 요청을 보내지 않았습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test failure")
        case .credentialUnavailable:
            return Text("이 기기의 허브 인증 정보를 읽을 수 없어 요청을 보내지 않았습니다. 설정에서 허브에 다시 연결하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test failure")
        case let .bluetooth(state):
            return availability(state)
        case .boardNotFound:
            return Text("선택한 보드를 더 이상 찾을 수 없습니다. 다시 검색하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment failure: the picked board is unknown")
        case let .connectionFailed(detail):
            return Text("보드에 연결하지 못했거나 연결이 끊겼습니다. (\(detail)) 보드가 켜져 있고 가까이 있는지 확인한 뒤 다시 시도하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment failure: connection; the argument is a technical detail")
        case let .protocolMismatch(detail):
            return problem(.protocolMismatch(detail))
        case .authenticationFailed:
            return problem(.authenticationFailed)
        case .handshakeRefused:
            return Text("보드가 인증을 시작하지 않습니다. 이번 부팅의 Bluetooth 등록이 닫혔거나(인증 5회 실패, 15분 경과) 이 앱의 인증 방식을 받지 않습니다. 보드 전원을 껐다 켠 뒤 다시 시도하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment failure: the board refused to start a handshake")
        case .boardProofMismatch:
            return Text("상대 기기가 이 EUI-64와 설정 코드의 보드임을 증명하지 못했습니다. 연결을 끊었습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment failure: the board's proof did not verify")
        case let .differentBoard(actual):
            return problem(.differentBoard(actual: actual))
        case let .boardNotWaiting(state):
            return problem(.notWaiting(state))
        case .boardBusy:
            return problem(.busy)
        case .boardClosed:
            return problem(.closed)
        case .boardUnavailable:
            return problem(.unavailable)
        case let .hub(error, _):
            return PowerBaseEnrollmentText.error(error)
        case let .boardRefused(code, _):
            return Text("보드가 등록 요청을 거부했습니다. (\(code.name)) Thread 가입은 시작되지 않았습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment failure: pb-start refused; the argument is the protocol's code name")
        case .boardUnreachable:
            return Text("보드에 다시 연결하지 못해 등록 요청을 전달하지 못했습니다. Thread 가입은 시작되지 않았습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment failure: could not deliver pb-start")
        case let .boardProblem(detail, _):
            return problem(detail)
        case let .boardAttemptFailed(result, _):
            return Text("보드의 Thread 가입 시도가 등록 없이 끝났습니다. (\(PowerBaseBLEResult.name(result)))", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment failure: the board's attempt failed; the argument is the firmware's result name")
        case .stopped:
            return Text("시험을 중단했습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment failure: cancelled before any hub session")
        case .sourceChanged:
            return Text("데이터 소스가 바뀌어 시험을 중단했습니다. 원래 허브의 세션과 보드의 요청에 취소를 요청했습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment failure: the app switched source during a run")
        }
    }

    static func problem(_ problem: Controller.Problem) -> Text {
        switch problem {
        case let .differentBoard(actual):
            return Text("인증된 보드가 알려 준 실제 EUI-64(\(actual))가 확인한 값과 다릅니다. 다른 보드이므로 중단했습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment failure: the authenticated EUI-64 differs; the argument is the board's EUI-64")
        case let .notWaiting(state):
            return Text("보드가 등록 대기 상태가 아닙니다. (\(state))", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment failure: the board is not waiting; the argument is its state")
        case .busy:
            return Text("보드에서 다른 등록 시도가 진행 중입니다. 그 시도가 끝난 뒤 다시 시도하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment failure: board busy")
        case .closed:
            return Text("보드의 Bluetooth 등록이 이번 부팅에서 닫혔습니다(등록 완료, 잠금 또는 시간 경과).", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment failure: BLE enrollment closed on the board")
        case .unavailable:
            return Text("이 보드는 Joiner를 실행할 수 없는 상태입니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment failure: the board cannot run a Joiner")
        case let .protocolMismatch(detail):
            return Text("보드의 Bluetooth 규약이 이 앱이 아는 것과 다릅니다. (\(detail)) 펌웨어와 앱의 버전을 확인하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment failure: protocol mismatch; the argument is a technical detail")
        case .authenticationFailed:
            return Text("보드가 인증을 거부했습니다. 설정 코드가 틀렸거나 이 EUI-64의 보드가 아닙니다. 자동으로 다시 시도하지 않습니다. 보드는 한 번 켠 동안 인증이 5회 실패하면 Bluetooth 등록을 닫습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment failure: authentication refused")
        }
    }

    /// For failures before the hub was contacted: says so.
    static func failureNote(_ failure: Controller.Failure) -> Text? {
        switch failure {
        case .connectionFailed, .protocolMismatch, .authenticationFailed, .handshakeRefused, .boardProofMismatch, .differentBoard,
             .boardNotWaiting, .boardBusy, .boardClosed, .boardUnavailable:
            return Text("허브에는 아무것도 보내지 않았습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment failure note: the hub was never contacted")
        default:
            return nil
        }
    }

    static func cleanup(of failure: Controller.Failure) -> Controller.Cleanup? {
        switch failure {
        case let .boardRefused(_, cleanup), let .boardUnreachable(cleanup), let .boardProblem(_, cleanup), let .boardAttemptFailed(_, cleanup),
             let .stopped(cleanup):
            return cleanup
        case let .hub(_, board?):
            return Controller.Cleanup(hub: .notNeeded, board: board)
        default:
            return nil
        }
    }

    // MARK: Clean-up

    static func hubCancel(_ cancel: Controller.HubCancel) -> Text? {
        switch cancel {
        case .notNeeded, .alreadyFinal:
            return nil
        case .cancelled:
            return Text("허브의 이 세션을 취소했습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment clean-up: hub session cancelled")
        case .notDelivered:
            return Text("허브에 세션 취소 요청이 전달되지 않았습니다. 세션은 허브의 제한 시간이 지나면 끝납니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment clean-up: hub cancel not delivered")
        case .unknownSession:
            return Text("허브가 세션을 만들었는지 알 수 없어 취소를 요청하지 못했습니다. 만들어졌다면 허브의 제한 시간이 지나면 끝납니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment clean-up: unknown whether a hub session exists")
        }
    }

    static func boardCancel(_ cancel: Controller.BoardCancel) -> Text {
        switch cancel {
        case .notNeeded:
            return Text("보드에는 등록 요청을 보내지 않았으므로 취소할 것이 없습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment clean-up: nothing was sent to the board")
        case .taken:
            return Text("보드가 이 요청의 취소를 받았습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment clean-up: board took the cancel")
        case .nothingToCancel:
            return Text("보드에 이 요청으로 취소할 수 있는 시도가 없습니다. (\(PowerBaseBLECode.noSuchAttempt.name)) 이미 끝났거나 등록을 마친 보드는 그대로 둡니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment clean-up: the board answered NO_SUCH_ATTEMPT; the argument is the protocol's code name")
        case let .refused(code) where code == .closed:
            return Text("보드의 Bluetooth 등록이 닫혀 있어 취소 요청을 받지 않았습니다. (\(code.name)) 보드가 등록을 마쳤을 수도 있고, 닫힌 채로 가입 시도를 계속하고 있을 수도 있습니다. 진행 중인 시도는 보드의 제한 시간이 지나면 끝납니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment clean-up: the board answered the cancel with CLOSED; the argument is the protocol's code name")
        case let .refused(code):
            return Text("보드가 취소 요청을 받아들이지 않았습니다. (\(code.name)) 보드의 시도가 취소됐다고 볼 수 없습니다. 진행 중이라면 보드의 제한 시간이 지나면 끝납니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment clean-up: the board refused the cancel; the argument is the protocol's code name")
        case .unconfirmed:
            return Text("보드에 취소 요청을 보냈지만 답을 확인하지 못했습니다. 보드가 취소를 받았는지 알 수 없습니다. 진행 중인 시도가 있다면 보드의 제한 시간이 지나면 끝납니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment clean-up: board cancel sent, answer lost")
        case .notDelivered:
            return Text("보드에 취소 요청을 전달하지 못했습니다. 보드에 진행 중인 시도가 있다면 보드의 제한 시간이 지나면 끝납니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment clean-up: board cancel not delivered")
        }
    }
}
#endif
