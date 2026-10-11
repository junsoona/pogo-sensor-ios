import SwiftUI
import XCTest
@testable import PogoHome

/// The field defect of `1.2.0 (8)` (2026-10-08, reproduced repeatedly on a device): a Power Base
/// was removed -- the hub's job `completed` -- and registered again at once. The device list showed
/// the Base online with its sensors **and** a green "삭제 완료" next to it; "Power Base 관리" said
/// "삭제 완료" too and offered no delete button. Starting the app again changed nothing. About ten
/// minutes later the button was back.
///
/// The hub lists a finished job for 10 minutes (`docs/pogohome-api-v1.md`, firmware repository),
/// also after the same board has been registered again: the job is about the *earlier*
/// registration. The app took every `completed` job of a Base for the state of the Base it lists.
///
/// Every test here goes the way the app does: the hub's JSON through the real
/// `LiveSensorDataSource` and `PogoSnapshotMapper` into the real `AppModel`, the hub's removal
/// routes through the real `PowerBaseRemovalController`, and the sheet's state read as
/// `PowerBaseManagementSheet` reads it. Only what was already there before the fix is used, so
/// this file compiles against `1.2.0 (8)` and fails there.
@MainActor
final class PowerBaseReenrolledAfterRemovalTests: XCTestCase {
    private typealias P = PowerBaseManagementPresentation
    private typealias F = ReenrollHubFixtures

    private var harness: ReenrollHarness!

    override func setUp() async throws {
        harness = ReenrollHarness()
    }

    override func tearDown() async throws {
        harness.stop()
        harness = nil
    }

    private var model: AppModel { harness.model }
    private var removals: PowerBaseRemovalController { harness.removals }

    /// What the device list shows next to the Base: `PowerBaseRemovalBadge` is given exactly this.
    private func listBadge(_ identifier: String = F.base) -> PowerBaseRemoval.Presentation? {
        P.badge(for: removals.removal(for: identifier, in: model.snapshot))
    }

    /// Removed and confirmed: the hub's job goes accepted, released, completed; the Base and its
    /// sensors leave the hub's lists at `released`.
    private func removeTheBase() async throws {
        try await harness.startApp(first: F.enrolled(removals: [F.removal("accepted")]))
        try await harness.deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("released")]))
        try await harness.deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        XCTAssertTrue(model.snapshot.powerBases.isEmpty)
        XCTAssertTrue(model.snapshot.modules.isEmpty)
    }

    private func assertTheNewRegistrationIsManagedLikeAnyOther(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let state = harness.sheetState()
        XCTAssertNotNil(state.base, what, file: file, line: line)
        XCTAssertEqual(state.availability, .available, "the earlier removal does not stand in the way of a new one: \(what)", file: file, line: line)
        XCTAssertNil(PowerBaseManagementText.unavailableMessage(state.availability), what, file: file, line: line)
        XCTAssertNil(listBadge(), "no '삭제 완료' next to a Base the hub lists: \(what)", file: file, line: line)
    }

    // MARK: - The report

    func testABaseRegisteredAgainRightAfterItsRemovalIsNotShownAsRemoved() async throws {
        try await removeTheBase()

        // Registered again at once. The hub keeps listing the finished job.
        try await harness.deliver(F.enrolled(removals: [F.removal("completed")]))
        XCTAssertEqual(model.snapshot.powerBases.map(\.isOnline), [true])
        XCTAssertEqual(model.snapshot.modules.count, 2, "its sensors are back")
        XCTAssertEqual(model.health, .healthy)
        assertTheNewRegistrationIsManagedLikeAnyOther("online, sensors delivering")

        // And it stays that way for as long as the hub repeats the finished job.
        for _ in 0..<3 {
            try await harness.deliver(F.enrolled(removals: [F.removal("completed")]))
            assertTheNewRegistrationIsManagedLikeAnyOther("the hub's next snapshot")
        }
    }

    func testABaseRegisteredAgainButNotHeardYetIsNotShownAsRemoved() async throws {
        try await removeTheBase()

        // The new registration is active on the hub; the Base is not heard right now.
        try await harness.deliver(F.snapshot(bases: [F.base(online: false, moduleCount: 0)], modules: [], removals: [F.removal("completed")]))
        XCTAssertEqual(model.snapshot.powerBases.map(\.isOnline), [false])
        assertTheNewRegistrationIsManagedLikeAnyOther("offline")
    }

    func testStartingTheAppAgainDoesNotBringTheFinishedRemovalBack() async throws {
        // The app is started after all of it: the first thing it reads is the Base, registered
        // again, and the finished job of its earlier registration.
        try await harness.startApp(first: F.enrolled(removals: [F.removal("completed")]))
        assertTheNewRegistrationIsManagedLikeAnyOther("the first snapshot after a start")

        harness.stop()
        harness = ReenrollHarness()
        try await harness.startApp(first: F.snapshot(bases: [F.base(online: false, moduleCount: 0)], modules: [], removals: [F.removal("completed")]))
        assertTheNewRegistrationIsManagedLikeAnyOther("the first snapshot after a start, Base offline")
    }

    func testTheHubsOwnListOfJobsDoesNotBringTheFinishedRemovalBackEither() async throws {
        try await removeTheBase()
        try await harness.deliver(F.enrolled(removals: [F.removal("completed")]))

        // The sheet reads the hub's list of jobs while it is shown: the same finished job.
        harness.removalHub.scriptList(.success([RemovalFixtures.removal(.completed)]))
        await removals.refresh()
        assertTheNewRegistrationIsManagedLikeAnyOther("after the list was read")

        // The list answers before the snapshot of the new registration, too.
        try await harness.deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        harness.removalHub.scriptList(.success([RemovalFixtures.removal(.completed)]))
        await removals.refresh()
        try await harness.deliver(F.enrolled(removals: [F.removal("completed")]))
        assertTheNewRegistrationIsManagedLikeAnyOther("list first, snapshot second")

        // A list that cannot be read changes nothing about it.
        harness.removalHub.scriptList(.failure(.unreachable("timeout")))
        await removals.refresh()
        XCTAssertNotNil(removals.refreshProblem)
        assertTheNewRegistrationIsManagedLikeAnyOther("the list could not be read")
    }

    // MARK: - A new removal while the hub still lists the earlier one

    func testANewRemovalIsItsOwnJobWhileTheEarlierOneIsStillListed() async throws {
        try await removeTheBase()
        try await harness.deliver(F.enrolled(removals: [F.removal("completed")]))
        XCTAssertEqual(harness.sheetState().availability, .available)

        // The user removes the Base again: the hub makes a new job.
        harness.removalHub.scriptRequest(.success(RemovalFixtures.removal(.pending, id: RemovalFixtures.otherRemovalID)))
        removals.requestRemoval(of: F.base)
        try await waitUntil { self.removals.action(for: F.base) == nil }
        XCTAssertEqual(harness.removalHub.recorded.filter { if case .request = $0 { true } else { false } }.count, 1)
        var state = harness.sheetState()
        XCTAssertEqual(state.removal?.id, RemovalFixtures.otherRemovalID, "the new job, before any snapshot carries it")
        XCTAssertEqual(state.removal?.presentation, .waitingForPowerBase)
        XCTAssertEqual(state.availability, .removalExists)
        XCTAssertEqual(listBadge(), .waitingForPowerBase)

        // The hub's snapshots carry both jobs from now on.
        let earlier = F.removal("completed")
        try await harness.deliver(F.enrolled(removals: [earlier, F.removal("accepted", id: RemovalFixtures.otherRemovalID)]))
        state = harness.sheetState()
        XCTAssertEqual(state.removal?.id, RemovalFixtures.otherRemovalID)
        XCTAssertEqual(state.removal?.presentation, .inProgress)
        XCTAssertEqual(listBadge(), .inProgress)

        // An answer about the earlier job arrives late (the list, read before the new request).
        harness.removalHub.scriptList(.success([RemovalFixtures.removal(.completed)]))
        await removals.refresh()
        state = harness.sheetState()
        XCTAssertEqual(state.removal?.id, RemovalFixtures.otherRemovalID, "an answer about the earlier job is not this job's state")
        XCTAssertEqual(state.removal?.presentation, .inProgress)
        XCTAssertEqual(state.availability, .removalExists)
    }

    // MARK: - The screens

    /// The real sheet content with the state the app has after the report's steps: it offers
    /// "Power Base 삭제" and says nothing of a finished removal.
    func testTheManagementScreenOffersTheDeleteButtonForTheNewRegistration() async throws {
        try await removeTheBase()
        try await harness.deliver(F.enrolled(removals: [F.removal("completed")]))

        let labels = try await ScreenLabels.read(List { PowerBaseManagementContent(state: harness.sheetState()) })
        XCTAssertTrue(labels.contains(PowerBaseManagementText.delete), "the delete button is there: \(labels)")
        XCTAssertFalse(labels.contains { $0.contains(PowerBaseManagementText.removalTitle(.completed)) }, "nothing says '삭제 완료': \(labels)")
    }

    /// The real device-list header of the Base, as the list builds it.
    func testTheDeviceListShowsTheNewRegistrationWithoutAFinishedRemoval() async throws {
        try await removeTheBase()
        try await harness.deliver(F.enrolled(removals: [F.removal("completed")]))

        let base = try XCTUnwrap(model.snapshot.powerBases.first)
        let header = PowerBaseHeader(base: base, isCurrentStateVerified: model.isPowerBaseStateVerified, removal: removals.removal(for: base.hardwareIdentifier, in: model.snapshot))
        let labels = try await ScreenLabels.read(header)
        XCTAssertTrue(labels.contains { $0.contains(base.shortLabel) }, "\(labels)")
        XCTAssertFalse(labels.contains { $0.contains(PowerBaseManagementText.removalTitle(.completed)) }, "no '삭제 완료' in the Base's row: \(labels)")
    }
}

// MARK: - The app, as it runs on a device

/// The real `AppModel` on a `LiveSensorDataSource` fed by a controllable hub, and the real
/// `PowerBaseRemovalController` on a scripted hub -- wired as `DevicesView` wires them.
@MainActor
final class ReenrollHarness {
    private typealias F = ReenrollHubFixtures

    private(set) var settingsHub: FakeSettingsHub!
    private(set) var transport: ControllableSensorAPITransport!
    private(set) var credentials: InMemoryHubCredentialStore!
    private(set) var removalHub: FakeRemovalHub!
    private(set) var removals: PowerBaseRemovalController!
    private(set) var model: AppModel!

    func liveSource(_ transport: ControllableSensorAPITransport) -> LiveSensorDataSource {
        LiveSensorDataSource(
            endpoint: PogoAPIEndpoint(baseURL: F.hubURL), transport: transport, sleeper: RecordingSleeper(),
            livenessIdleTimeout: 5, periodicRefreshInterval: nil
        )
    }

    /// An app following a paired hub picked in "허브 찾기", with rooms configured, connected, with
    /// the hub's first snapshot received.
    func startApp(first: Data, store: InMemoryHomeConfigurationStore = InMemoryHomeConfigurationStore(language: .korean)) async throws {
        let hub = FakeSettingsHub()
        settingsHub = hub
        credentials = InMemoryHubCredentialStore()
        transport = ControllableSensorAPITransport { first }
        model = AppModel(
            dataSource: liveSource(transport), sourceIdentity: .hub(id: hub.hubID), sourceAddress: F.hubURL,
            configurationStore: store,
            sharedSettings: SharedSettingsController(transport: hub, credentials: credentials, cache: InMemorySharedSettingsCache(), language: .korean, retryInterval: .zero),
            language: .korean
        )
        removalHub = FakeRemovalHub()
        removals = PowerBaseRemovalController(transport: removalHub, credentials: credentials)
        model.start()
        try await waitUntil { self.model.lastSyncAt != nil }
        try await waitUntil { await self.transport.hasOpenEventStream }
        await transport.sendLine(": heartbeat")
        try await waitUntil { self.model.connectionStatus == .connected }
        _ = hub.createCode()
        _ = try await model.sharedSettings.pair(code: "7KQM-3XWD-PA9T", deviceName: "Test")
        removals.targetDidChange(PowerBaseHubTarget(appModel: model))
    }

    func stop() {
        model?.stop()
    }

    /// The hub's next snapshot, as an SSE event on the open connection -- received whether or not
    /// the app puts it on screen.
    func deliver(_ json: Data) async throws {
        let before = model.lastSyncAt
        await transport.setSnapshotProvider { json }
        await transport.sendLines(PogoAPIFixtures.sseSnapshotEvent(json: json))
        try await waitUntil { self.model.lastSyncAt != before }
    }

    /// The sheet's state, read as `PowerBaseManagementSheet.state` reads it; the target as
    /// `DevicesView` hands it to the controller.
    func sheetState(_ identifier: String = ReenrollHubFixtures.base) -> PowerBaseManagementPresentation.State {
        removals.targetDidChange(PowerBaseHubTarget(appModel: model))
        return PowerBaseManagementPresentation.state(
            identifier: identifier, snapshot: model.snapshot, target: removals.target,
            removal: removals.removal(for: identifier, in: model.snapshot),
            action: removals.action(for: identifier),
            isCurrentStateVerified: model.isPowerBaseStateVerified
        )
    }
}

/// A hub's `/api/v1/snapshot` JSON around one Power Base with two sensors.
enum ReenrollHubFixtures {
    static let hubURL = RemovalFixtures.url
    static let base = RemovalFixtures.base
    static let otherBase = RemovalFixtures.otherBase
    static let gasSensor = "744dbdfffe65d357"
    static let dustSensor = "744dbdfffe65d07a"
    static let otherSensor = "0011223344556677"

    nonisolated(unsafe) private static var sequence: Int64 = 0

    static func base(_ uuid: String = base, online: Bool = true, moduleCount: Int = 2, management: String? = "supported", eraseConfirmation: String? = "automatic") -> String {
        // A Base the hub can remove says which registration it lists and how many removals were
        // asked of it (Linux bridge 0.5.0): what a removal request names.
        let binding = management == "supported" ? ",\"record\":\"\(RemovalFixtures.record)\",\"removal_serial\":0" : ""
        let field = (management.map { ",\"management\":\"\($0)\"" } ?? "") + (eraseConfirmation.map { ",\"erase_confirmation\":\"\($0)\"" } ?? "") + binding
        return """
        {"uuid":"\(uuid)","online":\(online),"module_count":\(moduleCount),"online_module_count":\(online ? moduleCount : 0)\(field)}
        """
    }

    static func module(_ uuid: String, base: String = base, online: Bool = true, hasReadings: Bool = true) -> String {
        let readings = hasReadings ? #"{"kind":"temperature","raw_value":23400,"scale":1,"value":23.4,"unit":"celsius","status":"ok","sample_seq":1}"# : ""
        return """
        {"uuid":"\(uuid)","power_base_uuid":"\(base)","parent_uuid":"\(base)","online":\(online),"depth":1,"role":"leaf","sensor_bitmap":6,"generation":1,"last_seq":1,"readings":[\(readings)]}
        """
    }

    /// A job as the hub writes it: `erase_confirmation` only while it is not final.
    static func removal(_ state: String, id: String = RemovalFixtures.removalID, base: String = base, resultUnknown: Bool = false, eraseConfirmation: String? = "automatic") -> String {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let isFinal = ["completed", "cancelled", "superseded"].contains(state)
        let confirmation = isFinal ? "" : (eraseConfirmation.map { ",\"erase_confirmation\":\"\($0)\"" } ?? "")
        return """
        {"removal_id":"\(id)","power_base_uuid":"\(base)","generation":"\(String(repeating: "7e", count: 16))","state":"\(state)","result_unknown":\(resultUnknown),"cancellable":\(state == "pending"),"created_at_unix_ms":\(now - 60_000),"updated_at_unix_ms":\(now - 1_000),"affected_module_count":2\(confirmation)}
        """
    }

    static func snapshot(bases: [String], modules: [String], removals: [String]?) -> Data {
        sequence += 1
        let generatedAt = Int64(Date().timeIntervalSince1970 * 1000) + sequence
        let removalsField = removals.map { ",\"power_base_removals\":[\($0.joined(separator: ","))]" } ?? ""
        return Data("""
        {"schema_version":1,"generated_at_unix_ms":\(generatedAt),"registry_generation":\(sequence),"power_bases":[\(bases.joined(separator: ","))],"modules":[\(modules.joined(separator: ","))]\(removalsField)}
        """.utf8)
    }

    /// The Base registered and heard, both sensors delivering.
    static func enrolled(online: Bool = true, removals: [String]) -> Data {
        snapshot(
            bases: [base(online: online)],
            modules: [module(gasSensor, online: online), module(dustSensor, online: online)],
            removals: removals
        )
    }
}

/// What VoiceOver reads on a real SwiftUI screen put into a window of the test host.
@MainActor
enum ScreenLabels {
    private static var windows: [UIWindow] = []

    static func read<V: View>(_ view: V, size: CGSize = CGSize(width: 390, height: 844)) async throws -> [String] {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        windows.append(window)
        defer {
            window.isHidden = true
            windows.removeAll { $0 === window }
        }
        try await Task.sleep(for: .milliseconds(300))
        // SwiftUI builds its accessibility tree only once something asks for accessibility (see
        // `SheetIconRowLayoutTests`).
        typealias SetAutomationEnabled = @convention(c) (Int32) -> Void
        if let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let symbol = dlsym(library, "_AXSSetAutomationEnabled") {
            unsafeBitCast(symbol, to: SetAutomationEnabled.self)(1)
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        var labels: [String] = []
        func collect(_ object: Any) {
            guard let element = object as? NSObject else { return }
            if element.isAccessibilityElement, let label = element.accessibilityLabel, !label.isEmpty { labels.append(label) }
            if let children = element.accessibilityElements { children.forEach(collect) }
            if !element.isAccessibilityElement, let view = element as? UIView { view.subviews.forEach(collect) }
        }
        collect(window)
        try XCTSkipIf(labels.isEmpty, "this test host exposes no accessibility tree (not verified here)")
        return labels
    }
}
