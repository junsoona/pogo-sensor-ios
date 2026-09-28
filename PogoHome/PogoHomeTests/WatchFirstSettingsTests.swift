import XCTest
@testable import PogoHome

/// The Watch's side of the first hand-over: a Watch without settings asks the iPhone as soon as the
/// link comes up instead of waiting for the next round, a late answer never undoes newer settings,
/// and the Watch says which of "connecting", "not installed", "out of reach" and "nothing sent yet"
/// keeps it without settings.
@MainActor
final class WatchFirstSettingsTests: XCTestCase {
    private typealias F = GlanceFixtures
    private typealias W = WatchFixtures

    private var clock = Clock(GlanceFixtures.t0)

    private func engine(store: InMemoryWatchStore = InMemoryWatchStore(), phone: WatchPhoneRelaying) -> WatchSyncEngine {
        let clock = clock
        return WatchSyncEngine(store: store, hub: ScriptedHub(), phone: phone, reloader: CountingWatchReloader(), language: .korean, now: { clock.now })
    }

    private func reply(settings: WatchSettings, glance: HomeGlanceSnapshot? = nil) -> WatchRelayReply {
        WatchRelayReply(outcome: .hubUnreachable, payload: W.payload(glance: glance, settings: settings, sentAt: clock.now))
    }

    /// The launch round runs before the session has activated: the iPhone can't be asked yet.
    func testAWatchWithoutSettingsAsksTheIPhoneAsSoonAsTheLinkComesUp() async {
        let phone = ScriptedPhone(reachable: false)
        let store = InMemoryWatchStore()
        let sync = engine(store: store, phone: phone)

        let first = await sync.refresh()
        XCTAssertEqual(first?.phone, .failed(.phoneUnreachable))
        XCTAssertNil(sync.settings)

        phone.isPhoneReachable = true
        phone.replies = [.success(reply(settings: W.settings()))]
        sync.phoneLinkDidChange(.reachable)

        let received = await waitUntil { sync.settings != nil }
        XCTAssertTrue(received)
        XCTAssertEqual(sync.settings, W.settings())
        XCTAssertEqual(phone.requestCount, 1)
        XCTAssertEqual(sync.phoneLink, .reachable)
        XCTAssertEqual(store.state.settings, W.settings(), "kept for the next launch and the widgets")
    }

    func testTheIPhoneComingIntoReachDuringARoundIsAskedRightAfterIt() async {
        let phone = HeldPhone()
        let sync = engine(phone: phone)
        let round = Task { await sync.refresh() }
        let ready1 = await waitUntil { phone.waiting }
        XCTAssertTrue(ready1)

        sync.phoneLinkDidChange(.unreachable)
        sync.phoneLinkDidChange(.reachable)
        phone.answer(.failure(WatchPhoneRelayError.unreachable))
        _ = await round.value
        XCTAssertNil(sync.settings)

        let ready2 = await waitUntil { phone.waiting }
        XCTAssertTrue(ready2)
        XCTAssertEqual(phone.requestCount, 2, "asked again after the round, not 30 s later")
        phone.answer(.success(reply(settings: W.settings())))
        let ready3 = await waitUntil { !sync.isRefreshing && sync.settings != nil }
        XCTAssertTrue(ready3)
        XCTAssertEqual(sync.settings, W.settings())
    }

    func testAWatchThatHasSettingsDoesntAskOnEveryReachabilityChange() async {
        let phone = ScriptedPhone(reachable: true)
        let sync = engine(store: InMemoryWatchStore(WatchStoredState(glance: nil, settings: W.settings(), record: .empty)), phone: phone)

        sync.phoneLinkDidChange(.reachable)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(phone.requestCount, 0)
        XCTAssertFalse(sync.isRefreshing)
    }

    func testALateAnswerNeverUndoesNewerSettingsHandedOverMeanwhile() async {
        let phone = HeldPhone()
        let sync = engine(phone: phone)
        let older = W.settings(updatedAt: F.t0, selection: [F.temperatureID])
        let newer = W.settings(updatedAt: F.t0.addingTimeInterval(60), selection: [F.appleHomeTemperatureID])
        let round = Task { await sync.refresh() }
        let ready4 = await waitUntil { phone.waiting }
        XCTAssertTrue(ready4)

        sync.receivePush(W.payload(glance: nil, settings: newer))
        phone.answer(.success(reply(settings: older)))
        _ = await round.value

        XCTAssertEqual(sync.settings, newer)
    }

    func testWithoutSettingsTheWatchSaysWhatKeepsIt() {
        func hint(_ link: WatchPhoneLinkStatus, refreshing: Bool = false) -> WatchSetupHint? {
            WatchGlancePresentation.setupHint(settings: nil, selectedCount: 0, phoneLink: link, isRefreshing: refreshing)
        }
        XCTAssertEqual(hint(.activating), .connectingToPhone)
        XCTAssertEqual(hint(.companionNotInstalled), .phoneAppNotInstalled)
        XCTAssertEqual(hint(.unreachable), .phoneUnreachable)
        XCTAssertEqual(hint(.reachable, refreshing: true), .receivingSettings)
        XCTAssertEqual(hint(.reachable), .openPhoneApp)
        XCTAssertEqual(WatchGlancePresentation.setupHint(settings: W.settings(selection: []), selectedCount: 0, phoneLink: .unreachable, isRefreshing: false), .pickValues)
        XCTAssertNil(WatchGlancePresentation.setupHint(settings: W.settings(), selectedCount: 1, phoneLink: .unreachable, isRefreshing: false))
    }
}

/// An iPhone link whose answer the test releases.
@MainActor
private final class HeldPhone: WatchPhoneRelaying {
    var isPhoneReachable = true
    private(set) var requestCount = 0
    private var pending: CheckedContinuation<WatchRelayReply, Error>?

    var waiting: Bool { pending != nil }

    func requestRefresh() async throws -> WatchRelayReply {
        requestCount += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    func answer(_ result: Result<WatchRelayReply, Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}
