import Foundation
import PowerBaseBLEKit

/// What the product "Power Base 추가" screen shows for each state of
/// `PowerBaseEnrollmentBLEController`, as plain values and strings -- separate from the views so
/// every state can be checked in a test and rendered in every language.
///
/// The rules it encodes:
/// - **Done means the hub said so.** The only success is the hub's `heartbeat_received` for this
///   run's own session. The board's "accepted" or "enrolled", an earlier "online" in the snapshot
///   and the Bluetooth connection ending are all progress, never success.
/// - **A finished screen shows the result, not old progress.** Nothing of the board's last
///   reported state is shown once the run is over.
/// - **Partly done is said as that.** When the board may have joined but the hub did not confirm
///   it, the screen says so, says that nothing was reset, and says what to do -- it never claims
///   the board was put back.
/// - **Nothing secret is shown.** No PSKd, no management key, no address, no session id.
nonisolated enum PowerBaseSetupStage: Int, CaseIterable, Sendable {
    case finding
    case verifyingBoard
    case connecting
    case confirmingWithHub
    case done
}

nonisolated enum PowerBaseSetupPresentation {
    typealias Controller = PowerBaseEnrollmentBLEController

    /// How a run ended, as the screen distinguishes it.
    enum Result: Equatable, Sendable {
        /// The hub heard the new Power Base.
        case registered
        /// The board was given the request and may have joined, but the hub did not confirm it.
        /// Nothing was reset.
        case partlyDone
        /// Nothing reached the board, or the board refused: it is as it was.
        case notRegistered(Reason)
        /// The user cancelled. `boardMayHaveJoined`: the request had already reached the board and
        /// the board did not confirm that it stopped.
        case cancelled(boardMayHaveJoined: Bool)
    }

    enum Reason: Equatable, Sendable {
        /// The setup code (or the board it belongs to) was not accepted.
        case wrongSetupCode
        /// The board has refused too many attempts, or its enrollment time is over: power-cycle it.
        case boardLocked
        case boardBusy
        /// The board is already enrolled (or in the middle of joining).
        case boardNotWaiting
        case boardNeedsUpdate
        /// The board that authenticated is not the one that was picked.
        case differentBoard
        case boardUnreachable
        case bluetooth(PowerBaseBLEAvailability)
        case hubNeedsUpdate
        case hubNotPaired
        case hubUnreachable
        case hubBusy
        case alreadyRegistered
        case timedOut
        case sourceChanged
        case other
    }

    /// The step of the progress list a running controller is at; `nil` when no run is under way.
    static func stage(phase: Controller.Phase, boardProgress: Controller.BoardProgress?) -> PowerBaseSetupStage? {
        switch phase {
        case .idle, .failed, .cancelling:
            return nil
        case .authenticating:
            return .verifyingBoard
        case .requestingHub, .hubUncertain, .preparingHub, .delivering, .deliveryUncertain, .earlierHubSession:
            return .connecting
        case .joining:
            // The board says it has joined and stored that: what is left is the hub hearing it.
            switch boardProgress {
            case .enrolled, .unreachable: return .confirmingWithHub
            default: return .connecting
            }
        case let .finished(outcome):
            return outcome.session.state == .heartbeatReceived ? .done : nil
        }
    }

    /// The result of an ended run; `nil` while one is under way (or none was started).
    static func result(of phase: Controller.Phase) -> Result? {
        switch phase {
        case let .finished(outcome):
            switch outcome.session.state {
            case .heartbeatReceived:
                return .registered
            case .cancelled:
                // Only the board's own "cancelled" settles it; anything else leaves it open.
                let boardStopped = outcome.cleanup?.board == .taken
                return .cancelled(boardMayHaveJoined: outcome.delivery != .notSent && !boardStopped)
            case .expired, .failed, .preparing, .waitingForHeartbeat:
                if outcome.delivery == .notSent {
                    return .notRegistered(outcome.session.state == .expired ? .timedOut : .hubUnreachable)
                }
                return .partlyDone
            }
        case let .failed(failure):
            return result(of: failure)
        default:
            return nil
        }
    }

    static func result(of failure: Controller.Failure) -> Result {
        switch failure {
        case .invalidEUI64, .invalidSetupCode, .advertisedNameMismatch, .randomnessUnavailable:
            return .notRegistered(.other)
        case .credentialUnavailable:
            return .notRegistered(.hubNotPaired)
        case let .bluetooth(availability):
            return .notRegistered(.bluetooth(availability))
        case .boardNotFound, .connectionFailed:
            return .notRegistered(.boardUnreachable)
        case .protocolMismatch:
            return .notRegistered(.boardNeedsUpdate)
        case .authenticationFailed, .boardProofMismatch:
            return .notRegistered(.wrongSetupCode)
        case .handshakeRefused, .boardClosed:
            return .notRegistered(.boardLocked)
        case .differentBoard:
            return .notRegistered(.differentBoard)
        case .boardNotWaiting:
            return .notRegistered(.boardNotWaiting)
        case .boardBusy:
            return .notRegistered(.boardBusy)
        case .boardUnavailable, .boardNeedsUpdate:
            return .notRegistered(.boardNeedsUpdate)
        case let .hub(error, _):
            return .notRegistered(reason(for: error))
        case let .boardRefused(code, _):
            switch code {
            case .busy: return .notRegistered(.boardBusy)
            case .closed: return .notRegistered(.boardLocked)
            case .notWaiting: return .notRegistered(.boardNotWaiting)
            default: return .notRegistered(.other)
            }
        case .boardUnreachable:
            return .notRegistered(.boardUnreachable)
        case let .boardProblem(problem, _):
            switch problem {
            case .differentBoard: return .notRegistered(.differentBoard)
            case .notWaiting: return .notRegistered(.boardNotWaiting)
            case .busy: return .notRegistered(.boardBusy)
            case .closed: return .notRegistered(.boardLocked)
            case .unavailable, .protocolMismatch, .needsUpdate: return .notRegistered(.boardNeedsUpdate)
            case .authenticationFailed: return .notRegistered(.wrongSetupCode)
            }
        case .boardAttemptFailed:
            // The board tried to join and gave up by itself: it is waiting again, unchanged.
            return .notRegistered(.timedOut)
        case .hubEndpoint:
            return .notRegistered(.hubNeedsUpdate)
        case let .stopped(cleanup):
            return .cancelled(boardMayHaveJoined: cleanup.board != .notNeeded && cleanup.board != .taken && cleanup.board != .nothingToCancel)
        case .sourceChanged:
            return .notRegistered(.sourceChanged)
        }
    }

    static func reason(for error: PowerBaseEnrollmentError) -> Reason {
        switch error {
        case .unauthorized, .forbidden, .certificateMismatch:
            return .hubNotPaired
        case .enrollmentDisabled, .notSupported, .bridgeEndpointNotSupported, .managementNotSupported:
            return .hubNeedsUpdate
        case .enrollmentInProgress:
            return .hubBusy
        case .powerBaseAlreadyConnected:
            return .alreadyRegistered
        case .unreachable, .unavailable, .internalError, .badResponse, .sessionNotFound, .sessionAlreadyFinal:
            return .hubUnreachable
        case .rejected, .managementRequired:
            return .other
        }
    }

    /// One row per advertised EUI-64 (the strongest signal wins), in the order first seen. A
    /// peripheral whose name is not a Power Base name is not offered: without the EUI-64 there
    /// is nothing to authenticate against.
    static func selectableBoards(_ boards: [PowerBaseBLEDiscoveredBoard]) -> [PowerBaseBLEDiscoveredBoard] {
        var order: [String] = []
        var best: [String: PowerBaseBLEDiscoveredBoard] = [:]
        for board in boards {
            guard let eui64 = board.advertisedEUI64 else { continue }
            if let existing = best[eui64] {
                if board.rssi > existing.rssi { best[eui64] = board }
            } else {
                order.append(eui64)
                best[eui64] = board
            }
        }
        return order.compactMap { best[$0] }
    }

    /// The board a QR code may be read for on "Power Base 추가": the selected row of the list,
    /// while the setup code field is shown -- not while a run is under way, a result is shown or
    /// the hub cannot be used. `nil`: nothing may be read.
    @MainActor
    static func qrTarget(controller: Controller, form: PowerBaseSetupForm) -> PowerBaseSetupQRIntake.Target? {
        guard controller.ineligibility == nil, result(of: controller.phase) == nil, !controller.isBusy, form.didStartFinding,
              let board = selectableBoards(controller.boards).first(where: { $0.id == form.selectedBoardID }),
              let eui64 = board.advertisedEUI64 else { return nil }
        return PowerBaseSetupQRIntake.Target(boardID: board.id, boardEUI64: eui64)
    }

    /// The same short label the device list uses for a registered Base: "Power Base ··1234".
    static func label(forAdvertisedEUI64 eui64: String) -> String {
        "Power Base ··\(eui64.suffix(4))"
    }

    /// How many characters of a valid setup code have been typed so far (letters and digits of
    /// its alphabet only), for the "n / 26" hint. Never the code itself.
    static func typedSetupCodeLength(_ input: String) -> Int {
        input.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
    }
}

/// The screen's wording, in the app's language. Every string a user can see on "Power Base 추가"
/// comes from here, so a test can list them and render them in every language.
nonisolated enum PowerBaseSetupText {
    typealias Result = PowerBaseSetupPresentation.Result
    typealias Reason = PowerBaseSetupPresentation.Reason

    static func stageTitle(_ stage: PowerBaseSetupStage) -> String {
        switch stage {
        case .finding: return String(localized: "찾는 중", comment: "Power Base setup step: scanning for boards")
        case .verifyingBoard: return String(localized: "보드 확인 중", comment: "Power Base setup step: authenticating the board with its setup code")
        case .connecting: return String(localized: "연결 중", comment: "Power Base setup step: the hub and the board are setting up the connection")
        case .confirmingWithHub: return String(localized: "허브 확인 중", comment: "Power Base setup step: waiting for the hub to hear the new Power Base")
        case .done: return String(localized: "완료", comment: "Power Base setup step: done")
        }
    }

    /// One line under the progress list saying what is happening now.
    static func progressDetail(phase: PowerBaseEnrollmentBLEController.Phase, boardProgress: PowerBaseEnrollmentBLEController.BoardProgress?) -> String? {
        switch phase {
        case .authenticating:
            return String(localized: "설정 코드로 보드를 확인하고 있습니다. 몇 초 걸릴 수 있습니다.", comment: "Power Base setup progress")
        case .requestingHub, .preparingHub:
            return String(localized: "허브에 등록을 요청하고 있습니다.", comment: "Power Base setup progress")
        case .hubUncertain:
            return String(localized: "허브의 응답을 받지 못했습니다. 등록이 시작됐는지 아직 알 수 없습니다.", comment: "Power Base setup progress: the request to the hub got no answer")
        case .delivering:
            return String(localized: "보드에 가입 정보를 전달하고 있습니다.", comment: "Power Base setup progress")
        case .deliveryUncertain:
            return String(localized: "보드의 응답을 받지 못했습니다. 허브가 신호를 받는지 계속 확인합니다.", comment: "Power Base setup progress: the board's answer was lost")
        case .earlierHubSession:
            return String(localized: "이 기기가 먼저 시작한 등록이 허브에서 진행 중입니다. 끝날 때까지 기다리거나 취소할 수 있습니다.", comment: "Power Base setup progress: an earlier session of this device is still running on the hub")
        case .joining:
            switch boardProgress {
            case .enrolled, .unreachable:
                return String(localized: "Power Base가 네트워크에 연결했습니다. 허브가 첫 신호를 받으면 등록이 끝납니다.", comment: "Power Base setup progress: waiting for the hub's confirmation")
            default:
                return String(localized: "Power Base가 Thread 네트워크에 연결하고 있습니다. 1~2분 걸릴 수 있습니다.", comment: "Power Base setup progress")
            }
        case .cancelling:
            return String(localized: "등록을 취소하고 있습니다.", comment: "Power Base setup progress: cancelling")
        case .idle, .finished, .failed:
            return nil
        }
    }

    static func resultTitle(_ result: Result) -> String {
        switch result {
        case .registered: return String(localized: "Power Base를 등록했습니다", comment: "Power Base setup result title: success")
        case .partlyDone: return String(localized: "등록을 끝까지 확인하지 못했습니다", comment: "Power Base setup result title: the board may have joined but the hub did not confirm")
        case .notRegistered: return String(localized: "등록하지 못했습니다", comment: "Power Base setup result title: failure")
        case .cancelled: return String(localized: "등록을 취소했습니다", comment: "Power Base setup result title: cancelled")
        }
    }

    static func resultMessage(_ result: Result) -> String {
        switch result {
        case .registered:
            return String(localized: "허브가 새 Power Base의 신호를 받았습니다. 이제 센서 모듈을 Power Base에 끼우면 자동으로 연결되어 기기 목록에 나타납니다.", comment: "Power Base setup result: success, with what to do next")
        case .partlyDone:
            return String(localized: "Power Base는 가입 정보를 받았고 네트워크에 연결했을 수 있지만, 허브가 정해진 시간 안에 신호를 받지 못했습니다. 보드는 초기화하지 않았고 그대로 둡니다. 잠시 뒤 기기 목록에 나타나는지 확인하세요. 나타나지 않으면 Power Base의 전원을 껐다 켠 뒤 다시 등록하세요.", comment: "Power Base setup result: partly done; nothing was reset")
        case let .cancelled(boardMayHaveJoined):
            return boardMayHaveJoined
                ? String(localized: "취소를 요청했지만 Power Base가 이미 가입 정보를 받은 뒤였습니다. 보드는 초기화하지 않았습니다. 기기 목록에 나타나면 등록된 것이고, 나타나지 않으면 전원을 껐다 켠 뒤 다시 등록할 수 있습니다.", comment: "Power Base setup result: cancelled after the board had the request")
                : String(localized: "Power Base는 등록 전 상태 그대로입니다. 언제든 다시 등록할 수 있습니다.", comment: "Power Base setup result: cancelled; nothing reached the board, or the board confirmed that it stopped")
        case let .notRegistered(reason):
            return reasonMessage(reason)
        }
    }

    static func reasonMessage(_ reason: Reason) -> String {
        switch reason {
        case .wrongSetupCode:
            return String(localized: "설정 코드가 이 Power Base의 것과 맞지 않습니다. 코드를 다시 확인하세요. 한 번 켠 동안 다섯 번 틀리면 Power Base가 등록을 닫으며, 그때는 전원을 껐다 켜야 합니다.", comment: "Power Base setup failure: wrong setup code")
        case .boardLocked:
            return String(localized: "Power Base가 지금은 등록을 받지 않습니다. 등록 대기 시간이 지났거나 설정 코드를 여러 번 틀렸습니다. Power Base의 전원을 껐다 켠 뒤 다시 시도하세요.", comment: "Power Base setup failure: the board closed enrollment for this boot")
        case .boardBusy:
            return String(localized: "Power Base가 다른 등록을 처리하고 있습니다. 잠시 뒤 다시 시도하세요.", comment: "Power Base setup failure: another attempt is in progress on the board")
        case .boardNotWaiting:
            return String(localized: "이 Power Base는 이미 등록되어 있거나 연결하는 중입니다. 기기 목록을 확인하세요.", comment: "Power Base setup failure: the board is not waiting for enrollment")
        case .boardNeedsUpdate:
            return String(localized: "이 Power Base의 펌웨어는 앱에서 등록하고 삭제하는 기능을 지원하지 않습니다. Power Base 펌웨어를 업데이트해야 합니다. 허브에는 아무것도 요청하지 않았습니다.", comment: "Power Base setup failure: board firmware too old")
        case .differentBoard:
            return String(localized: "선택한 Power Base와 설정 코드로 확인된 Power Base가 다릅니다. 안전을 위해 등록하지 않았습니다. 목록에서 다시 선택하세요.", comment: "Power Base setup failure: the authenticated board is not the selected one")
        case .boardUnreachable:
            return String(localized: "Bluetooth로 Power Base에 연결하지 못했습니다. Power Base 가까이에서, 전원이 켜져 있는지 확인하고 다시 시도하세요.", comment: "Power Base setup failure: Bluetooth connection failed")
        case let .bluetooth(availability):
            return bluetoothMessage(availability) ?? String(localized: "Bluetooth를 사용할 수 없습니다.", comment: "Power Base setup failure: Bluetooth unavailable")
        case .hubNeedsUpdate:
            return String(localized: "연결된 허브가 앱에서 Power Base를 등록하는 기능을 지원하지 않습니다. 허브를 업데이트해야 합니다. Power Base에는 아무것도 전달하지 않았습니다.", comment: "Power Base setup failure: hub too old or enrollment not enabled")
        case .hubNotPaired:
            return String(localized: "허브가 이 기기의 연결 정보를 확인하지 못했습니다. 설정에서 허브에 다시 연결한 뒤 시도하세요. Power Base에는 아무것도 전달하지 않았습니다.", comment: "Power Base setup failure: this device is not (or no longer) paired with the hub")
        case .hubUnreachable:
            return String(localized: "허브에 연결하지 못했습니다. 허브가 켜져 있고 같은 네트워크에 있는지 확인한 뒤 다시 시도하세요.", comment: "Power Base setup failure: hub unreachable")
        case .hubBusy:
            return String(localized: "허브가 다른 기기의 Power Base 등록을 처리하고 있습니다. 끝난 뒤 다시 시도하세요.", comment: "Power Base setup failure: another device's enrollment session is running")
        case .alreadyRegistered:
            return String(localized: "이 Power Base는 이미 허브에 연결되어 있습니다. 기기 목록을 확인하세요.", comment: "Power Base setup failure: the hub already hears this Power Base")
        case .timedOut:
            return String(localized: "정해진 시간 안에 Power Base가 네트워크에 연결하지 못했습니다. Power Base는 등록 전 상태 그대로입니다. 허브 가까이에서 다시 시도하세요.", comment: "Power Base setup failure: the join attempt timed out; the board is unchanged")
        case .sourceChanged:
            return String(localized: "등록하는 동안 연결된 허브가 바뀌어 등록을 중단했습니다.", comment: "Power Base setup failure: the app switched to another hub")
        case .other:
            return String(localized: "등록을 시작하지 못했습니다. 다시 시도하세요.", comment: "Power Base setup failure: generic")
        }
    }

    /// What to do about Bluetooth, or `nil` when it is on.
    static func bluetoothMessage(_ availability: PowerBaseBLEAvailability) -> String? {
        switch availability {
        case .poweredOn: return nil
        case .unknown, .resetting:
            return String(localized: "Bluetooth를 준비하고 있습니다. 잠시만 기다리세요.", comment: "Power Base setup: Bluetooth state not known yet or resetting")
        case .poweredOff:
            return String(localized: "Bluetooth가 꺼져 있습니다. 제어 센터나 설정에서 Bluetooth를 켜면 자동으로 찾기 시작합니다.", comment: "Power Base setup: Bluetooth is off")
        case .denied:
            return String(localized: "이 앱의 Bluetooth 사용이 허용되어 있지 않습니다. 설정에서 조각보 홈의 Bluetooth를 허용하세요.", comment: "Power Base setup: Bluetooth permission denied")
        case .restricted:
            return String(localized: "이 기기에서는 Bluetooth 사용이 제한되어 있습니다.", comment: "Power Base setup: Bluetooth restricted")
        case .unsupported:
            return String(localized: "이 기기는 Bluetooth LE를 지원하지 않아 Power Base를 등록할 수 없습니다.", comment: "Power Base setup: no Bluetooth LE")
        }
    }

    /// Why the hub the app reads cannot be used, with what to do.
    static func hubMessage(_ ineligibility: PowerBaseHubIneligibility) -> String {
        switch ineligibility {
        case .simulatedData:
            return String(localized: "지금은 시뮬레이션 데이터를 보고 있습니다. Power Base를 등록하려면 설정에서 실제 허브를 선택하세요.", comment: "Power Base setup: the app shows simulated data")
        case .typedAddress, .noAddress:
            return String(localized: "Power Base를 등록하려면 설정의 '허브 찾기'에서 허브를 선택해야 합니다.", comment: "Power Base setup: no hub picked in Find hubs")
        case .notPaired:
            return String(localized: "이 기기가 아직 허브에 연결(페어링)되어 있지 않습니다. 설정의 '허브 설정 공유'에서 허브에 연결한 뒤 다시 시도하세요.", comment: "Power Base setup: this device is not paired with the selected hub")
        }
    }

    static var screenTitle: String { String(localized: "Power Base 추가", comment: "Power Base setup: screen title") }
    static var hubHeader: String { String(localized: "등록할 허브", comment: "Power Base setup: section header, the hub the Power Base will be registered with") }
    static var hubFooter: String { String(localized: "Power Base는 이 허브의 Thread 네트워크에 가입합니다.", comment: "Power Base setup: hub section footer") }
    static var openSettings: String { String(localized: "설정 열기", comment: "Power Base setup: button that opens the app's settings tab or the system settings") }
    static var findHeader: String { String(localized: "Power Base 선택", comment: "Power Base setup: section header of the scan list") }
    static var startFinding: String { String(localized: "주변에서 Power Base 찾기", comment: "Power Base setup: button that starts the Bluetooth scan") }
    static var startFindingHint: String { String(localized: "이 화면을 열면 Bluetooth로 주변의 등록되지 않은 Power Base를 자동으로 찾습니다. 찾기가 시작되지 않았다면 위 버튼을 누르세요.", comment: "Power Base setup: footer while the automatic search has not started; the button above starts it by hand") }
    static var findFooter: String { String(localized: "이 화면이 열려 있는 동안 Bluetooth로 주변의 등록되지 않은 Power Base를 자동으로 찾습니다. 찾는 것만으로는 Power Base에 연결하거나 등록하지 않습니다.", comment: "Power Base setup: footer of the scan list; the search is automatic and only looks") }
    static var finding: String { String(localized: "주변의 Power Base를 찾는 중입니다.", comment: "Power Base setup: scanning") }
    static var stillFinding: String { String(localized: "계속 찾고 있습니다. Power Base가 나타나면 여기에 표시됩니다.", comment: "Power Base setup: under the nothing-found advice; the search goes on") }
    static var findingPaused: String { String(localized: "지금은 찾고 있지 않습니다. 아래 '다시 찾기'를 누르세요.", comment: "Power Base setup: the list is empty and no search is running (after the app was away or the search stopped)") }
    static var findAgain: String { String(localized: "다시 찾기", comment: "Power Base setup: button that restarts the scan") }
    static var nothingFound: String { String(localized: "아직 찾지 못했습니다. Power Base의 전원이 켜져 있는지, 가까이 있는지 확인하세요. Power Base는 전원을 켠 뒤 15분 동안만 등록을 기다리므로, 시간이 지났다면 전원을 껐다 켜세요. 이미 등록된 Power Base는 여기에 나타나지 않습니다.", comment: "Power Base setup: nothing found after a while, with what to check") }
    static var codeHeader: String { String(localized: "설정 코드", comment: "Power Base setup: section header of the setup code field") }
    static var codePlaceholder: String { String(localized: "26자리 설정 코드", comment: "Power Base setup: placeholder of the setup code field") }
    static var codeFooter: String { String(localized: "Power Base와 함께 받은 26자리 코드(A–Z, 2–7)를 입력하세요. 코드는 이 화면에서만 쓰이며 저장되지 않습니다.", comment: "Power Base setup: what the setup code is; it is not stored") }
    static var paste: String { String(localized: "붙여넣기", comment: "Power Base setup: paste button for the setup code") }
    static var register: String { String(localized: "등록", comment: "Power Base setup: the button that starts the registration") }
    static var cancel: String { String(localized: "취소", comment: "Power Base setup: cancels a registration under way") }
    static var askHubAgain: String { String(localized: "허브에 다시 확인", comment: "Power Base setup: asks the hub again after a request without an answer") }
    static var retry: String { String(localized: "다시 시도", comment: "Power Base setup: back to the start for another attempt") }
    static var backToDevices: String { String(localized: "기기 목록으로", comment: "Power Base setup: closes the sheet after success") }
    static var progressHeader: String { String(localized: "진행 상태", comment: "Power Base setup: section header of the progress list") }
    static var nextHeader: String { String(localized: "다음 단계", comment: "Power Base setup: section header after success") }
    static var nextSensors: String { String(localized: "센서 모듈을 새 Power Base에 끼우세요. 따로 등록할 필요 없이 자동으로 연결됩니다.", comment: "Power Base setup: next step after success") }
    static var hubProblemHint: String { String(localized: "허브와의 연결이 잠시 끊겼습니다. 다시 연결되면 계속 확인합니다.", comment: "Power Base setup: a poll of the hub failed; it is retried") }
    static var backgroundHint: String { String(localized: "앱이 다시 화면에 보이면 등록을 이어서 진행합니다.", comment: "Power Base setup: the run is paused while the app is in the background") }

    static func codeProgress(_ typed: Int) -> String {
        String(localized: "\(typed) / 26자", comment: "Power Base setup: how many characters of the 26-character setup code are typed")
    }

    static func signal(_ rssi: Int) -> String {
        if rssi >= -60 { return String(localized: "신호 강함", comment: "Power Base setup: Bluetooth signal strength of a found board") }
        if rssi >= -80 { return String(localized: "신호 보통", comment: "Power Base setup: Bluetooth signal strength of a found board") }
        return String(localized: "신호 약함", comment: "Power Base setup: Bluetooth signal strength of a found board")
    }

    static func hubFallbackName(hubID: String) -> String {
        String(localized: "허브 ··\(String(hubID.suffix(4)))", comment: "Power Base setup: the hub's name when no readable name is known; the argument is the end of its id")
    }
}
