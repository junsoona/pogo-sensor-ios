#if DEBUG
import PowerBaseBLEKit
import SwiftUI
import UIKit
import XCTest
@testable import PogoHome

/// What "다른 허브에 연결하기" shows for each state: that the eight things it has to tell apart are
/// worded as eight things, and that every word of it exists in English and Spanish.
@MainActor
final class PowerBaseReenrollPresentationTests: XCTestCase {
    typealias Controller = PowerBaseLocalResetController
    typealias P = PowerBaseReenrollPresentation
    typealias T = PowerBaseReenrollText

    static let failures: [Controller.Failure] = [
        .invalidSetupCode, .randomnessUnavailable, .bluetooth(.poweredOff), .boardNotFound, .wrongSetupCode, .boardLocked, .boardUnreachable,
        .differentBoard, .boardNeedsUpdate, .windowNotOpen, .removalInProgress, .boardBusy, .resetNotStarted, .other,
    ]

    private func table(_ language: String, _ file: String) -> [String: Any] {
        guard let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: nil, localization: language),
              let dictionary = NSDictionary(contentsOf: url) as? [String: Any] else { return [:] }
        return dictionary
    }

    /// Every text of the screen that is a key of its own, as the app shows it in the current language.
    private var allTexts: [String] {
        var texts = [
            T.entryTitle, T.entrySubtitle, T.intro, T.introFooter, T.hubHeader, T.hubReadyFooter, T.hubNotReady, T.hubNotReadyConsequence,
            T.buttonHeader, T.buttonStep1, T.buttonStep2, T.buttonStep3, T.buttonFooter, T.findHeader, T.startFinding, T.startFindingHint, T.finding,
            T.nothingFound, T.codeFooter, T.verify, T.checkResult, T.backgroundHint, T.confirmExplanation, T.confirmOldHubRemains, T.eraseButton,
            T.declineButton, T.dialogTitle, T.dialogMessage, T.dialogConfirm, T.dialogCancel, T.registerNext, T.registerNextFooter, T.uncertainGuide,
            T.failedTitle, T.retry,
        ]
        texts += PowerBaseReenrollStage.allCases.map(T.stageTitle)
        texts += [Controller.Phase.connecting, .resetting].compactMap(T.progressDetail)
        texts += [Controller.Ready.resetVerified, .alreadyNotEnrolled].flatMap { [T.readyTitle($0), T.readyMessage($0)] }
        texts += [Controller.Uncertainty.answerLost, .boardStillWorking].flatMap { [T.uncertainTitle($0), T.uncertainMessage($0)] }
        texts += Self.failures.map(T.failureMessage)
        return texts
    }

    private let formatKeys = [
        "%@ 확인됨", "Power Base가 기다리는 시간이 약 %lld초 남았습니다. 시간이 지나면 아무것도 지우지 않고 원래대로 돌아갑니다.",
        "지우기 요청은 이미 Power Base로 보냈고, 그 결과를 아직 확인하지 못했습니다.",
    ]

    func testEveryWordIsTranslatedToEnglishAndSpanish() throws {
        // In Korean a text is its own key, so each can be looked up in the other tables.
        guard AppLanguage.current == .korean else { throw XCTSkip("looks the Korean texts up; run in Korean") }
        let texts = allTexts
        XCTAssertGreaterThan(texts.count, 60)
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
        let hangul = CharacterSet(charactersIn: "\u{AC00}"..."\u{D7A3}")
        var texts = allTexts
        texts += [T.confirmTitle("Power Base ··b3c4"), T.confirmTimeLeft(42), T.confirmTimeLeft(1), T.uncertainMessage(.checkFailed(.boardUnreachable))]
        for text in texts {
            XCTAssertFalse(text.isEmpty)
            if AppLanguage.current != .korean {
                XCTAssertNil(text.rangeOfCharacter(from: hangul), "left in Korean: \(text)")
            }
        }
        XCTAssertTrue(T.confirmTitle("Power Base ··b3c4").contains("Power Base ··b3c4"))
        XCTAssertTrue(T.confirmTimeLeft(42).contains("42"))
    }

    // MARK: - Eight things, told apart

    func testEachPartOfTheWayHasItsOwnStepOrSection() {
        XCTAssertNil(P.stage(of: .idle), "the BOOT button guide and the scan: no run yet")
        XCTAssertEqual(P.stage(of: .connecting), .verifyingBoard)
        XCTAssertEqual(P.stage(of: .checking), .verifyingBoard)
        XCTAssertEqual(P.stage(of: .awaitingConfirmation), .confirming)
        XCTAssertEqual(P.stage(of: .resetting), .resetting)
        XCTAssertEqual(P.stage(of: .ready(.resetVerified)), .readyToRegister)
        XCTAssertNil(P.stage(of: .uncertain(.answerLost)), "an unknown outcome is not a step of the progress list")
        XCTAssertNil(P.stage(of: .failed(.other)))
        XCTAssertEqual(Set(PowerBaseReenrollStage.allCases.map(T.stageTitle)).count, PowerBaseReenrollStage.allCases.count, "four different titles")
    }

    func testAcceptedInProgressVerifiedAndRegisteredAreNeverWordedAsEachOther() {
        let verified = T.readyTitle(.resetVerified)
        let registered = PowerBaseSetupText.resultTitle(.registered)
        XCTAssertNotEqual(verified, registered, "the reset being verified is not the new hub's registration")
        XCTAssertNotEqual(T.readyMessage(.resetVerified), PowerBaseSetupText.resultMessage(.registered))
        XCTAssertNotEqual(T.readyTitle(.resetVerified), T.readyTitle(.alreadyNotEnrolled), "nothing erased is not said as erased")
        XCTAssertNotEqual(T.stageTitle(.resetting), verified, "resetting (accepted, under way) is not verified")
        for uncertainty in [Controller.Uncertainty.answerLost, .boardStillWorking, .checkFailed(.boardUnreachable)] {
            XCTAssertNotEqual(T.uncertainTitle(uncertainty), verified)
            XCTAssertNotEqual(T.uncertainTitle(uncertainty), T.failedTitle, "a sent command is never shown as 'nothing was erased'")
            XCTAssertNotEqual(T.uncertainMessage(uncertainty), T.failureMessage(.other))
        }
        XCTAssertNotEqual(T.uncertainTitle(.answerLost), T.uncertainTitle(.boardStillWorking))
        XCTAssertNotEqual(T.verify, T.checkResult, "asking about a sent command is not offered as a new check-and-reset")
    }

    func testTheScanAndTheCodeAreShownExactlyWhenTheBoardHasToBeReached() {
        func shows(_ phase: Controller.Phase) -> Bool { P.showsFinding(PowerBaseReenrollScreenState(phase: phase)) }
        XCTAssertTrue(shows(.idle))
        XCTAssertTrue(shows(.uncertain(.answerLost)), "to check the result the board has to be reached again")
        for phase in [Controller.Phase.connecting, .checking, .awaitingConfirmation, .resetting, .ready(.resetVerified), .failed(.other)] {
            XCTAssertFalse(shows(phase), "\(phase)")
        }
    }

    func testAllFailuresHaveTheirOwnExplanation() {
        let messages = Self.failures.map(T.failureMessage)
        XCTAssertFalse(messages.contains(""))
        // boardNotFound and boardUnreachable share one text on purpose; everything else differs.
        XCTAssertEqual(Set(messages).count, Self.failures.count - 1)
    }
}

/// Renders "다른 허브에 연결하기" in each state to PNG -- only when `POGO_SCREEN_RENDER_DIR` is set
/// (pass `TEST_RUNNER_POGO_SCREEN_RENDER_DIR=…` to `xcodebuild test`; add `-testLanguage ko|en|es`).
/// Run it on a small iPhone, an iPad and "My Mac (Mac Catalyst)". No Bluetooth is used and nothing
/// is sent anywhere: the screen is drawn from plain states, and every identifier is made up.
@MainActor
final class PowerBaseReenrollRenderingTests: XCTestCase {
    private struct Variant {
        let name: String
        let size: CGSize
        var contentSize: UIContentSizeCategory = .large
        var style: UIUserInterfaceStyle = .light
    }

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private var platform: String { PlatformSupport.isMacCatalyst ? "mac" : isPhone ? "iphone" : "ipad" }

    private var variants: [Variant] {
        if PlatformSupport.isMacCatalyst {
            return [
                Variant(name: "narrow", size: CGSize(width: 480, height: 620)),
                Variant(name: "wide-dark", size: CGSize(width: 820, height: 900), style: .dark),
                Variant(name: "narrow-axxl", size: CGSize(width: 480, height: 620), contentSize: .accessibilityExtraExtraExtraLarge),
            ]
        }
        let screen = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.bounds.size ?? CGSize(width: 375, height: 812)
        let size = isPhone ? screen : CGSize(width: 504, height: 900)
        return [
            Variant(name: "regular", size: size),
            Variant(name: "dark", size: size, style: .dark),
            Variant(name: "axxl", size: size, contentSize: .accessibilityExtraExtraExtraLarge),
        ]
    }

    private static let states = [
        "start", "start-hub-not-ready", "bluetooth-off", "bluetooth-denied", "finding", "finding-nothing", "finding-paused", "found-code", "verifying", "confirm",
        "confirm-hub-not-ready", "resetting",
        "resetting-paused", "uncertain-answer-lost", "uncertain-still-working", "uncertain-check-failed", "ready-verified", "ready-not-enrolled",
        "ready-hub-not-ready", "failed-window", "failed-wrong-code", "failed-needs-update", "failed-removal",
    ]

    private static let boardID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private static let eui64 = "00124b0001a2b3c4"

    private func state(for name: String) -> (PowerBaseReenrollScreenState, PowerBaseReenrollForm) {
        let board = PowerBaseBLEDiscoveredBoard(id: Self.boardID, name: "POGO-PB-00124B0001A2B3C4", advertisedEUI64: Self.eui64, rssi: -52)
        var state = PowerBaseReenrollScreenState(availability: .poweredOn, hubName: "Jogakbo Hub (study)")
        var form = PowerBaseReenrollForm()
        let found = PowerBaseReenrollForm(didStartFinding: true, selectedBoardID: Self.boardID, setupCode: "MFRGGZDFMZTWQ2LKNNWG23TPOA")
        switch name {
        case "start": break
        case "start-hub-not-ready": state.hubIneligibility = .notPaired
        case "bluetooth-off", "bluetooth-denied":
            state.availability = name == "bluetooth-off" ? .poweredOff : .denied
            form.didStartFinding = true
        case "finding":
            // Entered a moment ago: looking, nothing yet.
            state.isScanning = true
            form.didStartFinding = true
        case "finding-paused":
            // The list is empty and nothing is looking (the app was away, or a run ended).
            form.didStartFinding = true
        case "finding-nothing":
            state.isScanning = true
            state.foundNothingSoFar = true
            form.didStartFinding = true
        case "found-code":
            state.boards = [board]
            form = found
        case "verifying": state.phase = .connecting
        case "confirm", "confirm-hub-not-ready":
            state.phase = .awaitingConfirmation
            state.boardIdentifier = Self.eui64
            state.windowSecondsLeft = 96
            if name == "confirm-hub-not-ready" { state.hubIneligibility = .typedAddress }
        case "resetting": state.phase = .resetting
        case "resetting-paused":
            state.phase = .resetting
            state.isSuspended = true
        case "uncertain-answer-lost", "uncertain-still-working", "uncertain-check-failed":
            state.phase = .uncertain(name == "uncertain-answer-lost" ? .answerLost : name == "uncertain-still-working" ? .boardStillWorking : .checkFailed(.boardUnreachable))
            state.hasUnresolvedOperation = true
            state.unresolvedBoardIdentifier = Self.eui64
            state.boards = [board]
            form = found
        case "ready-verified": state.phase = .ready(.resetVerified)
        case "ready-not-enrolled": state.phase = .ready(.alreadyNotEnrolled)
        case "ready-hub-not-ready":
            state.phase = .ready(.resetVerified)
            state.hubIneligibility = .notPaired
        case "failed-window": state.phase = .failed(.windowNotOpen)
        case "failed-wrong-code": state.phase = .failed(.wrongSetupCode)
        case "failed-needs-update": state.phase = .failed(.boardNeedsUpdate)
        case "failed-removal": state.phase = .failed(.removalInProgress)
        default: XCTFail("unknown state \(name)")
        }
        return (state, form)
    }

    private func outputDirectory() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["POGO_SCREEN_RENDER_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_POGO_SCREEN_RENDER_DIR to render screens")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return output
    }

    private var language: String { Bundle.main.preferredLocalizations.first ?? "ko" }

    /// `POGO_SCREEN_RENDER_ONLY` limits what is rendered, like in `PowerBaseProductRenderingTests`:
    /// "reenroll" for the whole screen, or state names.
    private func renders(_ state: String) -> Bool {
        guard let only = ProcessInfo.processInfo.environment["POGO_SCREEN_RENDER_ONLY"] else { return true }
        let names = only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return names.contains(state) || names.contains("reenroll") || names.contains("reenroll-\(state)")
    }

    func testRenderReenrollStates() async throws {
        let output = try outputDirectory()
        for variant in variants {
            for name in Self.states where renders(name) {
                let (state, form) = state(for: name)
                let view = NavigationStack {
                    List {
                        PowerBaseReenrollContent(state: state, form: .constant(form), qr: PowerBaseSetupQRIntake(camera: nil))
                    }
                    .sheetListSpacing()
                    .navigationTitle(Text(verbatim: PowerBaseReenrollText.entryTitle))
                    .navigationBarTitleDisplayMode(.inline)
                }
                try await render(view, variant: variant, named: "\(platform)-\(language)-reenroll-\(name)-\(variant.name)", in: output)
            }
        }
    }

    /// Every state builds its view tree without a render directory too, so this runs in every
    /// test run (the PNG test above is skipped without its directory).
    func testEveryStateBuildsItsSections() {
        for name in Self.states {
            let (state, form) = state(for: name)
            let host = UIHostingController(rootView: List { PowerBaseReenrollContent(state: state, form: .constant(form), qr: PowerBaseSetupQRIntake(camera: nil)) })
            host.view.frame = CGRect(x: 0, y: 0, width: 375, height: 700)
            host.view.layoutIfNeeded()
            XCTAssertNotNil(host.view, name)
        }
    }

    private func render(_ view: some View, variant: Variant, named name: String, in directory: URL) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        #if targetEnvironment(macCatalyst)
        scene.sizeRestrictions?.minimumSize = CGSize(width: 300, height: 300)
        scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(origin: CGPoint(x: 40, y: 40), size: variant.size)))
        try await Task.sleep(for: .milliseconds(600))
        #endif
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: variant.size)
        let host = UIHostingController(rootView: view)
        host.traitOverrides.userInterfaceStyle = variant.style
        host.traitOverrides.preferredContentSizeCategory = variant.contentSize
        if isPhone { host.traitOverrides.horizontalSizeClass = .compact }
        window.overrideUserInterfaceStyle = variant.style
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(700))
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        format.scale = 1
        let scrollView = Self.firstScrollView(in: window)
        var page = 1
        while true {
            let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                _ = window.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name)-p\(page).png"))
            guard let scrollView, page < 40 else { break }
            let maxOffset = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
            let current = scrollView.contentOffset.y
            guard current < maxOffset - 1 else { break }
            // Overlap a little, so no line falls between two pages.
            scrollView.setContentOffset(CGPoint(x: 0, y: min(current + scrollView.bounds.height * 0.8, maxOffset)), animated: false)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            page += 1
        }
        window.isHidden = true
        window.rootViewController = nil
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView, scrollView.contentSize.height > 0 { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}
#endif
