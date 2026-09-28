import XCTest
@testable import PogoHome

/// Widgets are reloaded when what they say changes — not on every POGO update.
final class HomeGlanceRefreshPolicyTests: XCTestCase {
    private typealias F = GlanceFixtures
    private typealias P = HomeGlanceRefreshPolicy

    private func glance(
        _ modules: [SensorModule] = [F.climate()],
        health: HomeHealthState = .healthy,
        syncedAt: Date = F.t0,
        appleHome: HomeGlanceBuilder.AppleHomeInput = F.appleHomeInput(),
        previous: HomeGlanceSnapshot? = nil
    ) -> HomeGlanceSnapshot {
        F.build(pogo: F.pogoInput(F.home(modules), health: health, lastSyncAt: syncedAt), appleHome: appleHome, previous: previous, now: syncedAt)
    }

    // MARK: - Classification

    func testClassification() {
        let base = glance()
        XCTAssertEqual(P.classify(from: nil, to: base), .state)
        XCTAssertEqual(P.classify(from: base, to: base), .none)

        var written = base
        written.writtenAt = F.t0.addingTimeInterval(1)
        XCTAssertEqual(P.classify(from: base, to: written), .none, "writing again isn't a change")

        XCTAssertEqual(P.classify(from: base, to: glance(syncedAt: F.t0.addingTimeInterval(5))), .minor, "only confirmation times moved")
        XCTAssertEqual(P.classify(from: base, to: glance([F.climate(temperature: 23.6)])), .minor, "0.2 °C isn't worth a redraw")
        XCTAssertEqual(P.classify(from: base, to: glance([F.climate(temperature: 24.0)])), .values)
        XCTAssertEqual(P.classify(from: base, to: glance([F.climate(status: .stale)], health: .attentionNeeded)), .state)
        XCTAssertEqual(P.classify(from: base, to: glance([F.climate(online: false)], health: .attentionNeeded)), .state)
        XCTAssertEqual(P.classify(from: base, to: glance([F.climate(), F.air()])), .state, "a new value to pick")
        XCTAssertEqual(P.classify(from: base, to: glance([F.climate(name: "새 이름")])), .state)
        XCTAssertEqual(P.classify(from: base, to: glance(health: .reconnecting, previous: base)), .state)
        XCTAssertEqual(P.classify(from: base, to: glance(appleHome: F.appleHomeInput(state: .denied))), .privacy)
        XCTAssertEqual(P.classify(from: base, to: glance(appleHome: F.appleHomeInput(isEnabled: false))), .privacy)
    }

    func testDiscreteAppleHomeValuesAlwaysCount() {
        let open = AppleHomeAccessory(
            id: UUID(), homeID: AppleHomeFixtures.homeID, name: "현관", isReachable: true,
            services: [AppleHomeService(id: UUID(), kind: .contactSensor, name: "문", characteristics: [
                AppleHomeCharacteristic(id: F.sameNameTemperatureID, kind: .contactState, value: .int(0), confirmedAt: F.t0),
            ])]
        )
        let closed = AppleHomeAccessory(
            id: open.id, homeID: open.homeID, name: open.name, isReachable: true,
            services: [AppleHomeService(id: open.services[0].id, kind: .contactSensor, name: "문", characteristics: [
                AppleHomeCharacteristic(id: F.sameNameTemperatureID, kind: .contactState, value: .int(1), confirmedAt: F.t0),
            ])]
        )
        XCTAssertEqual(P.classify(from: glance(appleHome: F.appleHomeInput([open])), to: glance(appleHome: F.appleHomeInput([closed]))), .state)
    }

    // MARK: - Decisions

    func testFirstGlanceIsWrittenAndReloaded() {
        let decision = P.decide(next: glance(), persisted: nil, reloaded: nil, lastPersistAt: nil, lastReloadAt: nil, now: F.t0)
        XCTAssertEqual(decision, .init(persist: true, reload: .now))
    }

    func testSteadyPollingWritesRarelyAndNeverReloadsEveryTick() {
        let base = glance()
        var persists = 0
        var reloads = 0
        var lastPersistAt = F.t0
        var lastReloadAt = F.t0
        var persisted = base
        // Five minutes of a POGO update every 5 s with tiny jitter.
        for tick in 1...60 {
            let now = F.t0.addingTimeInterval(Double(tick) * 5)
            let next = glance([F.climate(temperature: 23.4 + (tick.isMultiple(of: 2) ? 0.1 : 0))], syncedAt: now)
            let decision = P.decide(next: next, persisted: persisted, reloaded: base, lastPersistAt: lastPersistAt, lastReloadAt: lastReloadAt, now: now)
            if decision.persist { persists += 1; persisted = next; lastPersistAt = now }
            if decision.reload == .now { reloads += 1; lastReloadAt = now }
        }
        XCTAssertEqual(reloads, 0)
        XCTAssertLessThanOrEqual(persists, 1)
    }

    func testAStateChangeReloadsAtOnceButNotTwiceWithinTheInterval() {
        let base = glance()
        let offline = glance([F.climate(online: false)], health: .attentionNeeded, syncedAt: F.t0.addingTimeInterval(20))

        let long = P.decide(next: offline, persisted: base, reloaded: base, lastPersistAt: F.t0, lastReloadAt: F.t0.addingTimeInterval(-120), now: F.t0.addingTimeInterval(20))
        XCTAssertEqual(long, .init(persist: true, reload: .now))

        let soon = P.decide(next: offline, persisted: base, reloaded: base, lastPersistAt: F.t0, lastReloadAt: F.t0, now: F.t0.addingTimeInterval(20))
        XCTAssertTrue(soon.persist, "the file is current even while the reload waits")
        XCTAssertEqual(soon.reload, .at(F.t0.addingTimeInterval(P.stateReloadInterval)))
    }

    func testRevokedAppleHomeReloadsImmediatelyEvenRightAfterAReload() {
        let base = glance()
        let denied = glance(appleHome: F.appleHomeInput(state: .denied))
        let decision = P.decide(next: denied, persisted: base, reloaded: base, lastPersistAt: F.t0, lastReloadAt: F.t0, now: F.t0.addingTimeInterval(1))
        XCTAssertEqual(decision, .init(persist: true, reload: .now))
    }

    func testVisibleValueChangesAreWrittenButReloadedAtMostEveryFifteenMinutes() {
        let base = glance()
        let warmer = glance([F.climate(temperature: 25)], syncedAt: F.t0.addingTimeInterval(60))
        let soon = P.decide(next: warmer, persisted: base, reloaded: base, lastPersistAt: F.t0, lastReloadAt: F.t0, now: F.t0.addingTimeInterval(60))
        XCTAssertEqual(soon, .init(persist: true, reload: .none))

        let later = P.decide(next: warmer, persisted: warmer, reloaded: base, lastPersistAt: F.t0, lastReloadAt: F.t0, now: F.t0.addingTimeInterval(P.valueReloadInterval))
        XCTAssertEqual(later.reload, .now)
    }

    func testConfirmationsAloneReloadBeforeTheWidgetWouldCallThemOld() {
        let base = glance()
        let now = F.t0.addingTimeInterval(P.confirmationReloadInterval)
        let decision = P.decide(next: glance(syncedAt: now), persisted: base, reloaded: base, lastPersistAt: F.t0, lastReloadAt: F.t0, now: now)
        XCTAssertEqual(decision.reload, .now)
        XCTAssertLessThan(P.confirmationReloadInterval, HomeGlanceFreshness.staleAfter)
    }

    func testLeavingTheForegroundFlushesOnlyWhatDiffers() {
        let base = glance()
        XCTAssertEqual(P.decideOnLeavingForeground(next: base, persisted: base, reloaded: base), .init(persist: false, reload: .none))
        let newer = glance(syncedAt: F.t0.addingTimeInterval(30))
        XCTAssertEqual(P.decideOnLeavingForeground(next: newer, persisted: base, reloaded: base), .init(persist: true, reload: .now))
    }
}
