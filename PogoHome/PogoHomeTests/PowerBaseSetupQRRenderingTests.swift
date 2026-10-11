#if DEBUG
import PowerBaseBLEKit
import SwiftUI
import UIKit
import XCTest
@testable import PogoHome

/// Renders the QR code entry -- the rows under the setup code field on the three screens, and
/// the camera scanner -- in each state to PNG, for checking that nothing is cut off at the
/// largest text size, in a small window, in every language and in both appearances. Only when
/// `POGO_SCREEN_RENDER_DIR` is set (pass `TEST_RUNNER_POGO_SCREEN_RENDER_DIR=…` to
/// `xcodebuild test`; add `-testLanguage ko|en|es`); `POGO_SCREEN_RENDER_ONLY` limits it to
/// "qr" or to state names.
///
/// No camera is used: the scanner's camera is scripted and its viewfinder is a placeholder.
/// Every identifier and code in the pictures is made up.
@MainActor
final class PowerBaseSetupQRRenderingTests: XCTestCase {
    private typealias F = SetupQRFixtures
    private typealias Intake = PowerBaseSetupQRIntake

    private struct Variant {
        let name: String
        let size: CGSize
        var contentSize: UIContentSizeCategory = .large
        var style: UIUserInterfaceStyle = .light
    }

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private var platform: String { PlatformSupport.isMacCatalyst ? "mac" : isPhone ? "iphone" : "ipad" }
    private var language: String { Bundle.main.preferredLocalizations.first ?? "ko" }

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

    static let entryStates = ["setup-entry", "setup-filled", "setup-different-board", "setup-several-codes", "setup-reading-image", "reenroll-entry", "confirm-no-code"]
    static let scannerStates = ["scanner-preparing", "scanner-running", "scanner-different-board", "scanner-denied", "scanner-no-camera", "scanner-paused"]

    private func renders(_ state: String) -> Bool {
        guard let only = ProcessInfo.processInfo.environment["POGO_SCREEN_RENDER_ONLY"] else { return true }
        let names = only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return names.contains(state) || names.contains("qr") || names.contains("qr-\(state)")
    }

    private func outputDirectory() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["POGO_SCREEN_RENDER_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_POGO_SCREEN_RENDER_DIR to render screens")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return output
    }

    // MARK: States

    /// The Mac has no camera row; iPhone and iPad have one (here with a scripted camera).
    private func makeIntake(_ provider: FakeQRCameraProvider = FakeQRCameraProvider()) -> Intake {
        let intake = Intake(camera: PlatformSupport.isMacCatalyst ? nil : PowerBaseSetupQRCamera(provider: provider))
        intake.hubDidChange(EnrollmentFixtures.hubA)
        intake.screenDidAppear()
        return intake
    }

    private let board = PowerBaseBLEDiscoveredBoard(id: FakeBLEBoardProvider.boardID, name: "POGO-PB-00124B0001A2B3C4", advertisedEUI64: SetupQRFixtures.eui64, rssi: -52)

    /// One state of the code entry on one of the three screens, with what it must show.
    private func entry(_ state: String) throws -> (view: AnyView, intake: Intake, field: () -> PowerBaseSetupCodeField) {
        let intake = makeIntake()
        func read(_ reading: PowerBaseSetupQRReading?, into field: Binding<PowerBaseSetupCodeField>, target: Intake.Target) throws {
            intake.targetDidChange(target)
            guard let reading else { return }
            let ticket = try XCTUnwrap(PowerBaseSetupQRRows.beginReadingImage(intake: intake, target: target, field: field))
            intake.complete(ticket, with: reading)
        }
        if state.hasPrefix("reenroll") {
            var form = PowerBaseReenrollForm(didStartFinding: true)
            form.select(board)
            let box = RenderBox(form)
            try read(nil, into: box.binding.code, target: F.target)
            let screenState = PowerBaseReenrollScreenState(phase: .idle, availability: .poweredOn, boards: [board], hubName: "Jogakbo Hub (living-room)")
            return (AnyView(PowerBaseReenrollContent(state: screenState, form: box.binding, qr: intake)), intake, { box.value.code })
        }
        if state.hasPrefix("confirm") {
            let provider = FakeBLEBoardProvider(board: FakeBoard())
            let controller = PowerBaseReleaseConfirmationController(
                powerBaseIdentifier: F.eui64, provider: provider, transport: FakeRemovalHub(),
                credentials: InMemoryHubCredentialStore([EnrollmentFixtures.credential()]), quietScanPeriod: .seconds(60)
            )
            controller.targetDidChange(EnrollmentFixtures.pairedTarget())
            controller.activate()
            controller.startScanning()
            var form = PowerBaseReleaseConfirmationForm(didStartFinding: true)
            form.select(controller.boards.first)
            let box = RenderBox(form)
            try read(.symbols([]), into: box.binding.code, target: Intake.Target(boardID: board.id, boardEUI64: F.eui64, requiredEUI64: F.eui64))
            return (AnyView(PowerBaseReleaseConfirmationContent(controller: controller, form: box.binding, qr: intake)), intake, { box.value.code })
        }
        let provider = FakeBLEBoardProvider(board: FakeBoard())
        let controller = PowerBaseEnrollmentBLEController(
            provider: provider, transport: FakeEnrollmentHub(), credentials: InMemoryHubCredentialStore([EnrollmentFixtures.credential()]),
            quietScanPeriod: .seconds(60), requireManagement: true
        )
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        controller.activate()
        controller.startScanning()
        var form = PowerBaseSetupForm(didStartFinding: true)
        form.select(provider.boards[0])
        let box = RenderBox(form)
        switch state {
        case "setup-filled": try read(.symbols([F.text]), into: box.binding.code, target: F.target)
        case "setup-different-board": try read(.symbols([F.otherText]), into: box.binding.code, target: F.target)
        case "setup-several-codes": try read(.symbols([F.text, F.otherText]), into: box.binding.code, target: F.target)
        case "setup-reading-image":
            intake.targetDidChange(F.target)
            XCTAssertNotNil(PowerBaseSetupQRRows.beginReadingImage(intake: intake, target: F.target, field: box.binding.code))
        default: try read(nil, into: box.binding.code, target: F.target)
        }
        return (AnyView(PowerBaseSetupContent(controller: controller, form: box.binding, hubName: "Jogakbo Hub (living-room)", qr: intake)), intake, { box.value.code })
    }

    /// The camera scanner in one state; `nil` where there is no camera scan (Mac).
    private func scanner(_ state: String) async throws -> (view: AnyView, intake: Intake, provider: FakeQRCameraProvider)? {
        guard !PlatformSupport.isMacCatalyst else { return nil }
        let provider = FakeQRCameraProvider()
        switch state {
        case "scanner-preparing": provider.holdsStart = true
        case "scanner-denied": provider.access = .denied
        case "scanner-no-camera": provider.hasCamera = false
        default: break
        }
        let intake = makeIntake(provider)
        intake.targetDidChange(F.target)
        let box = QRFieldBox()
        box.field.select(boardEUI64: F.eui64)
        XCTAssertNotNil(intake.begin(.camera, for: F.target) { box.apply($0) })
        let camera = try XCTUnwrap(intake.camera)
        switch state {
        case "scanner-preparing": try await eventually { camera.state == .starting }
        case "scanner-denied": try await eventually { camera.state == .denied }
        case "scanner-no-camera": try await eventually { camera.state == .unavailable }
        case "scanner-paused":
            try await eventually { camera.state == .running }
            intake.sceneDidEnterBackground()
        case "scanner-different-board":
            try await eventually { camera.state == .running }
            provider.show(F.otherText)
            try await eventually { intake.problem == .differentBoard }
        default: try await eventually { camera.state == .running }
        }
        let sheet = PowerBaseSetupQRScannerSheet(intake: intake, boardLabel: PowerBaseSetupPresentation.label(forAdvertisedEUI64: F.eui64))
        return (AnyView(sheet), intake, provider)
    }

    // MARK: What the states are (runs always)

    func testTheEntryStatesAreWhatTheyAreCalledAndBuildTheirRows() throws {
        let expected: [String: (problem: Intake.Problem?, didFill: Bool, isReading: Bool, text: String)] = [
            "setup-entry": (nil, false, false, ""), "setup-filled": (nil, true, false, F.setupCode), "setup-different-board": (.differentBoard, false, false, ""),
            "setup-several-codes": (.severalCodes, false, false, ""), "setup-reading-image": (nil, false, true, ""), "reenroll-entry": (nil, false, false, ""),
            "confirm-no-code": (.noCodeInImage, false, false, ""),
        ]
        XCTAssertEqual(Set(expected.keys), Set(Self.entryStates))
        for state in Self.entryStates {
            let (view, intake, field) = try entry(state)
            let host = UIHostingController(rootView: List { view })
            host.view.frame = CGRect(x: 0, y: 0, width: 375, height: 700)
            host.view.layoutIfNeeded()
            let want = try XCTUnwrap(expected[state])
            XCTAssertEqual(intake.problem, want.problem, state)
            XCTAssertEqual(intake.didFill, want.didFill, state)
            XCTAssertEqual(intake.imageStage == .reading, want.isReading, state)
            XCTAssertEqual(field().text, want.text, state)
            XCTAssertEqual(intake.camera == nil, PlatformSupport.isMacCatalyst, "the camera row is there on iPhone and iPad, not on the Mac")
        }
    }

    func testTheScannerStatesAreWhatTheyAreCalled() async throws {
        let expected: [String: PowerBaseSetupQRCamera.State] = [
            "scanner-preparing": .starting, "scanner-running": .running, "scanner-different-board": .running, "scanner-denied": .denied,
            "scanner-no-camera": .unavailable, "scanner-paused": .paused,
        ]
        for state in Self.scannerStates {
            guard let (view, intake, provider) = try await scanner(state) else { throw XCTSkip("no camera scan on the Mac") }
            let host = UIHostingController(rootView: view)
            host.view.frame = CGRect(x: 0, y: 0, width: 375, height: 700)
            host.view.layoutIfNeeded()
            XCTAssertEqual(intake.camera?.state, expected[state], state)
            XCTAssertEqual(provider.isRunning, state == "scanner-running" || state == "scanner-different-board", state)
            XCTAssertEqual(provider.accessRequests, 0, "\(state): the scripted camera was authorized or refused beforehand")
            intake.cancel()
            provider.finishStarts()
        }
    }

    /// Every text of the QR code entry, as the app shows it in the current language.
    private var allTexts: [String] {
        typealias T = PowerBaseSetupQRText
        return Intake.Problem.allCases.map(T.problemMessage) + [
            T.scanButton, T.photoButton, T.fileButton, T.readingImage, T.filled, T.scannerTitle, T.close, T.viewfinderLabel, T.scannerFootnote, T.cameraPreparing,
            T.cameraPaused, T.cameraDenied, T.cameraRestricted, T.cameraUnavailable, T.cameraFailed,
        ]
    }

    /// Every message a user can be shown exists in the app's language and names no secret.
    func testEveryMessageHasWordsAndShowsNothingThatWasRead() {
        typealias T = PowerBaseSetupQRText
        let all = allTexts + [T.scannerHint("Power Base ··b3c4")]
        XCTAssertEqual(all.count, Intake.Problem.allCases.count + 16)
        XCTAssertEqual(Set(all).count, all.count, "no two states share their words")
        let hangul = CharacterSet(charactersIn: "\u{AC00}"..."\u{D7A3}")
        for text in all {
            XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(text.contains(F.setupCode))
            XCTAssertFalse(text.contains("POGO-PB:"))
            XCTAssertFalse(text.contains(F.eui64))
            if AppLanguage.current != .korean {
                XCTAssertNil(text.rangeOfCharacter(from: hangul), "left in Korean: \(text)")
            }
        }
        XCTAssertTrue(T.scannerHint("Power Base ··b3c4").contains("Power Base ··b3c4"))
    }

    func testEveryMessageIsTranslatedToEnglishAndSpanish() throws {
        // In Korean a text is its own key, so each can be looked up in the other tables.
        guard AppLanguage.current == .korean else { throw XCTSkip("looks the Korean texts up; run in Korean") }
        func table(_ language: String, _ file: String) -> [String: Any] {
            guard let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: nil, localization: language),
                  let dictionary = NSDictionary(contentsOf: url) as? [String: Any] else { return [:] }
            return dictionary
        }
        for language in ["en", "es"] {
            let strings = table(language, "Localizable.strings")
            for text in allTexts {
                let translated = strings[text] as? String
                XCTAssertNotNil(translated, "\(language) has no translation for: \(text)")
                XCTAssertNotEqual(translated, text, "\(language): \(text)")
            }
            XCTAssertNotNil(strings["%@의 설정 QR 코드 하나만 화면 안에 비추세요."], language)
            // The camera's purpose, shown by the system when it asks: in every language, on iOS only.
            let purpose = table(language, "InfoPlist.strings")["NSCameraUsageDescription"] as? String
            XCTAssertEqual(purpose?.contains("Jogakbo Home"), true, language)
        }
        // The Info.plist itself, not its localized strings: the app declares the camera's purpose
        // (one setting of the app target, so the Mac bundle carries the words too, unused), and
        // no purpose for the photo library.
        let declared = Bundle.main.infoDictionary?["NSCameraUsageDescription"] as? String
        XCTAssertEqual(declared?.isEmpty, false)
        XCTAssertNil(Bundle.main.infoDictionary?["NSPhotoLibraryUsageDescription"], "the photo picker needs no library access")
        XCTAssertNil(Bundle.main.infoDictionary?["NSPhotoLibraryAddUsageDescription"])
    }

    // MARK: Pictures

    func testRenderTheCodeEntryStates() async throws {
        let output = try outputDirectory()
        for variant in variants {
            for state in Self.entryStates where renders(state) {
                let (content, _, _) = try entry(state)
                let view = NavigationStack {
                    List { content }
                        .sheetListSpacing()
                        .navigationTitle(Text(verbatim: PowerBaseSetupText.screenTitle))
                        .navigationBarTitleDisplayMode(.inline)
                }
                try await render(view, variant: variant, named: "\(platform)-\(language)-qr-\(state)-\(variant.name)", in: output)
            }
        }
    }

    func testRenderTheScannerStates() async throws {
        let output = try outputDirectory()
        for variant in variants {
            for state in Self.scannerStates where renders(state) {
                guard let (view, intake, provider) = try await scanner(state) else { throw XCTSkip("no camera scan on the Mac") }
                try await render(view, variant: variant, named: "\(platform)-\(language)-qr-\(state)-\(variant.name)", in: output)
                intake.cancel()
                provider.finishStarts()
            }
        }
    }

    /// One PNG per screenful, scrolling until the end, like `PowerBaseProductRenderingTests`.
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

/// A form the rendered rows write into.
@MainActor
@Observable
private final class RenderBox<Form> {
    var value: Form
    init(_ value: Form) { self.value = value }
    var binding: Binding<Form> { Binding(get: { self.value }, set: { self.value = $0 }) }
}
#endif
