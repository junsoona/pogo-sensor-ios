#if DEBUG
import PowerBaseBLEKit
import XCTest
@testable import PogoHome

/// What the product "Power Base 추가" screen shows for each state: the mapping from the
/// controller's states to steps, results and reasons, and that every word of it exists in English
/// and Spanish.
@MainActor
final class PowerBaseSetupPresentationTests: XCTestCase {
    typealias P = PowerBaseSetupPresentation
    typealias Controller = PowerBaseEnrollmentBLEController

    private func session(_ state: PowerBaseEnrollmentSession.State) -> PowerBaseEnrollmentSession { EnrollmentFixtures.session(state) }

    private func finished(_ state: PowerBaseEnrollmentSession.State, delivery: Controller.Delivery, board: Controller.BoardProgress? = nil) -> Controller.Phase {
        .finished(Controller.Outcome(session: session(state), delivery: delivery, boardProgress: board, cleanup: nil))
    }

    private let cleanup = Controller.Cleanup(hub: .notNeeded, board: .notNeeded)

    // MARK: - Success

    func testOnlyTheHubsHeartbeatIsRegistered() {
        XCTAssertEqual(P.result(of: finished(.heartbeatReceived, delivery: .accepted, board: .enrolled)), .registered)
        // Everything else that looks like progress is not.
        for state in [PowerBaseEnrollmentSession.State.preparing, .waitingForHeartbeat, .expired, .failed] {
            XCTAssertNotEqual(P.result(of: finished(state, delivery: .accepted, board: .enrolled)), .registered, "\(state)")
        }
        for phase in [Controller.Phase.joining(session(.waitingForHeartbeat)), .delivering(session(.waitingForHeartbeat)), .deliveryUncertain(session(.waitingForHeartbeat))] {
            XCTAssertNil(P.result(of: phase), "a run under way has no result")
        }
    }

    func testAnEndWithoutTheHeartbeatAfterDeliveryIsPartlyDone() {
        for state in [PowerBaseEnrollmentSession.State.expired, .failed] {
            XCTAssertEqual(P.result(of: finished(state, delivery: .accepted, board: .enrolled)), .partlyDone)
            XCTAssertEqual(P.result(of: finished(state, delivery: .uncertain)), .partlyDone, "a start whose answer was lost may have arrived")
        }
        XCTAssertEqual(P.result(of: finished(.expired, delivery: .notSent)), .notRegistered(.timedOut), "nothing reached the board")
    }

    func testCancellingSaysWhetherTheBoardMayHaveJoined() {
        XCTAssertEqual(P.result(of: finished(.cancelled, delivery: .notSent)), .cancelled(boardMayHaveJoined: false))
        XCTAssertEqual(P.result(of: finished(.cancelled, delivery: .accepted)), .cancelled(boardMayHaveJoined: true))
        XCTAssertEqual(P.result(of: finished(.cancelled, delivery: .uncertain)), .cancelled(boardMayHaveJoined: true))
        // Only the board's own word that it stopped settles a request that had reached it.
        func cancelled(board: Controller.BoardCancel) -> Controller.Phase {
            .finished(Controller.Outcome(session: session(.cancelled), delivery: .accepted, boardProgress: .joining, cleanup: .init(hub: .cancelled(session(.cancelled)), board: board)))
        }
        XCTAssertEqual(P.result(of: cancelled(board: .taken)), .cancelled(boardMayHaveJoined: false))
        for board in [Controller.BoardCancel.unconfirmed, .notDelivered, .refused(.busy), .nothingToCancel] {
            XCTAssertEqual(P.result(of: cancelled(board: board)), .cancelled(boardMayHaveJoined: true), "\(board)")
        }
    }

    // MARK: - Steps

    func testTheStepsFollowTheRunAndAFinishedRunShowsNoOldProgress() {
        XCTAssertNil(P.stage(phase: .idle, boardProgress: nil))
        XCTAssertEqual(P.stage(phase: .authenticating, boardProgress: nil), .verifyingBoard)
        XCTAssertEqual(P.stage(phase: .requestingHub, boardProgress: nil), .connecting)
        XCTAssertEqual(P.stage(phase: .preparingHub(session(.preparing)), boardProgress: nil), .connecting)
        XCTAssertEqual(P.stage(phase: .joining(session(.waitingForHeartbeat)), boardProgress: .joining), .connecting)
        XCTAssertEqual(P.stage(phase: .joining(session(.waitingForHeartbeat)), boardProgress: .attaching), .connecting)
        XCTAssertEqual(P.stage(phase: .joining(session(.waitingForHeartbeat)), boardProgress: .enrolled), .confirmingWithHub)
        XCTAssertEqual(P.stage(phase: finished(.heartbeatReceived, delivery: .accepted, board: .attaching), boardProgress: .attaching), .done,
                       "the board's last word does not matter once the hub confirmed")
        XCTAssertNil(P.stage(phase: finished(.expired, delivery: .accepted, board: .attaching), boardProgress: .attaching))
        XCTAssertNil(PowerBaseSetupText.progressDetail(phase: finished(.heartbeatReceived, delivery: .accepted, board: .attaching), boardProgress: .attaching),
                     "no 'joining'/'attaching' line on a finished screen")
    }

    // MARK: - Failures

    func testFailuresAreToldApart() {
        let cases: [(Controller.Failure, P.Reason)] = [
            (.authenticationFailed, .wrongSetupCode),
            (.boardProofMismatch, .wrongSetupCode),
            (.handshakeRefused, .boardLocked),
            (.boardClosed, .boardLocked),
            (.differentBoard(actual: "00124b0001a2ffff"), .differentBoard),
            (.boardNotWaiting("enrolled"), .boardNotWaiting),
            (.boardBusy, .boardBusy),
            (.boardNeedsUpdate, .boardNeedsUpdate),
            (.boardNotFound, .boardUnreachable),
            (.connectionFailed("timeout"), .boardUnreachable),
            (.bluetooth(.poweredOff), .bluetooth(.poweredOff)),
            (.credentialUnavailable, .hubNotPaired),
            (.hub(.unauthorized, board: nil), .hubNotPaired),
            (.hub(.certificateMismatch, board: nil), .hubNotPaired),
            (.hub(.managementNotSupported, board: nil), .hubNeedsUpdate),
            (.hub(.bridgeEndpointNotSupported, board: nil), .hubNeedsUpdate),
            (.hub(.unreachable("timeout"), board: nil), .hubUnreachable),
            (.hub(.powerBaseAlreadyConnected, board: nil), .alreadyRegistered),
            (.hubEndpoint(.managementMissing, cleanup: cleanup), .hubNeedsUpdate),
            (.boardAttemptFailed(result: 3, cleanup: cleanup), .timedOut),
            (.boardUnreachable(cleanup: cleanup), .boardUnreachable),
            (.sourceChanged, .sourceChanged),
        ]
        for (failure, reason) in cases {
            XCTAssertEqual(P.result(of: .failed(failure)), .notRegistered(reason), "\(failure)")
            XCTAssertFalse(PowerBaseSetupText.reasonMessage(reason).isEmpty)
        }
        // Authentication, time-out, hub and partial completion never share a message.
        let messages = [P.Reason.wrongSetupCode, .timedOut, .hubUnreachable, .hubNeedsUpdate, .boardNeedsUpdate, .differentBoard].map(PowerBaseSetupText.reasonMessage)
            + [PowerBaseSetupText.resultMessage(.partlyDone)]
        XCTAssertEqual(Set(messages).count, messages.count)
    }

    func testNoMessageTellsTheUserToResetTheBoardOrClaimsItWasReset() {
        // The Korean source is what every translation follows; only checked in Korean.
        guard AppLanguage.current == .korean else { return }
        let texts = [PowerBaseSetupText.resultMessage(.partlyDone), PowerBaseSetupText.resultMessage(.cancelled(boardMayHaveJoined: true))]
        for text in texts {
            XCTAssertTrue(text.contains("초기화하지 않았"), text)
            XCTAssertFalse(text.contains("초기화했"), text)
            XCTAssertFalse(text.contains("초기화하세요"), text)
        }
    }

    // MARK: - The scan list and the code

    func testOneRowPerBoardWithTheStrongestSignalAndNoRowWithoutAnIdentity() {
        func found(_ id: String, _ eui64: String?, _ rssi: Int) -> PowerBaseBLEDiscoveredBoard {
            PowerBaseBLEDiscoveredBoard(id: UUID(uuidString: id)!, name: eui64.map { "POGO-PB-" + $0.uppercased() } ?? "Other", advertisedEUI64: eui64, rssi: rssi)
        }
        let first = "11111111-2222-3333-4444-555555555551", second = "11111111-2222-3333-4444-555555555552"
        let third = "11111111-2222-3333-4444-555555555553", fourth = "11111111-2222-3333-4444-555555555554"
        let rows = P.selectableBoards([
            found(first, "00124b0001a2b3c4", -80), found(second, "00124b0001a2b3c5", -60), found(third, "00124b0001a2b3c4", -50), found(fourth, nil, -30),
        ])
        XCTAssertEqual(rows.map(\.advertisedEUI64), ["00124b0001a2b3c4", "00124b0001a2b3c5"], "in the order first seen")
        XCTAssertEqual(rows.first?.id, UUID(uuidString: third), "the stronger of two sightings of one board")
        XCTAssertEqual(P.label(forAdvertisedEUI64: "00124b0001a2b3c4"), "Power Base ··b3c4", "the same label the device list uses")
        XCTAssertEqual(P.label(forAdvertisedEUI64: "00124b0001a2b3c4"), PowerBase(hardwareIdentifier: "00124b0001a2b3c4", isOnline: true, moduleCount: 0, onlineModuleCount: 0).shortLabel)
    }

    func testTheCodeHintCountsWithoutEverChangingTheCode() {
        XCTAssertEqual(P.typedSetupCodeLength(""), 0)
        XCTAssertEqual(P.typedSetupCodeLength("  abcd\n"), 4)
        XCTAssertEqual(P.typedSetupCodeLength(EnrollmentFixtures.setupCode), PowerBaseSetupCode.length)
        // A code with a wrong character is not repaired into another code.
        XCTAssertNil(PowerBaseSetupCode.normalized(String(EnrollmentFixtures.setupCode.dropLast()) + "1"))
        XCTAssertNil(PowerBaseSetupCode.normalized(String(EnrollmentFixtures.setupCode.dropLast())))
        XCTAssertEqual(PowerBaseSetupCode.normalized(" " + EnrollmentFixtures.setupCode.lowercased() + "\n"), EnrollmentFixtures.setupCode)
    }

    // MARK: - Wording in every language

    private func table(_ language: String, _ file: String) -> [String: Any] {
        guard let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: nil, localization: language),
              let dictionary = NSDictionary(contentsOf: url) as? [String: Any] else { return [:] }
        return dictionary
    }

    /// Every text of the two product screens, as the app shows it in the current language.
    private var allTexts: [String] {
        typealias S = PowerBaseSetupText
        typealias M = PowerBaseManagementText
        var texts: [String] = PowerBaseSetupStage.allCases.map(S.stageTitle)
        let phases: [Controller.Phase] = [
            .authenticating, .requestingHub, .hubUncertain, .preparingHub(session(.preparing)), .delivering(session(.waitingForHeartbeat)),
            .deliveryUncertain(session(.waitingForHeartbeat)), .earlierHubSession(session(.waitingForHeartbeat)), .cancelling,
        ]
        texts += phases.compactMap { S.progressDetail(phase: $0, boardProgress: nil) }
        texts += [Controller.BoardProgress.joining, .enrolled].compactMap { S.progressDetail(phase: .joining(session(.waitingForHeartbeat)), boardProgress: $0) }
        let results: [P.Result] = [.registered, .partlyDone, .notRegistered(.other), .cancelled(boardMayHaveJoined: true), .cancelled(boardMayHaveJoined: false)]
        texts += results.map(S.resultTitle) + results.map(S.resultMessage)
        let reasons: [P.Reason] = [
            .wrongSetupCode, .boardLocked, .boardBusy, .boardNotWaiting, .boardNeedsUpdate, .differentBoard, .boardUnreachable, .hubNeedsUpdate, .hubNotPaired,
            .hubUnreachable, .hubBusy, .alreadyRegistered, .timedOut, .sourceChanged, .other,
        ]
        texts += reasons.map(S.reasonMessage)
        texts += [PowerBaseBLEAvailability.unknown, .poweredOff, .denied, .restricted, .unsupported].compactMap(S.bluetoothMessage)
        texts += [PowerBaseHubIneligibility.simulatedData, .typedAddress, .notPaired].map(S.hubMessage)
        texts += [
            S.screenTitle, S.hubHeader, S.hubFooter, S.openSettings, S.findHeader, S.startFinding, S.startFindingHint, S.finding, S.findAgain, S.nothingFound,
            S.codeHeader, S.codePlaceholder, S.codeFooter, S.paste, S.register, S.cancel, S.askHubAgain, S.retry, S.backToDevices, S.progressHeader, S.nextHeader,
            S.nextSensors, S.hubProblemHint, S.backgroundHint, S.signal(-40), S.signal(-70), S.signal(-95),
        ]
        texts += [
            M.sheetTitle, M.statusHeader, M.removalHeader, M.deleteHeader, M.delete, M.deleteConfirm, M.keep, M.cancelRemoval, M.requesting, M.cancelling,
            M.dismissFailure, M.listHeader, M.refreshProblem, M.deleteFooter, M.confirmErase, M.confirmEraseWhenUnknown, M.cleanupPending,
            M.confirmLater, M.confirmRegisterAgain, M.confirmOffline,
            M.connection(of: nil, isCurrentStateVerified: true),
            M.connection(of: PowerBase(hardwareIdentifier: "00124b0001a2b3c4", isOnline: true, moduleCount: 0, onlineModuleCount: 0), isCurrentStateVerified: false),
        ]
        let presentations: [PowerBaseRemoval.Presentation] = [
            .waitingForPowerBase, .inProgress, .resultUnknown, .removedFromListUnconfirmed, .finishing, .awaitingEraseConfirmation, .completed,
            .cancelled, .superseded,
        ]
        texts += presentations.map(M.removalTitle) + presentations.map(M.removalMessage)
        let unavailable: [PowerBaseManagementPresentation.Availability] = [
            .hubNotEligible(.simulatedData), .hubNotEligible(.noAddress), .hubNotEligible(.notPaired), .hubUnsupported, .powerBaseUnsupported, .gone,
        ]
        texts += unavailable.compactMap(M.unavailableMessage)
        let errors: [PowerBaseRemovalError] = [
            .unauthorized, .unknownPowerBase, .enrollmentInProgress, .notCancellable(nil), .unavailable("x"), .unreachable("x"), .rejected("x"),
            .capacityFull, .receiptRejected,
        ]
        texts += errors.map(M.requestFailureMessage) + [M.failureMessage(.credentialUnavailable)]
        // "허브 목록에서 제거".
        texts += [
            M.forgetHeader, M.forgetExplanation, M.forgetFooter, M.forgetConfirm, M.forgetRequesting, M.forgetResultUnknown, M.forgetRetry,
        ]
        let forgetErrors: [PowerBaseForgetError] = [
            .unauthorized, .notSupported, .notListed, .online, .staleRecord, .enrollmentInProgress, .capacityFull, .unavailable("x"),
        ]
        texts += forgetErrors.map { M.forgetFailureMessage(.request($0)) }
        // "삭제 확인".
        typealias C = PowerBaseReleaseConfirmationText
        texts += [C.intro(.released), C.intro(.resultUnknown), C.backgroundHint, C.introFooter, C.findHeader, C.startFinding, C.startFindingHint, C.finding, C.nothingFound, C.codeFooter, C.done, C.failedTitle, C.sendAgain]
        texts += C.steps
        let confirmationFailures: [PowerBaseReleaseConfirmationController.Failure] = [
            .invalidSetupCode, .differentBoard, .boardNeedsUpdate, .noReceipt, .hub(.notSupported), .hub(.unreachable("x")),
        ]
        texts += confirmationFailures.map(C.failureMessage)
        return texts
    }

    /// The keys with a number or a name in them, which `allTexts` cannot look up by their text.
    private let formatKeys = [
        "%lld / 26자", "허브 ··%@", "연결된 센서 %lld개", "%@ 삭제", "%@ 삭제 완료", "%@ 허브 목록에서 제거", "%@ 허브 목록에서 제거됨",
        "이 Power Base와 연결된 센서 %lld개가 기기 목록과 Apple 홈에서 사라집니다.",
    ]

    func testEveryWordOfTheProductScreensIsTranslatedToEnglishAndSpanish() throws {
        // In Korean a text is its own key, so each can be looked up in the other tables.
        guard AppLanguage.current == .korean else { throw XCTSkip("looks the Korean texts up; run in Korean") }
        let texts = allTexts
        XCTAssertGreaterThan(texts.count, 159)
        for language in ["en", "es"] {
            let strings = table(language, "Localizable.strings")
            let plurals = table(language, "Localizable.stringsdict")
            for text in texts {
                let translated = strings[text] as? String
                XCTAssertNotNil(translated, "\(language) has no translation for: \(text)")
                XCTAssertNotEqual(translated, text, "\(language): \(text)")
            }
            for key in formatKeys {
                XCTAssertTrue(strings[key] != nil || plurals[key] != nil, "\(language) has no translation for: \(key)")
            }
        }
    }

    func testTheTextsAreInTheLanguageTheAppRunsIn() {
        // Whatever language the test runs in, no text falls back to an empty string, and outside
        // Korean none is left in Korean.
        let hangul = CharacterSet(charactersIn: "\u{AC00}"..."\u{D7A3}")
        for text in allTexts {
            XCTAssertFalse(text.isEmpty)
            if AppLanguage.current != .korean {
                XCTAssertNil(text.rangeOfCharacter(from: hangul), "left in Korean: \(text)")
            }
        }
        XCTAssertFalse(PowerBaseSetupText.codeProgress(7).isEmpty)
        XCTAssertTrue(PowerBaseSetupText.codeProgress(7).contains("7"))
        XCTAssertTrue(PowerBaseManagementText.sensors(3).contains("3"))
        XCTAssertTrue(PowerBaseManagementText.confirmTitle(label: "Power Base ··b3c4").contains("Power Base ··b3c4"))
        XCTAssertTrue(PowerBaseManagementText.confirmMessage(sensorCount: 2, isOnline: false).contains("2"))
        XCTAssertTrue(PowerBaseSetupText.hubFallbackName(hubID: EnrollmentFixtures.hubA).contains("aaaa"))
    }
}
#endif
