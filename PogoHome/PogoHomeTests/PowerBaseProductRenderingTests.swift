#if DEBUG
import PowerBaseBLEKit
import SwiftUI
import UIKit
import XCTest
@testable import PogoHome

/// Renders the product "Power Base 추가" screen and the "Power Base 관리" sheet in each state to
/// PNG, for checking that buttons and messages are never cut off and that every state scrolls --
/// only when `POGO_SCREEN_RENDER_DIR` is set (pass `TEST_RUNNER_POGO_SCREEN_RENDER_DIR=…` to
/// `xcodebuild test`; add `-testLanguage ko|en|es`). Run it on a small iPhone, an iPad and "My Mac
/// (Mac Catalyst)". Nothing is sent anywhere and no Bluetooth is used: the hub and the board are
/// scripted, and every identifier and code in the pictures is made up.
@MainActor
final class PowerBaseProductRenderingTests: XCTestCase {
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
            Variant(name: "dark", size: size, style: .dark),
            Variant(name: "axxl", size: size, contentSize: .accessibilityExtraExtraExtraLarge),
        ]
    }

    private static let setupStates = [
        "hub-not-paired", "start", "bluetooth-off", "bluetooth-denied", "finding", "finding-nothing", "finding-paused", "found", "code-entry", "ready", "verifying",
        "connecting",
        "confirming-hub-unreachable", "hub-uncertain", "success", "partly-done", "wrong-code", "different-board", "board-needs-update", "hub-needs-update",
        "cancelled",
    ]

    private static let managementStates = [
        "available-online", "available-offline", "pending", "in-progress", "result-unknown", "released", "released-automatic", "released-cleanup-pending", "completed",
        "cancelled", "hub-unsupported", "base-unsupported", "not-paired", "requesting", "failed-no-answer", "failed-capacity-full",
        // "허브 목록에서 제거": offered (also next to a removal that waits, and for a Base registered
        // the earlier way), under way, without an answer, refused.
        "forget-offered", "forget-offered-pending", "forget-offered-earlier-registration", "forget-requesting", "forget-result-unknown",
        "forget-failed-online",
        // A removal whose Base was taken out of the hub's list while its command may be with the
        // board: out of the list, the erase not confirmed -- just after, and after a long silence
        // (with the way to "삭제 확인").
        "list-removed", "list-removed-result-unknown",
        // A removal request (1.3.3): without an answer -- kept, with the button that sends the
        // same request again; refused because what is listed is not what was confirmed any more;
        // and a hub that can remove the Base but takes no request that names a registration.
        "request-result-unknown", "failed-stale-registration", "hub-outdated-for-removal",
    ]

    private static let confirmationStates = [
        "hub-not-paired", "start", "start-result-unknown", "finding-nothing", "found-code", "reading", "reading-paused", "confirmed", "no-receipt",
        "wrong-code", "hub-unreachable",
    ]

    private func outputDirectory() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["POGO_SCREEN_RENDER_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_POGO_SCREEN_RENDER_DIR to render screens")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return output
    }

    private var language: String { Bundle.main.preferredLocalizations.first ?? "ko" }
    private var only: String? { ProcessInfo.processInfo.environment["POGO_SCREEN_RENDER_ONLY"] }

    /// `POGO_SCREEN_RENDER_ONLY` limits what is rendered: a comma-separated list of state names
    /// ("result-unknown"), whole screens ("setup", "manage", "confirm", "list") or both together
    /// ("confirm-start"). Without it everything is rendered.
    private func renders(_ screen: String, _ state: String) -> Bool {
        guard let only else { return true }
        let names = only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return names.contains(state) || names.contains(screen) || names.contains("\(screen)-\(state)")
    }

    func testRenderSetupStates() async throws {
        let output = try outputDirectory()
        for variant in variants {
            for state in Self.setupStates where renders("setup", state) {
                let (controller, form) = try await makeSetup(for: state)
                let view = NavigationStack {
                    List {
                        PowerBaseSetupContent(controller: controller, form: .constant(form), hubName: "Jogakbo Hub (living-room)", qr: PowerBaseSetupQRIntake(camera: nil))
                    }
                    .sheetListSpacing()
                    .navigationTitle(Text(verbatim: PowerBaseSetupText.screenTitle))
                    .navigationBarTitleDisplayMode(.inline)
                }
                try await render(view, variant: variant, named: "\(platform)-\(language)-setup-\(state)-\(variant.name)", in: output)
                controller.leave()
            }
        }
    }

    func testRenderManagementStates() async throws {
        let output = try outputDirectory()
        for variant in variants {
            for state in Self.managementStates where renders("manage", state) {
                let view = NavigationStack {
                    List {
                        PowerBaseManagementContent(state: managementState(for: state), hasRefreshProblem: state == "result-unknown")
                    }
                    .sheetListSpacing()
                    .navigationTitle(Text(verbatim: PowerBaseManagementText.sheetTitle))
                    .navigationBarTitleDisplayMode(.inline)
                }
                try await render(view, variant: variant, named: "\(platform)-\(language)-manage-\(state)-\(variant.name)", in: output)
            }
        }
    }

    /// The delete confirmation itself, as the system presents it over the sheet: the narrow dialog
    /// the field feedback of `1.2.0 (8)` was about. The shortest and the longest branch.
    func testRenderDeleteConfirmationDialog() async throws {
        let output = try outputDirectory()
        let identifier = "00124b0001a2b3c4"
        let cases: [(String, PowerBase)] = [
            ("online-automatic", PowerBase(hardwareIdentifier: identifier, isOnline: true, moduleCount: 2, onlineModuleCount: 2, management: .supported, eraseConfirmation: .automatic, record: RemovalFixtures.record, removalSerial: 0)),
            ("offline-automatic", PowerBase(hardwareIdentifier: identifier, isOnline: false, moduleCount: 2, onlineModuleCount: 0, management: .supported, eraseConfirmation: .automatic, record: RemovalFixtures.record, removalSerial: 0)),
            ("offline-manual", PowerBase(hardwareIdentifier: identifier, isOnline: false, moduleCount: 2, onlineModuleCount: 0, management: .supported, eraseConfirmation: .manual, record: RemovalFixtures.record, removalSerial: 0)),
        ]
        for variant in variants {
            for (name, base) in cases where renders("dialog", name) {
                let state = PowerBaseManagementPresentation.State(
                    identifier: identifier, base: base, sensorCount: 2, removal: nil, action: nil, availability: .available, isCurrentStateVerified: true
                )
                let view = NavigationStack {
                    List {
                        PowerBaseManagementContent(state: state, startsConfirming: true)
                    }
                    .sheetListSpacing()
                    .navigationTitle(Text(verbatim: PowerBaseManagementText.sheetTitle))
                    .navigationBarTitleDisplayMode(.inline)
                }
                try await render(view, variant: variant, named: "\(platform)-\(language)-dialog-\(name)-\(variant.name)", in: output, presents: true)
            }
        }
    }

    /// The "허브 목록에서 제거" confirmation, as the system presents it over the sheet: the plain one
    /// and the longest (a removal that is still waiting is cancelled with it).
    func testRenderForgetConfirmationDialog() async throws {
        let output = try outputDirectory()
        for variant in variants {
            for name in ["forget-offered", "forget-offered-pending"] where renders("dialog", "dialog-" + name) {
                let view = NavigationStack {
                    List {
                        PowerBaseManagementContent(state: managementState(for: name), startsConfirmingForget: true)
                    }
                    .sheetListSpacing()
                    .navigationTitle(Text(verbatim: PowerBaseManagementText.sheetTitle))
                    .navigationBarTitleDisplayMode(.inline)
                }
                try await render(view, variant: variant, named: "\(platform)-\(language)-dialog-\(name)-\(variant.name)", in: output, presents: true)
            }
        }
    }

    /// The "삭제 완료" notice at the bottom of the Devices tab: for one removal, and for two that
    /// ended together.
    func testRenderCompletionNotice() async throws {
        let output = try outputDirectory()
        let completions = ["00124b0001a2b3c4", "00124b0001a2b3c6"].map { PowerBaseRemovalCompletions.Completion(id: "9f0c1d2e3f405162" + $0, powerBaseIdentifier: $0) }
        let other = PowerBase(hardwareIdentifier: "00124b0001a2b3c5", isOnline: true, moduleCount: 1, onlineModuleCount: 1, management: .supported, record: RemovalFixtures.record, removalSerial: 0)
        for variant in variants {
          // And the notice of a list removal ("허브 목록에서 제거됨"), alone and next to a completed removal.
          let listRemoval = PowerBaseRemovalCompletions.Completion(id: "5a0c1d2e3f405162738495a6b7c8d9e5", powerBaseIdentifier: "00124b0001a2b3c7", kind: .removedFromHubList)
          for (name, shown) in [
              ("notice", Array(completions.prefix(1))), ("notice-two", completions), ("notice-forget", [listRemoval]),
              ("notice-forget-and-removal", [completions[0], listRemoval]),
          ] where renders("notice", name) {
            let view = NavigationStack {
                ScrollView {
                    HStack(alignment: .center, spacing: 8) {
                        PowerBaseHeader(base: other, isCurrentStateVerified: true)
                        PowerBaseManageButton(identifier: other.hardwareIdentifier)
                    }
                    .padding()
                }
                .screenBackground()
                .navigationTitle(Text("기기"))
            }
            .overlay(alignment: .bottom) { PowerBaseRemovalCompletionNotice(completions: shown, duration: .seconds(600)) }
            try await render(view, variant: variant, named: "\(platform)-\(language)-\(name)-\(variant.name)", in: output)
          }
        }
    }

    func testRenderConfirmationStates() async throws {
        let output = try outputDirectory()
        for variant in variants {
            for state in Self.confirmationStates where renders("confirm", state) {
                let (controller, form) = try await makeConfirmation(for: state)
                let view = NavigationStack {
                    List {
                        PowerBaseReleaseConfirmationContent(
                            controller: controller, form: .constant(form), qr: PowerBaseSetupQRIntake(camera: nil),
                            origin: state == "start-result-unknown" ? .resultUnknown : .released
                        )
                    }
                    .sheetListSpacing()
                    .navigationTitle(Text(verbatim: PowerBaseManagementText.confirmErase))
                    .navigationBarTitleDisplayMode(.inline)
                }
                try await render(view, variant: variant, named: "\(platform)-\(language)-confirm-\(state)-\(variant.name)", in: output)
                controller.leave()
            }
        }
    }

    private func makeConfirmation(for state: String) async throws -> (PowerBaseReleaseConfirmationController, PowerBaseReleaseConfirmationForm) {
        let hub = FakeRemovalHub()
        let board = FakeBoard()
        board.set(capabilities: [.bridgeEndpointV1, .managementV1, .releaseReceiptV1])
        board.set(receipt: EnrollmentFixtures.releaseReceipt())
        let provider = FakeBLEBoardProvider(board: board)
        let controller = PowerBaseReleaseConfirmationController(
            powerBaseIdentifier: EnrollmentFixtures.eui64, provider: provider, transport: hub,
            credentials: InMemoryHubCredentialStore([EnrollmentFixtures.credential()]), quietScanPeriod: .milliseconds(20)
        )
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        var form = PowerBaseReleaseConfirmationForm(didStartFinding: true, selectedBoardID: FakeBLEBoardProvider.boardID, setupCode: EnrollmentFixtures.setupCode)
        func confirm() {
            controller.activate()
            controller.startScanning()
            controller.confirm(boardID: FakeBLEBoardProvider.boardID, setupCode: EnrollmentFixtures.setupCode)
        }
        switch state {
        case "hub-not-paired":
            controller.targetDidChange(.init(hubID: EnrollmentFixtures.hubA, baseURL: EnrollmentFixtures.urlA, isSimulated: false, isPaired: false))
            form = PowerBaseReleaseConfirmationForm()
        case "start", "start-result-unknown":
            form = PowerBaseReleaseConfirmationForm()
        case "finding-nothing":
            provider.boards = []
            controller.activate()
            controller.startScanning()
            try await eventually { controller.foundNothingSoFar }
            form = PowerBaseReleaseConfirmationForm(didStartFinding: true)
        case "reading-paused":
            // The board's status arrived while the app was away: the receipt request waits.
            board.holdPlainStatus()
            confirm()
            try await eventually { board.heldPlainStatusRequests == 1 }
            controller.sceneDidEnterBackground()
            board.releasePlainStatus()
            try await eventually { controller.foregroundWaiters == 1 }
        case "found-code":
            controller.activate()
            controller.startScanning()
        case "reading":
            board.holdPlainStatus()
            confirm()
            try await eventually { controller.phase == .reading }
        case "confirmed":
            hub.scriptReceipt(.success(removal(.completed, base: EnrollmentFixtures.eui64)))
            confirm()
            try await eventually { !controller.isBusy }
            form.setupCode = ""
        case "no-receipt":
            board.set(receipt: nil)
            confirm()
            try await eventually { !controller.isBusy }
        case "wrong-code":
            provider.openErrors = [.client(.authenticationFailed)]
            confirm()
            try await eventually { !controller.isBusy }
        default:
            hub.scriptReceipt(.failure(.unreachable("timeout")))
            confirm()
            try await eventually { !controller.isBusy }
        }
        return (controller, form)
    }

    /// Not a rendering: the confirmation states above are what their names say.
    func testTheRenderedConfirmationStatesAreWhatTheyAreCalled() async throws {
        typealias C = PowerBaseReleaseConfirmationController
        let (confirmed, _) = try await makeConfirmation(for: "confirmed")
        guard case let .confirmed(removal) = confirmed.phase else { return XCTFail("\(confirmed.phase)") }
        XCTAssertEqual(removal.state, .completed)
        let expected: [String: C.Failure] = ["no-receipt": .noReceipt, "wrong-code": .wrongSetupCode, "hub-unreachable": .hub(.unreachable("timeout"))]
        for (state, failure) in expected {
            let (controller, _) = try await makeConfirmation(for: state)
            XCTAssertEqual(controller.phase, .failed(failure), state)
            XCTAssertEqual(controller.canSendAgain, state == "hub-unreachable", state)
        }
        let (idle, form) = try await makeConfirmation(for: "start")
        XCTAssertFalse(form.didStartFinding)
        XCTAssertEqual(idle.availability, .unknown, "before the user asks to look for the board, Bluetooth is not touched")
        let (reading, _) = try await makeConfirmation(for: "reading")
        XCTAssertEqual(reading.phase, .reading)
        XCTAssertFalse(reading.isSuspended)
        reading.leave()
        let (paused, _) = try await makeConfirmation(for: "reading-paused")
        XCTAssertEqual(paused.phase, .reading)
        XCTAssertTrue(paused.isSuspended, "the hint about the background is shown for a run that waits for the foreground")
        paused.leave()
        XCTAssertEqual(paused.foregroundWaiters, 0)

        // The management sheet's "결과 확인 불가" is the job without a result, shown as that, with
        // the way to "삭제 확인" under it.
        let unknown = try XCTUnwrap(managementState(for: "result-unknown").removal)
        XCTAssertEqual(unknown.presentation, .resultUnknown)
        XCTAssertEqual(PowerBaseManagementPresentation.removalActions(for: unknown, isActing: false), [.confirmErase])
        let pending = try XCTUnwrap(managementState(for: "pending").removal)
        XCTAssertEqual(PowerBaseManagementPresentation.removalActions(for: pending, isActing: false), [.cancel])
        // A removal whose Base was taken out of the list is rendered as that, never as "결과 확인 불가".
        let listRemoved = try XCTUnwrap(managementState(for: "list-removed-result-unknown").removal)
        XCTAssertEqual(listRemoved.presentation, .removedFromListUnconfirmed)
        XCTAssertEqual(PowerBaseManagementPresentation.removalActions(for: listRemoved, isActing: false), [.confirmErase])
        XCTAssertEqual(PowerBaseManagementPresentation.removalActions(for: try XCTUnwrap(managementState(for: "list-removed").removal), isActing: false), [])
    }

    /// The device list's Power Base title with its management button and removal state, the rows
    /// of jobs whose Base is gone, and the Add Device sheet with its two Power Base rows.
    func testRenderListEntriesAndTheAddDeviceSheet() async throws {
        let output = try outputDirectory()
        let online = PowerBase(hardwareIdentifier: "00124b0001a2b3c4", isOnline: true, moduleCount: 2, onlineModuleCount: 2, management: .supported, record: RemovalFixtures.record, removalSerial: 0)
        let offline = PowerBase(hardwareIdentifier: "00124b0001a2b3c5", isOnline: false, moduleCount: 1, onlineModuleCount: 0, management: .supported, record: RemovalFixtures.record, removalSerial: 0)
        for variant in variants where renders("list", "list") {
            let list = NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: PogoTheme.sectionSpacing) {
                        HStack(alignment: .center, spacing: 8) {
                            PowerBaseHeader(base: online, isCurrentStateVerified: true)
                            PowerBaseManageButton(identifier: online.hardwareIdentifier)
                        }
                        HStack(alignment: .center, spacing: 8) {
                            PowerBaseHeader(base: offline, isCurrentStateVerified: true, removal: removal(.pending, base: offline.hardwareIdentifier))
                            PowerBaseManageButton(identifier: offline.hardwareIdentifier)
                        }
                        // The requests that are under way. A finished removal has no row.
                        PowerBaseRemovalCards(removals: [
                            removal(.accepted, base: "00124b0001a2b3c6", resultUnknown: true),
                            removal(.released, base: "00124b0001a2b3c8"),
                            automaticRemoval(.released, base: "00124b0001a2b3c9"),
                            listRemoved(.sent, base: "00124b0001a2b3c7", resultUnknown: true),
                        ])
                    }
                    .padding()
                }
                .screenBackground()
                .navigationTitle(Text("기기"))
            }
            try await render(list, variant: variant, named: "\(platform)-\(language)-devices-powerbase-entries-\(variant.name)", in: output)
            let sheet = AddDeviceSheet().environment(AppModel.preview).environment(AppleHomeModel.preview)
            try await render(sheet, variant: variant, named: "\(platform)-\(language)-add-device-\(variant.name)", in: output)
        }
    }

    // MARK: - States

    private func removal(_ state: PowerBaseRemoval.State, base: String = "00124b0001a2b3c4", resultUnknown: Bool = false) -> PowerBaseRemoval {
        // One job per Base, as the hub issues them: the id differs with the Base.
        PowerBaseRemoval(
            id: "9f0c1d2e3f405162" + base, powerBaseIdentifier: base, state: state, resultUnknown: resultUnknown, cancellable: state == .pending,
            affectedModuleCount: 2, createdAt: Date(timeIntervalSince1970: 1_790_000_000), updatedAt: Date(timeIntervalSince1970: 1_790_000_100)
        )
    }

    /// A removal whose Base the hub took out of its list while its command may be with the board.
    private func listRemoved(_ state: PowerBaseRemoval.State, base: String = "00124b0001a2b3c4", resultUnknown: Bool = false) -> PowerBaseRemoval {
        var removal = removal(state, base: base, resultUnknown: resultUnknown)
        removal.powerBaseListRemoved = true
        return removal
    }

    private func automaticRemoval(_ state: PowerBaseRemoval.State, base: String) -> PowerBaseRemoval {
        var removal = removal(state, base: base)
        removal.eraseConfirmation = .automatic
        return removal
    }

    private func managementState(for state: String) -> PowerBaseManagementPresentation.State {
        typealias State = PowerBaseManagementPresentation.State
        let identifier = "00124b0001a2b3c4"
        func base(online: Bool = true, management: PowerBaseManagementSupport = .supported) -> PowerBase {
            PowerBase(hardwareIdentifier: identifier, isOnline: online, moduleCount: 2, onlineModuleCount: online ? 2 : 0, management: management)
        }
        func make(_ base: PowerBase?, removal: PowerBaseRemoval? = nil, action: PowerBaseRemovalController.Action? = nil, _ availability: PowerBaseManagementPresentation.Availability) -> State {
            State(identifier: identifier, base: base, sensorCount: base == nil ? 0 : 2, removal: removal, action: action, availability: availability, isCurrentStateVerified: true)
        }
        switch state {
        case "available-online": return make(base(), .available)
        case "available-offline": return make(base(online: false), .available)
        case "pending": return make(base(online: false), removal: removal(.pending), .removalExists)
        case "in-progress": return make(base(), removal: removal(.accepted), .removalExists)
        case "result-unknown": return make(base(online: false), removal: removal(.sent, resultUnknown: true), .removalExists)
        case "released": return make(nil, removal: removal(.released), .removalExists)
        case "released-automatic":
            // The board confirms its erase to the hub by itself: "삭제 중", nothing to do.
            var finishing = removal(.released)
            finishing.eraseConfirmation = .automatic
            return make(nil, removal: finishing, .removalExists)
        case "released-cleanup-pending":
            var released = removal(.released)
            released.settingsCleanupPending = true
            return make(nil, removal: released, .removalExists)
        case "failed-capacity-full": return make(base(), action: .failed(.request(.capacityFull)), .available)
        case "completed": return make(nil, removal: removal(.completed), .removalExists)
        case "cancelled": return make(base(), removal: removal(.cancelled), .available)
        case "hub-unsupported": return make(base(management: .unknown), .hubUnsupported)
        case "base-unsupported": return make(base(management: .unsupported), .powerBaseUnsupported)
        case "not-paired": return make(base(), .hubNotEligible(.notPaired))
        case "requesting": return make(base(), action: .requesting, .available)
        case "request-result-unknown": return make(base(), action: .resultUnknown, .available)
        case "failed-stale-registration": return make(base(), action: .failed(.request(.staleRecord)), .available)
        case "hub-outdated-for-removal":
            // Linux bridge 0.4.2 and earlier: the registration, but no removal serial.
            return make(PowerBase(hardwareIdentifier: identifier, isOnline: true, moduleCount: 2, onlineModuleCount: 2, management: .supported, record: RemovalFixtures.record), .hubUnsupported)
        case "forget-offered":
            var offered = make(base(online: false), .available)
            offered.forgetOffer = .init(record: String(repeating: "7e", count: 16), removalEffect: .none)
            return offered
        case "forget-offered-pending":
            var offered = make(base(online: false), removal: removal(.pending), .removalExists)
            offered.forgetOffer = .init(record: String(repeating: "7e", count: 16), removalEffect: .cancelsPendingRemoval)
            return offered
        case "forget-offered-earlier-registration":
            var offered = make(base(online: false, management: .unsupported), .powerBaseUnsupported)
            offered.forgetOffer = .init(record: String(repeating: "7e", count: 16), removalEffect: .none)
            return offered
        case "forget-requesting":
            var requesting = make(base(online: false), .available)
            requesting.forgetAction = .requesting
            return requesting
        case "forget-result-unknown":
            var unknown = make(base(online: false), .available)
            unknown.forgetAction = .resultUnknown
            return unknown
        case "forget-failed-online":
            var failed = make(base(), .available)
            failed.forgetAction = .failed(.request(.online))
            return failed
        case "list-removed": return make(nil, removal: listRemoved(.sent), .removalExists)
        case "list-removed-result-unknown": return make(nil, removal: listRemoved(.accepted, resultUnknown: true), .removalExists)
        default: return make(base(), action: .failed(.request(.unreachable("timeout"))), .available)
        }
    }

    private func makeSetup(for state: String) async throws -> (PowerBaseEnrollmentBLEController, PowerBaseSetupForm) {
        let hub = FakeEnrollmentHub()
        hub.issuedManagement = EnrollmentFixtures.managementCredential()
        let board = FakeBoard()
        board.set(capabilities: [.bridgeEndpointV1, .managementV1])
        let provider = FakeBLEBoardProvider(board: board)
        let credentials = InMemoryHubCredentialStore([EnrollmentFixtures.credential()])
        let controller = PowerBaseEnrollmentBLEController(
            provider: provider, transport: hub, credentials: credentials, pollInterval: .milliseconds(20), boardPollInterval: .milliseconds(20),
            quietScanPeriod: state == "finding" ? .seconds(600) : .milliseconds(20), maxReconnects: 1, requireManagement: true
        )
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        let generation = EnrollmentFixtures.managementGeneration
        func session(_ state: PowerBaseEnrollmentSession.State) -> PowerBaseEnrollmentSession { EnrollmentFixtures.session(state, managementGeneration: generation) }
        var form = PowerBaseSetupForm(didStartFinding: true, selectedBoardID: FakeBLEBoardProvider.boardID, setupCode: EnrollmentFixtures.setupCode)
        func start() {
            controller.activate()
            controller.start(boardID: FakeBLEBoardProvider.boardID, expectedEUI64: EnrollmentFixtures.eui64, setupCode: EnrollmentFixtures.setupCode)
        }
        func waiting() {
            hub.scriptStart(.success(session(.waitingForHeartbeat)))
            hub.scriptStatus(.success(session(.waitingForHeartbeat)))
        }
        func joining() -> Bool { if case .joining = controller.phase { true } else { false } }

        switch state {
        case "hub-not-paired":
            controller.targetDidChange(.init(hubID: EnrollmentFixtures.hubA, baseURL: EnrollmentFixtures.urlA, isSimulated: false, isPaired: false))
            form = PowerBaseSetupForm()
        case "start":
            form = PowerBaseSetupForm()
        case "bluetooth-off", "bluetooth-denied":
            provider.availability = state == "bluetooth-off" ? .poweredOff : .denied
            provider.boards = []
            controller.activate()
            form = PowerBaseSetupForm(didStartFinding: true)
        case "finding":
            // Entered a moment ago: looking, nothing yet.
            provider.boards = []
            controller.activate()
            controller.startScanning()
            form = PowerBaseSetupForm(didStartFinding: true)
        case "finding-paused":
            // The list is empty and nothing is looking (the app was away, or a run ended).
            provider.boards = []
            controller.activate()
            form = PowerBaseSetupForm(didStartFinding: true)
        case "finding-nothing":
            provider.boards = []
            controller.activate()
            controller.startScanning()
            try await eventually { controller.foundNothingSoFar }
            form = PowerBaseSetupForm(didStartFinding: true)
        case "found":
            // The same board seen twice, another board, and something that is not a Power Base.
            provider.boards.append(PowerBaseBLEDiscoveredBoard(id: UUID(), name: "POGO-PB-00124B0001A2B3C4", advertisedEUI64: EnrollmentFixtures.eui64, rssi: -90))
            provider.boards.append(PowerBaseBLEDiscoveredBoard(id: UUID(), name: "POGO-PB-00124B0001A2B3D9", advertisedEUI64: "00124b0001a2b3d9", rssi: -74))
            provider.boards.append(PowerBaseBLEDiscoveredBoard(id: UUID(), name: nil, advertisedEUI64: nil, rssi: -40))
            controller.activate()
            controller.startScanning()
            form = PowerBaseSetupForm(didStartFinding: true)
        case "code-entry":
            controller.activate()
            controller.startScanning()
            form = PowerBaseSetupForm(didStartFinding: true, selectedBoardID: FakeBLEBoardProvider.boardID, setupCode: "MFRGGZDF")
        case "ready":
            controller.activate()
            controller.startScanning()
        case "verifying":
            provider.holdsOpens = true
            start()
        case "connecting":
            hub.scriptStart(.success(session(.preparing)))
            hub.scriptStatus(.success(session(.preparing)))
            start()
            try await eventually { if case .preparingHub = controller.phase { true } else { false } }
        case "confirming-hub-unreachable":
            waiting()
            start()
            try await eventually { joining() }
            board.advance(to: .enrolled, state: .enrolled, result: 17)
            hub.scriptStatus(.failure(.unreachable("timeout")))
            try await eventually { controller.boardProgress == .enrolled && controller.pollProblem != nil }
        case "hub-uncertain":
            hub.scriptStart(.failure(.unreachable("timeout")))
            start()
            try await eventually { controller.phase == .hubUncertain }
        case "success":
            waiting()
            // The board's last word stays "attaching": a finished screen must not show it.
            hub.scriptStatus(.success(session(.heartbeatReceived)))
            start()
            try await eventually { !controller.isBusy }
            form.setupCode = ""
        case "partly-done":
            waiting()
            start()
            try await eventually { joining() }
            board.advance(to: .enrolled, state: .enrolled, result: 17)
            try await eventually { controller.boardProgress == .enrolled }
            hub.replaceStatus(.success(session(.expired)))
            try await eventually { !controller.isBusy }
        case "wrong-code":
            provider.openErrors = [.client(.authenticationFailed)]
            start()
            try await eventually { !controller.isBusy }
        case "different-board":
            board.report(eui64: "00124b0001a2ffff")
            start()
            try await eventually { !controller.isBusy }
        case "board-needs-update":
            board.set(capabilities: [.bridgeEndpointV1])
            start()
            try await eventually { !controller.isBusy }
        case "hub-needs-update":
            hub.scriptStart(.failure(.managementNotSupported))
            start()
            try await eventually { !controller.isBusy }
        default:
            waiting()
            hub.scriptCancel(.success(session(.cancelled)))
            start()
            try await eventually { joining() }
            controller.cancel()
            try await eventually { !controller.isBusy }
        }
        return (controller, form)
    }

    // MARK: - What a state shows (runs always)

    /// Not a rendering: the states above really are the ones their names say.
    func testTheRenderedStatesAreWhatTheyAreCalled() async throws {
        typealias P = PowerBaseSetupPresentation
        let expected: [String: P.Result] = [
            "success": .registered, "partly-done": .partlyDone, "wrong-code": .notRegistered(.wrongSetupCode), "different-board": .notRegistered(.differentBoard),
            "board-needs-update": .notRegistered(.boardNeedsUpdate), "hub-needs-update": .notRegistered(.hubNeedsUpdate),
            "cancelled": .cancelled(boardMayHaveJoined: false),
        ]
        for (state, result) in expected {
            let (controller, _) = try await makeSetup(for: state)
            XCTAssertEqual(P.result(of: controller.phase), result, state)
            controller.leave()
        }
        let stages: [String: PowerBaseSetupStage] = ["verifying": .verifyingBoard, "connecting": .connecting, "confirming-hub-unreachable": .confirmingWithHub, "hub-uncertain": .connecting]
        for (state, stage) in stages {
            let (controller, _) = try await makeSetup(for: state)
            XCTAssertEqual(P.stage(phase: controller.phase, boardProgress: controller.boardProgress), stage, state)
            XCTAssertNil(P.result(of: controller.phase), state)
            controller.leave()
        }
        // Before the user asks to look for boards, nothing has touched Bluetooth.
        let (idle, form) = try await makeSetup(for: "start")
        XCTAssertFalse(form.didStartFinding)
        XCTAssertEqual(idle.availability, .unknown)
        XCTAssertFalse(idle.isScanning)
        // The list offers each board once, and nothing without an identity.
        let (found, _) = try await makeSetup(for: "found")
        XCTAssertEqual(found.boards.count, 4)
        XCTAssertEqual(P.selectableBoards(found.boards).count, 2)
        found.leave()
    }

    // MARK: - Rendering

    /// One PNG per screenful, scrolling the list until its end, so that the last row and every
    /// button are seen to be reachable in a small window.
    /// `presents`: the view puts a system dialog over itself; it is drawn with the window and
    /// taken away afterwards.
    private func render(_ view: some View, variant: Variant, named name: String, in directory: URL, presents: Bool = false) async throws {
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
        if presents {
            // The dialog hangs on the delete button, and a list only builds the rows on screen: at
            // the largest text size the button is further down, as it is for a user who scrolls to it.
            // A list builds its rows as they come on screen and only then knows how long it is:
            // the last section is reached by going to the end until the end stops moving.
            if let list = Self.firstScrollView(in: window) {
                for _ in 0..<8 {
                    let bottom = list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.height
                    guard bottom > list.contentOffset.y + 1 else { break }
                    list.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
                    window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(150))
                }
            }
            try await waitUntil(timeout: 5) { host.presentedViewController != nil }
            host.presentedViewController?.overrideUserInterfaceStyle = variant.style
            host.presentedViewController?.traitOverrides.preferredContentSizeCategory = variant.contentSize
            try await Task.sleep(for: .milliseconds(900))
        }
        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        format.scale = 1
        // A dialog whose text does not fit scrolls inside itself: its pages are drawn too, so the
        // pictures show that every line can be reached.
        let scrollView = presents
            ? host.presentedViewController.flatMap { Self.firstScrollView(in: $0.view, overflowingOnly: true) }
            : Self.firstScrollView(in: window)
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
        if presents {
            host.dismiss(animated: false)
            try await Task.sleep(for: .milliseconds(300))
        }
        window.isHidden = true
        window.rootViewController = nil
    }

    private static func firstScrollView(in view: UIView, overflowingOnly: Bool = false) -> UIScrollView? {
        if let scrollView = view as? UIScrollView, scrollView.contentSize.height > (overflowingOnly ? scrollView.bounds.height + 1 : 0) { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview, overflowingOnly: overflowingOnly) { return found }
        }
        return nil
    }
}
#endif
