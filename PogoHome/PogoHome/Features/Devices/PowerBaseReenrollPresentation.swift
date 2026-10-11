import Foundation
import PowerBaseBLEKit

/// What "다른 허브에 연결하기" shows, as plain values and strings -- separate from the views so every
/// state can be checked in a test and rendered in every language.
///
/// The rules it encodes:
/// - **Eight different things are shown as eight different things**: what to do with the BOOT
///   button, the board being found, the setup code being checked, the explicit confirmation, the
///   reset under way, a result that could not be confirmed, the reset verified (ready to register
///   with the new hub), and -- on the registration screen that follows -- the new hub hearing the
///   Power Base. None is worded as another.
/// - **"Verified" is the board's own word.** A command that was accepted, a connection that
///   ended and a screen that was left are never worded as "reset" or as "cancelled".
/// - **Nothing technical is asked for.** No key, address, PSKd or EUI-64 is shown or entered; a
///   board is named by the last four digits of its identifier, like in the device list.
/// - **The new hub is shown first and never stands in the way.** Whether the hub the app reads is
///   ready is said at the top, before anything is erased; when it is not, the screen says what
///   that means and still lets the user go on.
nonisolated struct PowerBaseReenrollScreenState: Equatable, Sendable {
    typealias Controller = PowerBaseLocalResetController

    var phase: Controller.Phase = .idle
    var availability: PowerBaseBLEAvailability = .unknown
    var boards: [PowerBaseBLEDiscoveredBoard] = []
    /// A search is running right now.
    var isScanning = false
    var foundNothingSoFar = false
    var isSuspended = false
    var windowSecondsLeft = 0
    /// A reset command was sent and its outcome is not settled.
    var hasUnresolvedOperation = false
    /// The board that operation went to (lower-case hex), when there is one.
    var unresolvedBoardIdentifier: String?
    /// The board the last run authenticated (lower-case hex).
    var boardIdentifier: String?
    /// Why the hub the app reads cannot take a registration now; `nil` when it can.
    var hubIneligibility: PowerBaseHubIneligibility?
    var hubName: String?
}

extension PowerBaseReenrollScreenState {
    @MainActor
    init(controller: PowerBaseLocalResetController, hubName: String?) {
        self.init(
            phase: controller.phase, availability: controller.availability, boards: controller.boards,
            isScanning: controller.isScanning, foundNothingSoFar: controller.foundNothingSoFar, isSuspended: controller.isSuspended,
            windowSecondsLeft: controller.windowSecondsLeft, hasUnresolvedOperation: controller.hasUnresolvedOperation,
            unresolvedBoardIdentifier: controller.unresolvedBoardIdentifier, boardIdentifier: controller.boardIdentifier,
            hubIneligibility: controller.target.ineligibility, hubName: hubName
        )
    }
}

/// The steps of the progress list, in order.
nonisolated enum PowerBaseReenrollStage: Int, CaseIterable, Sendable {
    /// Connecting and authenticating with the setup code.
    case verifyingBoard
    /// The user's confirmation.
    case confirming
    /// The board erases and verifies.
    case resetting
    /// Verified: ready to be registered with the new hub.
    case readyToRegister
}

nonisolated enum PowerBaseReenrollPresentation {
    typealias Controller = PowerBaseLocalResetController

    /// The step a run is at; `nil` when nothing is under way.
    static func stage(of phase: Controller.Phase) -> PowerBaseReenrollStage? {
        switch phase {
        case .connecting, .checking: return .verifyingBoard
        case .awaitingConfirmation: return .confirming
        case .resetting: return .resetting
        case .ready: return .readyToRegister
        case .idle, .uncertain, .failed: return nil
        }
    }

    /// Whether the scan list and the setup code are shown: at the start, and whenever the board
    /// has to be reached again (to check a result, or to try again).
    static func showsFinding(_ state: PowerBaseReenrollScreenState) -> Bool {
        switch state.phase {
        case .idle, .uncertain: return true
        case .connecting, .checking, .awaitingConfirmation, .resetting, .ready, .failed: return false
        }
    }

    /// The boards offered. While a sent command is unresolved only the board it went to is: the
    /// one thing to do then is to ask that board.
    static func selectableBoards(_ state: PowerBaseReenrollScreenState) -> [PowerBaseBLEDiscoveredBoard] {
        let all = PowerBaseSetupPresentation.selectableBoards(state.boards)
        guard state.hasUnresolvedOperation, let only = state.unresolvedBoardIdentifier else { return all }
        return all.filter { $0.advertisedEUI64 == only }
    }

    static func boardLabel(_ identifier: String?) -> String {
        PowerBaseSetupPresentation.label(forAdvertisedEUI64: identifier ?? "")
    }

    /// The board a QR code may be read for on "다른 허브에 연결하기": the selected row of the
    /// list, while the setup code field is shown. `nil`: nothing may be read.
    static func qrTarget(state: PowerBaseReenrollScreenState, form: PowerBaseReenrollForm) -> PowerBaseSetupQRIntake.Target? {
        guard showsFinding(state), form.didStartFinding, let board = selectableBoards(state).first(where: { $0.id == form.selectedBoardID }),
              let eui64 = board.advertisedEUI64 else { return nil }
        return PowerBaseSetupQRIntake.Target(boardID: board.id, boardEUI64: eui64)
    }

    /// What the registration screen that follows is given: the code of this screen's field, for
    /// the board this screen authenticated with it (`authenticatedBoard`, the board's own word) --
    /// and for no other board. `nil` -- nothing is handed over -- when no board was
    /// authenticated, when the field no longer holds a setup code, or when the code is known to
    /// belong to another board.
    static func handoff(code field: PowerBaseSetupCodeField, authenticatedBoard: String?) -> PowerBaseSetupCodeHandoff? {
        guard let authenticatedBoard else { return nil }
        if let owner = field.codeBoardEUI64, owner != authenticatedBoard { return nil }
        return PowerBaseSetupCodeHandoff(code: field.text, boardEUI64: authenticatedBoard)
    }
}

/// The screen's wording, in the app's language. Every string a user can see on "다른 허브에
/// 연결하기" comes from here.
nonisolated enum PowerBaseReenrollText {
    typealias Controller = PowerBaseLocalResetController

    // MARK: Entry and introduction

    static var entryTitle: String { String(localized: "다른 허브에 연결하기", comment: "Add device sheet / re-enroll screen title: move a registered Power Base to another hub") }
    static var entrySubtitle: String { String(localized: "이미 등록된 Power Base를 다른 허브로 옮깁니다. 이전 허브가 없어도 Power Base의 BOOT 버튼과 설정 코드로 할 수 있습니다.", comment: "Add device sheet: subtitle of the re-enroll entry") }
    static var intro: String { String(localized: "이미 허브에 등록된 Power Base를 다른 허브로 옮길 때 사용합니다. 이전 허브가 꺼져 있거나 없어도 됩니다. Power Base 가까이에서, BOOT 버튼과 설정 코드로 진행합니다.", comment: "Re-enroll: what this screen is for") }
    static var introFooter: String { String(localized: "순서: ① Power Base의 기존 등록 정보를 지웁니다(확인 후에만). ② 새 허브에 등록합니다. 두 단계는 따로 확인됩니다.", comment: "Re-enroll: the two parts of the procedure, confirmed separately") }

    // MARK: The new hub

    static var hubHeader: String { String(localized: "새로 연결할 허브", comment: "Re-enroll: section header, the hub the Power Base will be registered with afterwards") }
    static var hubReadyFooter: String { String(localized: "기존 등록 정보를 지운 뒤 이 허브에 등록합니다. 다른 허브로 옮기려면 먼저 설정에서 그 허브를 선택하세요.", comment: "Re-enroll: the new hub is ready; how to pick another one") }
    static var hubNotReady: String { String(localized: "새로 연결할 허브가 아직 준비되지 않았습니다.", comment: "Re-enroll: the hub the app reads cannot take a registration now") }
    static var hubNotReadyConsequence: String { String(localized: "허브를 준비하지 않고도 기존 등록 정보를 지울 수는 있습니다. 다만 그렇게 하면 새 허브에 등록할 때까지 Power Base는 어느 허브에도 연결되지 않습니다. 먼저 새 허브를 준비하는 것을 권장합니다.", comment: "Re-enroll: what resetting without a ready hub means; it is allowed, not required") }

    // MARK: The BOOT button

    static var buttonHeader: String { String(localized: "Power Base 준비", comment: "Re-enroll: section header of the BOOT button steps") }
    static var buttonStep1: String { String(localized: "Power Base가 켜져 평소처럼 동작하는 상태에서 BOOT 버튼을 5초 동안 누른 뒤 손을 떼세요.", comment: "Re-enroll step 1: hold the BOOT button for 5 seconds on a running board, then release") }
    static var buttonStep2: String { String(localized: "손을 떼면 Power Base가 다시 시작해 약 2분 동안 재등록을 기다립니다. 그동안 센서 데이터 전송은 잠시 멈춥니다.", comment: "Re-enroll step 2: the board restarts and waits about two minutes; data pauses") }
    static var buttonStep3: String { String(localized: "버튼을 누르거나 Bluetooth로 연결하는 것만으로는 아무것도 지워지지 않습니다. 2분 안에 아래에서 확인하지 않으면 Power Base는 원래대로 돌아갑니다.", comment: "Re-enroll step 3: the button and a connection erase nothing; without a confirmation the board goes back to how it was") }
    static var buttonFooter: String { String(localized: "전원을 연결하거나 RST 버튼을 누르는 순간에는 BOOT 버튼을 누르고 있지 마세요. 그렇게 하면 Power Base가 동작하지 않는 다른 모드로 켜집니다.", comment: "Re-enroll: do not hold BOOT while powering on or resetting") }

    // MARK: Finding and the setup code

    static var findHeader: String { String(localized: "Power Base 선택", comment: "Power Base setup: section header of the scan list") }
    static var startFinding: String { String(localized: "주변에서 Power Base 찾기", comment: "Power Base setup: button that starts the Bluetooth scan") }
    static var startFindingHint: String { String(localized: "이 화면을 열면 Bluetooth로 재등록을 기다리는 Power Base를 자동으로 찾습니다. 찾기가 시작되지 않았다면 위 버튼을 누르세요. BOOT 버튼을 5초 누른 Power Base만 나타납니다.", comment: "Re-enroll: footer while the automatic search has not started; only a board whose BOOT button was held shows up") }
    static var findFooter: String { String(localized: "이 화면이 열려 있는 동안 Bluetooth로 자동으로 찾습니다. 찾는 것만으로는 Power Base의 재등록 창이 열리지 않고 아무것도 지워지지 않습니다. 위 순서대로 BOOT 버튼을 5초 누른 Power Base만 여기에 나타납니다.", comment: "Re-enroll: footer of the scan list; the automatic search neither opens the board's window nor erases anything") }
    static var finding: String { String(localized: "재등록을 기다리는 Power Base를 찾는 중입니다.", comment: "Re-enroll: scanning") }
    static var nothingFound: String { String(localized: "아직 찾지 못했습니다. BOOT 버튼을 5초 동안 누른 뒤 손을 뗐는지, Power Base가 가까이 있는지 확인하세요. Power Base는 약 2분 동안만 기다리므로 시간이 지났다면 BOOT 버튼을 다시 5초 누르세요.", comment: "Re-enroll: nothing found after a while, with what to check") }
    static var codeFooter: String { String(localized: "이 Power Base와 함께 받은 26자리 설정 코드(A–Z, 2–7)를 입력하세요. 코드는 이 화면에서만 쓰이며 저장되지 않습니다. 코드를 확인하는 것만으로는 아무것도 지워지지 않습니다.", comment: "Re-enroll: the setup code authenticates the board; checking it erases nothing") }
    static var verify: String { String(localized: "Power Base 확인", comment: "Re-enroll: the button that connects and checks the board with the setup code (erases nothing)") }
    static var checkResult: String { String(localized: "결과 확인", comment: "Re-enroll: the button that asks the board what became of the reset that was already sent (sends no new reset)") }

    // MARK: Progress

    static func stageTitle(_ stage: PowerBaseReenrollStage) -> String {
        switch stage {
        case .verifyingBoard: return String(localized: "설정 코드 확인 중", comment: "Re-enroll step: authenticating the board with its setup code")
        case .confirming: return String(localized: "지우기 전 확인", comment: "Re-enroll step: waiting for the user's explicit confirmation")
        case .resetting: return String(localized: "기존 등록 정보 지우는 중", comment: "Re-enroll step: the board erases and verifies")
        case .readyToRegister: return String(localized: "새 허브에 등록 준비", comment: "Re-enroll step: reset verified, ready to register with the new hub")
        }
    }

    static func progressDetail(_ phase: Controller.Phase) -> String? {
        switch phase {
        case .connecting, .checking:
            return String(localized: "설정 코드로 Power Base를 확인하고 있습니다. 몇 초 걸릴 수 있습니다. 아직 아무것도 지우지 않았습니다.", comment: "Re-enroll progress: authenticating; nothing erased")
        case .resetting:
            return String(localized: "Power Base가 기존 등록 정보를 지우고, 지워졌는지 직접 확인하고 있습니다. Power Base를 끄지 마세요.", comment: "Re-enroll progress: the board erases and verifies")
        case .idle, .awaitingConfirmation, .uncertain, .ready, .failed:
            return nil
        }
    }

    static var backgroundHint: String { String(localized: "앱이 다시 화면에 보이면 이어서 진행합니다.", comment: "Re-enroll: the run is paused while the app is in the background") }

    // MARK: The confirmation

    static func confirmTitle(_ boardLabel: String) -> String {
        String(localized: "\(boardLabel) 확인됨", comment: "Re-enroll: the board was authenticated; the argument is its short label")
    }
    static var confirmExplanation: String { String(localized: "이 Power Base에 저장된 기존 등록 정보(이전 허브와의 연결 정보와 Thread 네트워크 가입 정보)를 지웁니다. 지우면 이전 허브와의 연결이 끊기며 되돌릴 수 없습니다.", comment: "Re-enroll confirmation: what is erased; the old connection ends and it cannot be undone") }
    static var confirmOldHubRemains: String { String(localized: "이전 허브의 기기 목록이나 방 배정 같은 기록은 이 작업으로 지워지지 않고 남을 수 있습니다. 센서 모듈과 설정 코드는 바뀌지 않습니다.", comment: "Re-enroll confirmation: the old hub's own records may remain; modules and the setup code are unchanged") }
    static func confirmTimeLeft(_ seconds: Int) -> String {
        String(localized: "Power Base가 기다리는 시간이 약 \(seconds)초 남았습니다. 시간이 지나면 아무것도 지우지 않고 원래대로 돌아갑니다.", comment: "Re-enroll confirmation: seconds the board's window had left when it was asked")
    }
    static var eraseButton: String { String(localized: "기존 등록 정보 지우기", comment: "Re-enroll: the destructive button that opens the final confirmation") }
    static var declineButton: String { String(localized: "지우지 않고 그만두기", comment: "Re-enroll: leaves the confirmation without erasing anything") }
    static var dialogTitle: String { String(localized: "기존 등록 정보를 지울까요?", comment: "Re-enroll: title of the final confirmation dialog") }
    static var dialogMessage: String { String(localized: "이 Power Base와 이전 허브의 연결이 끊깁니다. 되돌릴 수 없습니다.", comment: "Re-enroll: message of the final confirmation dialog") }
    static var dialogConfirm: String { String(localized: "지우기", comment: "Re-enroll: the destructive action of the final confirmation dialog") }
    static var dialogCancel: String { String(localized: "취소", comment: "Power Base setup: cancels a registration under way") }

    // MARK: Results

    static func readyTitle(_ ready: Controller.Ready) -> String {
        switch ready {
        case .resetVerified: return String(localized: "기존 등록 정보를 지웠습니다", comment: "Re-enroll result title: the board verified the reset")
        case .alreadyNotEnrolled: return String(localized: "이 Power Base는 등록되어 있지 않습니다", comment: "Re-enroll result title: nothing to reset")
        }
    }

    static func readyMessage(_ ready: Controller.Ready) -> String {
        switch ready {
        case .resetVerified:
            return String(localized: "Power Base가 기존 등록 정보를 지우고, 지워진 것을 직접 확인했습니다. 아직 새 허브에 등록된 것은 아닙니다. 이제 새 허브에 등록하세요.", comment: "Re-enroll result: reset verified by the board; not registered with the new hub yet")
        case .alreadyNotEnrolled:
            return String(localized: "지울 등록 정보가 없어 아무것도 지우지 않았습니다. 바로 새 허브에 등록할 수 있습니다.", comment: "Re-enroll result: the board held no registration; nothing was erased")
        }
    }

    static var registerNext: String { String(localized: "새 허브에 등록", comment: "Re-enroll: the button that goes on to the ordinary registration with the new hub") }
    static var registerNextFooter: String { String(localized: "등록은 새 허브가 Power Base의 첫 신호를 받아야 끝납니다. 다음 화면에서 확인할 수 있습니다.", comment: "Re-enroll: registration is only done when the new hub hears the Power Base") }

    static func uncertainTitle(_ uncertainty: Controller.Uncertainty) -> String {
        switch uncertainty {
        case .answerLost, .checkFailed:
            return String(localized: "지우기 결과를 확인하지 못했습니다", comment: "Re-enroll result title: the reset command was sent and its outcome is unknown")
        case .boardStillWorking:
            return String(localized: "Power Base가 아직 지우는 중입니다", comment: "Re-enroll result title: the board has the reset and has not verified it")
        }
    }

    static func uncertainMessage(_ uncertainty: Controller.Uncertainty) -> String {
        switch uncertainty {
        case .answerLost:
            return String(localized: "지우기 요청은 이미 Power Base로 보냈지만 결과를 받지 못했습니다. 지워졌을 수도, 아닐 수도 있습니다. 취소된 것이 아닙니다.", comment: "Re-enroll result: the command was sent, the answer was lost; not cancelled")
        case .boardStillWorking:
            return String(localized: "Power Base가 지우기 요청을 받았지만 아직 끝났다고 확인하지 않았습니다. Power Base는 다시 시작할 때마다 이어서 진행하며, 끝나기 전에는 이전 네트워크로 돌아가지 않습니다.", comment: "Re-enroll result: the board journaled the reset and has not verified it; it carries on at each restart")
        case let .checkFailed(failure):
            return String(localized: "지우기 요청은 이미 Power Base로 보냈고, 그 결과를 아직 확인하지 못했습니다.", comment: "Re-enroll result: a check of the outcome failed; followed by why") + " " + failureMessage(failure)
        }
    }

    static var uncertainGuide: String { String(localized: "Power Base 가까이에서 아래의 Power Base를 선택하고 '결과 확인'을 누르세요. 지우기 요청을 다시 보내지 않고, 이미 보낸 요청의 결과만 확인합니다. Power Base가 목록에 없으면 전원이 켜져 있는지 확인하세요.", comment: "Re-enroll: how to resolve an unknown outcome; nothing is sent again") }

    static var failedTitle: String { String(localized: "기존 등록 정보를 지우지 않았습니다", comment: "Re-enroll result title: nothing was erased") }

    static func failureMessage(_ failure: Controller.Failure) -> String {
        switch failure {
        case .invalidSetupCode:
            return String(localized: "설정 코드는 26자리(A–Z, 2–7)입니다. 다시 확인하세요.", comment: "Confirm removal failure: the code is not a setup code")
        case .randomnessUnavailable:
            return String(localized: "이 기기에서 안전한 난수를 만들 수 없어 진행하지 않았습니다. 잠시 뒤 다시 시도하세요.", comment: "Re-enroll failure: no secure randomness; nothing was sent")
        case let .bluetooth(availability):
            return PowerBaseSetupText.bluetoothMessage(availability) ?? PowerBaseSetupText.reasonMessage(.bluetooth(availability))
        case .boardNotFound, .boardUnreachable:
            return PowerBaseSetupText.reasonMessage(.boardUnreachable)
        case .wrongSetupCode:
            return String(localized: "설정 코드가 이 Power Base의 것과 맞지 않습니다. 아무것도 지우지 않았습니다. 코드를 다시 확인하세요. 여러 번 틀리면 Power Base가 재등록 대기를 닫고 원래대로 돌아갑니다.", comment: "Re-enroll failure: wrong setup code; nothing erased")
        case .boardLocked:
            return String(localized: "Power Base가 지금은 요청을 받지 않습니다. 재등록 대기 시간이 지났거나 설정 코드를 여러 번 틀렸습니다. 아무것도 지우지 않았습니다. BOOT 버튼을 다시 5초 누른 뒤 시도하세요.", comment: "Re-enroll failure: the board closed its window; nothing erased")
        case .differentBoard:
            return String(localized: "선택한 Power Base와 설정 코드로 확인된 Power Base가 다릅니다. 안전을 위해 아무것도 지우지 않았습니다. 목록에서 다시 선택하세요.", comment: "Re-enroll failure: the authenticated board is not the selected one; nothing erased")
        case .boardNeedsUpdate:
            return String(localized: "이 Power Base의 펌웨어는 BOOT 버튼으로 재등록하는 기능을 지원하지 않습니다. Power Base 펌웨어를 업데이트해야 합니다. 아무것도 지우지 않았습니다.", comment: "Re-enroll failure: firmware without the local reset; nothing erased, nothing else sent")
        case .windowNotOpen:
            return String(localized: "이 Power Base는 등록되어 있지만 재등록을 기다리는 상태가 아닙니다. BOOT 버튼을 누르지 않았거나 2분이 지났습니다. 아무것도 지우지 않았습니다. BOOT 버튼을 5초 동안 누른 뒤 손을 떼고 다시 시도하세요.", comment: "Re-enroll failure: the board's window is not open; nothing erased")
        case .removalInProgress:
            return String(localized: "이 Power Base는 허브에서 삭제하는 중입니다. 그 삭제를 먼저 마쳐야 합니다. 기기 목록의 Power Base 관리에서 '삭제 확인'을 진행하세요. 아무것도 지우지 않았습니다.", comment: "Re-enroll failure: a remote removal is under way and comes first")
        case .boardBusy:
            return String(localized: "Power Base가 다른 지우기 요청을 처리하고 있습니다. 잠시 뒤 다시 확인하세요.", comment: "Re-enroll failure: another reset is under way on the board")
        case .resetNotStarted:
            return String(localized: "Power Base가 지우기를 시작하지 않았다고 알려 왔습니다. 기존 등록 정보는 그대로입니다. 필요하면 BOOT 버튼을 다시 5초 누른 뒤 처음부터 진행하세요.", comment: "Re-enroll failure: the board says the reset never started; the registration is intact")
        case .other:
            return String(localized: "Power Base가 요청을 받아들이지 않았습니다. 아무것도 지우지 않았습니다. BOOT 버튼을 다시 5초 누른 뒤 시도하세요.", comment: "Re-enroll failure: generic refusal; nothing erased")
        }
    }

    static var retry: String { String(localized: "다시 시도", comment: "Power Base setup: back to the start for another attempt") }
}
