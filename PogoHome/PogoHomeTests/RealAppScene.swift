import SwiftUI
import UIKit
import XCTest
@testable import PogoHome

/// Sends the test host -- the real PogoHome app in the simulator -- to the background and brings it
/// back, so a test can see what a screen does across a **real** scene transition: UIKit's own
/// notifications, the application state, timers and tasks as they run in a backgrounded app.
///
/// The simulator only. Leaving goes through the same call the Home button ends in
/// (`-[UIApplication suspend]`); coming back asks the system to open this app again
/// (`LSApplicationWorkspace`, as a tap on its icon does). Both are private and used here, in test
/// code, only. Where either does nothing the test is skipped, not passed.
///
/// What this is not: a real iPhone. The simulator does not freeze a backgrounded app the way a
/// device eventually does, and nobody listens to what VoiceOver would say.
@MainActor
enum RealAppScene {
    static var isSupported: Bool {
        #if targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    static var isInForeground: Bool { UIApplication.shared.applicationState == .active }
    static var isInBackground: Bool { UIApplication.shared.applicationState == .background }

    static func enterBackground() async throws {
        try XCTSkipUnless(isSupported, "a real background transition is only driven in the iOS simulator")
        try XCTSkipUnless(isInForeground, "the test host is not in the foreground (state \(UIApplication.shared.applicationState.rawValue))")
        let suspend = NSSelectorFromString("suspend")
        try XCTSkipUnless(UIApplication.shared.responds(to: suspend), "this system cannot send the app to the background from a test")
        UIApplication.shared.perform(suspend)
        let deadline = Date().addingTimeInterval(10)
        while !isInBackground, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try XCTSkipUnless(isInBackground, "the app did not reach the background")
    }

    static func returnToForeground() async throws {
        guard !isInForeground else { return }
        if let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
           let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject,
           let bundleID = Bundle.main.bundleIdentifier {
            _ = workspace.perform(NSSelectorFromString("openApplicationWithBundleID:"), with: bundleID)
        }
        let deadline = Date().addingTimeInterval(15)
        while !isInForeground, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(isInForeground, "the app did not come back to the foreground (state \(UIApplication.shared.applicationState.rawValue))")
    }
}

/// Gives the screen under test the app's real phase, the way `PogoHomeApp` reads it: from what
/// UIKit says of the application, as it says it.
struct RealScenePhase<Content: View>: View {
    @ViewBuilder let content: () -> Content
    /// Called with every real change, after the screen got it (what `PogoHomeApp` does with it).
    var onChange: (ScenePhase) -> Void = { _ in }

    @State private var phase: ScenePhase = UIApplication.shared.applicationState == .active ? .active : .background

    var body: some View {
        content()
            .environment(\.scenePhase, phase)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in set(.background) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in set(.inactive) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in set(.active) }
    }

    private func set(_ new: ScenePhase) {
        guard new != phase else { return }
        phase = new
        onChange(new)
    }
}

/// What the removal notice and the management sheet do across a **real** trip of the app to the
/// background and back, in the iOS simulator (review of `1.2.1 (9)`, R3).
///
/// The real `DevicesView` with the real sheet, on the real `AppModel` and
/// `PowerBaseRemovalController`; the hub is scripted and its answers are held back until the app is
/// away. The model is stopped and started with the phase the way `PogoHomeApp` does it.
@MainActor
final class PowerBaseRemovalRealSceneTests: XCTestCase {
    private typealias F = ReenrollHubFixtures
    private typealias Completion = PowerBaseRemovalCompletions.Completion

    private var harness: ReenrollHarness!
    private var screen: HostedScreen?
    private var announced: [String] = []
    private var phases: [ScenePhase] = []

    override func setUp() async throws {
        harness = ReenrollHarness()
        announced = []
        phases = []
    }

    override func tearDown() async throws {
        try await RealAppScene.returnToForeground()
        screen?.close()
        screen = nil
        harness.removalHub?.release()
        harness.stop()
        harness = nil
    }

    private var completed: Completion { Completion(id: RemovalFixtures.removalID, powerBaseIdentifier: F.base) }
    private var notice: String { PowerBaseRemovalCompletionNotice.text(for: completed) }

    /// The Devices tab as the app shows it, following the app's real phase.
    private func showTheDevicesTab(actions: DeviceActions = DeviceActions(), noticeDuration: Duration) async throws -> HostedScreen {
        let harness = harness!
        let view = RealScenePhase(content: {
            DevicesView(actions: actions, removals: harness.removals, noticeDuration: noticeDuration, announce: { [weak self] in self?.announced.append($0) })
                .environment(harness.model).environment(AppleHomeModel.preview)
        }, onChange: { [weak self] phase in
            self?.phases.append(phase)
            // What `PogoHomeApp` does with the app's phase.
            switch phase {
            case .background: harness.model.stop()
            case .active: harness.model.start()
            default: break
            }
        })
        let hosted = try HostedScreen(view)
        screen = hosted
        // The tab is up and has handed the controller the jobs of the snapshot on screen.
        try await waitUntil(timeout: 5) { harness.removals.reportedSource == harness.model.sourceIdentity }
        return hosted
    }

    /// The helper itself: the app really leaves and really comes back.
    func testTheTestHostReallyGoesToTheBackgroundAndComesBack() async throws {
        let hosted = try HostedScreen(RealScenePhase(content: { Color.clear }, onChange: { [weak self] in self?.phases.append($0) }))
        screen = hosted
        try await RealAppScene.enterBackground()
        XCTAssertEqual(UIApplication.shared.applicationState, .background)
        try await waitUntil { self.phases.last == .background }
        try await RealAppScene.returnToForeground()
        XCTAssertEqual(UIApplication.shared.applicationState, .active)
        try await waitUntil { self.phases.last == .active }
        XCTAssertEqual(phases.filter { $0 != .inactive }, [.background, .active], "\(phases)")
    }

    /// A removal is requested in the foreground; the app goes to the background; the hub's answers
    /// arrive there (the request's, then the list's "completed"); the user comes back.
    func testARemovalThatCompletesWhileTheAppIsAwayIsShownAndClosesItsSheetOnTheReturn() async throws {
        try await harness.startApp(first: F.enrolled(removals: []))
        let removals = harness.removals!
        let actions = DeviceActions()
        let hosted = try await showTheDevicesTab(actions: actions, noticeDuration: .milliseconds(1200))
        actions.managingPowerBase = PowerBaseManagementTarget(identifier: F.base)
        try await waitUntil(timeout: 5) { hosted.isPresenting }

        // The request leaves in the foreground; its answer is held back.
        harness.removalHub.hold()
        var job = RemovalFixtures.removal(.pending)
        job.eraseConfirmation = .automatic
        harness.removalHub.scriptRequest(.success(job))
        removals.requestRemoval(of: F.base)
        try await waitUntil { self.harness.removalHub.heldCount == 1 }

        try await RealAppScene.enterBackground()
        try await waitUntil { self.phases.last == .background }
        try await waitUntil { self.harness.model.connectionStatus == .idle }

        // In the background: the request's answer, then the hub's list says the job is completed
        // (the list is read by the sheet on its own, whatever `AppModel` does).
        harness.removalHub.release()
        try await waitUntil { removals.action(for: F.base) == nil }
        harness.removalHub.scriptList(.success([RemovalFixtures.removal(.completed)]))
        await removals.refresh()
        try await waitUntil { removals.completionEvents.count == 1 }
        XCTAssertEqual(removals.completionEvents.map(\.completion), [completed], "the completion is taken in when the hub says so")

        // Longer than the notice's own time, with the app really away.
        try await Task.sleep(for: .milliseconds(1800))
        XCTAssertTrue(RealAppScene.isInBackground)
        XCTAssertEqual(announced, [], "nothing is announced in the background")
        XCTAssertEqual(removals.notices.shown, [], "nothing is shown there")
        XCTAssertEqual(removals.notices.waiting, [completed], "the notice waits, its time unspent")
        XCTAssertEqual(actions.managingPowerBase?.identifier, F.base, "the sheet is not closed behind the user's back")

        // The user comes back; the hub's snapshot no longer has the Base.
        let gone = F.snapshot(bases: [], modules: [], removals: [F.removal("completed")])
        await harness.transport.setSnapshotProvider { gone }
        try await RealAppScene.returnToForeground()
        try await waitUntil(timeout: 5) { actions.managingPowerBase == nil }
        try await waitUntil(timeout: 5) { self.announced == [self.notice] }
        XCTAssertEqual(removals.notices.shown, [completed], "shown now, in the foreground")
        let labels = try await hosted.labels()
        XCTAssertEqual(labels.filter { $0.contains(self.notice) }.count, 1, "on the Devices tab, once: \(labels)")
        try await waitUntil(timeout: 5) { self.harness.model.snapshot.powerBases.isEmpty }

        // It stays its time in the foreground and goes. Leaving and coming back again shows nothing.
        try await waitUntil(timeout: 5) { removals.notices == PowerBaseRemovalNotices() }
        try await RealAppScene.enterBackground()
        try await RealAppScene.returnToForeground()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(announced, [notice], "announced once in all")
        XCTAssertEqual(removals.notices, PowerBaseRemovalNotices())
        XCTAssertEqual(removals.completionEvents.count, 1)
    }

    /// The notice is on screen when the app goes to the background. Its time does not run there:
    /// back in the foreground it is shown again, for its whole time, and then never again.
    func testANoticeCutShortByTheBackgroundIsShownAgainInFullOnTheReturn() async throws {
        try await harness.startApp(first: F.enrolled(removals: [F.removal("accepted")]))
        let removals = harness.removals!
        _ = try await showTheDevicesTab(noticeDuration: .seconds(3))
        try await harness.deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        try await waitUntil(timeout: 5) { removals.notices.shown == [self.completed] }
        XCTAssertEqual(announced, [notice])

        // Away while it is shown, for longer than its time.
        try await RealAppScene.enterBackground()
        try await waitUntil { removals.notices.shown.isEmpty }
        XCTAssertEqual(removals.notices.waiting, [completed], "cut short: it waits again")
        try await Task.sleep(for: .milliseconds(3500))
        XCTAssertTrue(RealAppScene.isInBackground)
        XCTAssertEqual(removals.notices.waiting, [completed], "its time did not run out while nobody could see it")
        XCTAssertEqual(announced, [notice])

        // Back: shown again, from the start.
        let returned = Date()
        try await RealAppScene.returnToForeground()
        try await waitUntil(timeout: 5) { removals.notices.shown == [self.completed] }
        XCTAssertEqual(announced, [notice, notice], "presented again, as it was cut short the first time")
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(removals.notices.shown, [completed], "still there: it has its whole time")
        try await waitUntil(timeout: 6) { removals.notices == PowerBaseRemovalNotices() }
        XCTAssertGreaterThan(Date().timeIntervalSince(returned), 2.5, "it stayed for its time after the return")

        // Shown to its end: never again, however often the app leaves and returns or the hub repeats itself.
        try await RealAppScene.enterBackground()
        try await RealAppScene.returnToForeground()
        try await harness.deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(announced.count, 2)
        XCTAssertEqual(removals.notices, PowerBaseRemovalNotices())
    }

    /// The sheet's own "삭제 확인" answer arrives in the background (the hub's `completed` to the
    /// confirmation this device handed in): taken in there, acted on in the foreground.
    func testAConfirmationAnsweredInTheBackgroundClosesTheSheetOnTheReturn() async throws {
        try await harness.startApp(first: F.snapshot(bases: [], modules: [], removals: [F.removal("released", eraseConfirmation: "manual")]))
        let removals = harness.removals!
        let actions = DeviceActions()
        let hosted = try await showTheDevicesTab(actions: actions, noticeDuration: .milliseconds(1200))
        actions.managingPowerBase = PowerBaseManagementTarget(identifier: F.base)
        try await waitUntil(timeout: 5) { hosted.isPresenting }

        try await RealAppScene.enterBackground()
        try await waitUntil { self.phases.last == .background }
        removals.removalWasConfirmed(RemovalFixtures.removal(.completed))
        XCTAssertEqual(removals.completionEvents.map(\.completion), [completed])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(actions.managingPowerBase?.identifier, F.base, "the sheet stays while the app is away")
        XCTAssertEqual(announced, [])

        try await RealAppScene.returnToForeground()
        try await waitUntil(timeout: 5) { actions.managingPowerBase == nil }
        try await waitUntil(timeout: 5) { self.announced == [self.notice] }
    }
}
