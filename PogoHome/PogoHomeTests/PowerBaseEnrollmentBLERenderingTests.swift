#if DEBUG
import PowerBaseBLEKit
import SwiftUI
import UIKit
import XCTest
@testable import PogoHome

/// Renders the DEBUG "BLE 등록 시험" screen in each state to PNG, for checking that buttons, long
/// identifiers and messages are never cut off and that every state scrolls -- only when
/// `POGO_SCREEN_RENDER_DIR` is set (pass `TEST_RUNNER_POGO_SCREEN_RENDER_DIR=…` to `xcodebuild
/// test`; add `-testLanguage en|es` for the other languages). Run it on a small iPhone, an iPad and
/// "My Mac (Mac Catalyst)". Nothing is sent anywhere and no Bluetooth is used: the hub and the
/// board are scripted.
@MainActor
final class PowerBaseEnrollmentBLERenderingTests: XCTestCase {
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
        // iPad: the width of a form sheet.
        let size = isPhone ? screen : CGSize(width: 504, height: 900)
        return [
            Variant(name: "regular", size: size),
            Variant(name: "axxl", size: size, contentSize: .accessibilityExtraExtraExtraLarge),
        ]
    }

    private static let states = [
        "bluetooth-off", "bluetooth-denied", "searching-nothing", "ready", "authenticating", "preparing", "joining-hub-unreachable",
        "enrolled-waiting", "hub-uncertain", "delivery-uncertain", "earlier-session", "success", "expired-after-delivery",
        "authentication-failed", "board-busy", "cancelled-board-not-reached", "cancelled-board-refused",
    ]

    func testRenderBLEEnrollmentTestStates() async throws {
        guard let directory = ProcessInfo.processInfo.environment["POGO_SCREEN_RENDER_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_POGO_SCREEN_RENDER_DIR to render screens")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "ko"
        let only = ProcessInfo.processInfo.environment["POGO_SCREEN_RENDER_ONLY"]

        for variant in variants {
            for state in Self.states where only == nil || only == state {
                let (controller, form) = try await makeController(for: state)
                let view = NavigationStack {
                    List {
                        PowerBaseEnrollmentBLETestContent(controller: controller, form: .constant(form))
                    }
                    .sheetListSpacing()
                    .navigationTitle(Text(verbatim: state))
                    .navigationBarTitleDisplayMode(.inline)
                }
                try await render(view, variant: variant, named: "\(platform)-\(language)-ble-\(state)-\(variant.name)", in: output)
                controller.leave()
            }
        }
    }

    /// The Power Base screen with the entry row, the DEBUG wording and a clean-up report.
    func testRenderPowerBaseScreenWithTheBLEEntry() async throws {
        guard let directory = ProcessInfo.processInfo.environment["POGO_SCREEN_RENDER_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_POGO_SCREEN_RENDER_DIR to render screens")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "ko"
        for variant in variants {
            let view = NavigationStack { PowerBaseConnectionView() }.environment(AppModel.preview)
            try await render(view, variant: variant, named: "\(platform)-\(language)-powerbase-screen-\(variant.name)", in: output)
            // The screen as it is pushed: its title, the simulated-data warning, and on the Mac
            // the 닫기 button below the list. Scripted Bluetooth, no CoreBluetooth.
            let board = FakeBoard()
            let screen = NavigationStack {
                PowerBaseEnrollmentBLETestView(onCleanupReport: { _ in }, makeController: {
                    PowerBaseEnrollmentBLEController(provider: FakeBLEBoardProvider(board: board), transport: FakeEnrollmentHub(), credentials: InMemoryHubCredentialStore([]))
                })
            }.environment(AppModel.preview)
            try await render(screen, variant: variant, named: "\(platform)-\(language)-ble-screen-\(variant.name)", in: output)
            let report = PowerBaseEnrollmentBLEController.Cleanup(hub: .unknownSession, board: .notDelivered)
            let rows = NavigationStack {
                List {
                    Section {
                        PowerBaseEnrollmentBLECleanupRows(cleanup: report)
                        PowerBaseEnrollmentBLECleanupRows(cleanup: .init(hub: .cancelled(EnrollmentFixtures.session(.cancelled)), board: .nothingToCancel))
                        PowerBaseEnrollmentBLECleanupRows(cleanup: .init(hub: .notDelivered(.unreachable("timeout")), board: .taken))
                        // A cancel the board did not take, in each wording.
                        PowerBaseEnrollmentBLECleanupRows(cleanup: .init(hub: .notNeeded, board: .refused(.busy)))
                        PowerBaseEnrollmentBLECleanupRows(cleanup: .init(hub: .notNeeded, board: .refused(.closed)))
                        PowerBaseEnrollmentBLECleanupRows(cleanup: .init(hub: .notNeeded, board: .unconfirmed))
                    }
                    .sheetRowInsets()
                }
                .sheetListSpacing()
            }
            try await render(rows, variant: variant, named: "\(platform)-\(language)-ble-cleanup-rows-\(variant.name)", in: output)
        }
    }

    /// Not a rendering: which mark a clean-up row gets. Runs always.
    func testOnlyASettledCleanUpGetsTheCheckMark() {
        typealias Rows = PowerBaseEnrollmentBLECleanupRows
        XCTAssertEqual(Rows.symbol(settled: true), "checkmark.circle")
        XCTAssertEqual(Rows.symbol(settled: false), "exclamationmark.triangle")

        for cancel in [PowerBaseEnrollmentBLEController.BoardCancel.notNeeded, .taken, .nothingToCancel] {
            XCTAssertTrue(Rows.isSettled(cancel), "\(cancel)")
        }
        // A cancel the board did not take, or whose answer is unknown, is never shown as done.
        var unsettled: [PowerBaseEnrollmentBLEController.BoardCancel] = [.unconfirmed, .notDelivered]
        unsettled += PowerBaseBLECode.allCases.filter { $0 != .ok && $0 != .noSuchAttempt }.map { .refused($0) }
        for cancel in unsettled {
            XCTAssertFalse(Rows.isSettled(cancel), "\(cancel)")
        }
        // Whatever the board answers to a cancel, only OK and NO_SUCH_ATTEMPT end up with the check mark.
        for code in PowerBaseBLECode.allCases {
            let settled = Rows.isSettled(PowerBaseEnrollmentBLEController.boardCancel(for: code))
            XCTAssertEqual(settled, code == .ok || code == .noSuchAttempt, code.name)
        }

        let session = EnrollmentFixtures.session(.cancelled)
        XCTAssertTrue(Rows.isSettled(PowerBaseEnrollmentBLEController.HubCancel.cancelled(session)))
        XCTAssertTrue(Rows.isSettled(PowerBaseEnrollmentBLEController.HubCancel.alreadyFinal(session)))
        XCTAssertTrue(Rows.isSettled(PowerBaseEnrollmentBLEController.HubCancel.notNeeded))
        XCTAssertFalse(Rows.isSettled(PowerBaseEnrollmentBLEController.HubCancel.notDelivered(.unreachable("timeout"))))
        XCTAssertFalse(Rows.isSettled(PowerBaseEnrollmentBLEController.HubCancel.unknownSession))
    }

    private func makeController(for state: String) async throws -> (PowerBaseEnrollmentBLEController, PowerBaseEnrollmentBLEForm) {
        let hub = FakeEnrollmentHub()
        let board = FakeBoard()
        let provider = FakeBLEBoardProvider(board: board)
        let credentials = InMemoryHubCredentialStore([EnrollmentFixtures.credential()])
        let controller = PowerBaseEnrollmentBLEController(
            provider: provider, transport: hub, credentials: credentials, pollInterval: .milliseconds(20), boardPollInterval: .milliseconds(20),
            quietScanPeriod: .milliseconds(20), maxReconnects: 1
        )
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        var form = PowerBaseEnrollmentBLEForm(
            selectedBoardID: FakeBLEBoardProvider.boardID, expectedEUI64: EnrollmentFixtures.eui64, confirmedEUI64: true, setupCode: EnrollmentFixtures.setupCode
        )
        func start() {
            controller.activate()
            controller.start(boardID: FakeBLEBoardProvider.boardID, expectedEUI64: EnrollmentFixtures.eui64, setupCode: EnrollmentFixtures.setupCode)
        }
        func waiting() {
            hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
            hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        }
        func joining() -> Bool { if case .joining = controller.phase { true } else { false } }

        switch state {
        case "bluetooth-off", "bluetooth-denied":
            provider.availability = state == "bluetooth-off" ? .poweredOff : .denied
            provider.boards = []
            controller.activate()
            form = PowerBaseEnrollmentBLEForm()
        case "searching-nothing":
            provider.boards = []
            controller.activate()
            controller.startScanning()
            try await eventually { controller.foundNothingSoFar }
            form = PowerBaseEnrollmentBLEForm(expectedEUI64: "00:12:4b", setupCode: "abc")
        case "ready":
            provider.boards.append(PowerBaseBLEDiscoveredBoard(id: UUID(), name: nil, advertisedEUI64: nil, rssi: -88))
            controller.activate()
        case "authenticating":
            provider.holdsOpens = true
            start()
        case "preparing":
            hub.scriptStart(.success(EnrollmentFixtures.session(.preparing)))
            hub.scriptStatus(.success(EnrollmentFixtures.session(.preparing)))
            start()
            try await eventually { if case .preparingHub = controller.phase { true } else { false } }
        case "joining-hub-unreachable":
            waiting()
            start()
            try await eventually { joining() }
            board.advance(to: .running, state: .joining)
            hub.scriptStatus(.failure(.unreachable("timeout")))
            try await eventually { controller.boardProgress == .joining && controller.pollProblem != nil }
        case "enrolled-waiting":
            waiting()
            start()
            try await eventually { joining() }
            board.advance(to: .enrolled, state: .enrolled, result: 17)
            try await eventually { controller.boardProgress == .enrolled }
        case "hub-uncertain":
            hub.scriptStart(.failure(.unreachable("timeout")))
            start()
            try await eventually { controller.phase == .hubUncertain }
        case "delivery-uncertain":
            waiting()
            board.holdStart()
            board.loseNextStartAnswer(reachesBoard: true)
            start()
            try await eventually { board.heldStarts == 1 }
            provider.alwaysFailOpens = .connectionFailed("timeout")
            board.releaseStart()
            try await eventually { if case .deliveryUncertain = controller.phase { true } else { false } }
        case "earlier-session":
            let earlier = EnrollmentFixtures.session(.waitingForHeartbeat, id: EnrollmentFixtures.otherSessionID)
            hub.scriptStart(.failure(.enrollmentInProgress(ownSession: earlier)))
            hub.scriptStatus(.success(earlier))
            start()
            try await eventually { if case .earlierHubSession = controller.phase { true } else { false } }
        case "success":
            waiting()
            start()
            try await eventually { joining() }
            board.advance(to: .enrolled, state: .enrolled, result: 17)
            try await eventually { controller.boardProgress == .enrolled }
            hub.scriptStatus(.success(EnrollmentFixtures.session(.heartbeatReceived, joinerEntry: "removed")))
            try await eventually { !controller.isBusy }
        case "expired-after-delivery":
            waiting()
            start()
            try await eventually { joining() }
            board.advance(to: .running, state: .attaching)
            try await eventually { controller.boardProgress == .attaching }
            hub.scriptStatus(.success(EnrollmentFixtures.session(.expired, joinerEntry: "removed")))
            try await eventually { !controller.isBusy }
        case "authentication-failed":
            provider.openErrors = [.client(.authenticationFailed)]
            start()
            try await eventually { !controller.isBusy }
        case "board-busy":
            waiting()
            hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
            board.scriptStart(.busy)
            start()
            try await eventually { !controller.isBusy }
        case "cancelled-board-refused":
            waiting()
            hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled, joinerEntry: "removing")))
            start()
            try await eventually { joining() }
            board.scriptCancel(.busy)
            controller.cancel()
            try await eventually { !controller.isBusy }
        default:
            waiting()
            hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled, joinerEntry: "removing")))
            start()
            try await eventually { joining() }
            board.disconnect()
            provider.alwaysFailOpens = .connectionFailed("timeout")
            controller.cancel()
            try await eventually { !controller.isBusy }
        }
        return (controller, form)
    }

    /// One PNG per screenful, scrolling the list until its end, so that the last row and every
    /// button are seen to be reachable in a small window.
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
